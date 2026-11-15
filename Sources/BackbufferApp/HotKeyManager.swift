import AppKit
import BackbufferCore
import Carbon
import Foundation

private let backbufferHotKeySignature: OSType = 0x424B_4246 // "BKBF"

private struct HotKeyEventBox: @unchecked Sendable {
    let event: NSEvent
}

private func runHotKeySyncOnMainActor<T: Sendable>(_ operation: @MainActor () -> T) -> T {
    if #available(macOS 14.0, *) {
        return MainActor.assumeIsolated(operation)
    } else {
        precondition(Thread.isMainThread)
        typealias YesActor = @MainActor () -> T
        typealias NoActor = () -> T
        return withoutActuallyEscaping(operation) { (_ fn: @escaping YesActor) -> T in
            let rawFn = unsafeBitCast(fn, to: NoActor.self)
            return rawFn()
        }
    }
}

enum HotKeySlot: UInt32, CaseIterable, Hashable, Sendable {
    case saveClip = 1
    case togglePause = 2
}

private final class HotKeyCallbackContext: @unchecked Sendable {
    weak var manager: HotKeyManager?
}

private final class HotKeyResourceBox: @unchecked Sendable {
    var hotKeyRefs: [HotKeySlot: EventHotKeyRef] = [:]
    var eventHandlerRef: EventHandlerRef?
    let callbackContext = HotKeyCallbackContext()
    var retainedContextPtr: UnsafeMutableRawPointer?
    var localMonitor: AnyObject?

    deinit {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
        if let ptr = retainedContextPtr {
            Unmanaged<HotKeyCallbackContext>.fromOpaque(ptr).release()
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

/// Registers global shortcuts via Carbon `RegisterEventHotKey` targeting the
/// event dispatcher, plus an in-app `NSEvent` local keyDown fallback.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private static let triggerCooldownSeconds: TimeInterval = 0.25

    private let resources = HotKeyResourceBox()
    private var handlers: [HotKeySlot: @MainActor () -> Void] = [:]
    private var configuredShortcuts: [HotKeySlot: HotKeyShortcut] = [:]
    private var isRecordingPaused: Bool = false
    private var lastTriggerUptimes: [HotKeySlot: TimeInterval] = [:]

    var activeShortcuts: [HotKeySlot: HotKeyShortcut] {
        configuredShortcuts
    }

    init() {
        resources.callbackContext.manager = self
    }

    func setHandler(for slot: HotKeySlot, handler: @escaping @MainActor () -> Void) {
        handlers[slot] = handler
    }

    @discardableResult
    func register(shortcut: HotKeyShortcut, for slot: HotKeySlot) -> Bool {
        unregisterCarbonHotKey(for: slot)

        if isRecordingPaused {
            configuredShortcuts[slot] = shortcut
            installLocalMonitorIfNeeded()
            return true
        }

        guard installEventHandlerIfNeeded() else {
            configuredShortcuts.removeValue(forKey: slot)
            removeLocalMonitorIfNeededIfUnused()
            return false
        }

        guard let registeredRef = registerCarbonHotKey(shortcut: shortcut, slot: slot) else {
            configuredShortcuts.removeValue(forKey: slot)
            removeLocalMonitorIfNeededIfUnused()
            return false
        }

        resources.hotKeyRefs[slot] = registeredRef
        configuredShortcuts[slot] = shortcut
        installLocalMonitorIfNeeded()
        return true
    }

    func unregister(slot: HotKeySlot) {
        unregisterCarbonHotKey(for: slot)
        configuredShortcuts.removeValue(forKey: slot)
        lastTriggerUptimes.removeValue(forKey: slot)
        removeLocalMonitorIfNeededIfUnused()
    }

    func unregisterAll() {
        for slot in HotKeySlot.allCases {
            unregisterCarbonHotKey(for: slot)
        }
        configuredShortcuts.removeAll()
        lastTriggerUptimes.removeAll()
        removeLocalMonitorIfNeeded()
    }

    func setRecordingPaused(_ paused: Bool) {
        guard isRecordingPaused != paused else { return }
        isRecordingPaused = paused

        if paused {
            for slot in HotKeySlot.allCases {
                unregisterCarbonHotKey(for: slot)
            }
            return
        }

        guard !configuredShortcuts.isEmpty, installEventHandlerIfNeeded() else {
            return
        }

        for (slot, shortcut) in configuredShortcuts {
            unregisterCarbonHotKey(for: slot)
            if let ref = registerCarbonHotKey(shortcut: shortcut, slot: slot) {
                resources.hotKeyRefs[slot] = ref
            }
        }
        installLocalMonitorIfNeeded()
    }

    nonisolated static func isSystemSymbolicConflict(_ shortcut: HotKeyShortcut) -> Bool {
        var rawHotKeys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&rawHotKeys)
        guard status == noErr, let cfArray = rawHotKeys?.takeRetainedValue() else {
            return false
        }

        guard let entries = cfArray as NSArray as? [[String: Any]] else {
            return false
        }

        let targetModifiers = shortcut.nsEventModifierFlags.intersection([.command, .option, .shift, .control])
        let keyCodeKey = kHISymbolicHotKeyCode as String
        let modifiersKey = kHISymbolicHotKeyModifiers as String
        let enabledKey = kHISymbolicHotKeyEnabled as String

        for entry in entries {
            guard (entry[enabledKey] as? NSNumber)?.boolValue == true,
                  let rawKeyCode = (entry[keyCodeKey] as? NSNumber)?.int64Value,
                  rawKeyCode >= 0,
                  let rawModifiers = (entry[modifiersKey] as? NSNumber)?.uintValue else {
                continue
            }

            if UInt32(truncatingIfNeeded: rawKeyCode) != shortcut.keyCode {
                continue
            }

            let entryModifiers = NSEvent.ModifierFlags(rawValue: rawModifiers)
                .intersection([.command, .option, .shift, .control])
            if entryModifiers == targetModifiers {
                return true
            }
        }

        return false
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard resources.eventHandlerRef == nil else { return true }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let contextPtr = Unmanaged.passRetained(resources.callbackContext).toOpaque()
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )

            guard status == noErr,
                  pressedID.signature == backbufferHotKeySignature,
                  let slot = HotKeySlot(rawValue: pressedID.id) else {
                return OSStatus(eventNotHandledErr)
            }

            let context = Unmanaged<HotKeyCallbackContext>.fromOpaque(userData).takeUnretainedValue()
            if Thread.isMainThread {
                runHotKeySyncOnMainActor {
                    context.manager?.handleHotKeyPressed(slot: slot)
                }
            } else {
                Task { @MainActor in
                    context.manager?.handleHotKeyPressed(slot: slot)
                }
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventSpec,
            contextPtr,
            &handlerRef
        )

        guard status == noErr, let installedHandler = handlerRef else {
            Unmanaged<HotKeyCallbackContext>.fromOpaque(contextPtr).release()
            return false
        }

        resources.retainedContextPtr = contextPtr
        resources.eventHandlerRef = installedHandler
        return true
    }

    private func registerCarbonHotKey(shortcut: HotKeyShortcut, slot: HotKeySlot) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(
            signature: backbufferHotKeySignature,
            id: slot.rawValue
        )
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &newRef
        )
        guard status == noErr else { return nil }
        return newRef
    }

    private func unregisterCarbonHotKey(for slot: HotKeySlot) {
        if let ref = resources.hotKeyRefs.removeValue(forKey: slot) {
            UnregisterEventHotKey(ref)
        }
    }

    private func installLocalMonitorIfNeeded() {
        guard resources.localMonitor == nil else { return }

        let context = resources.callbackContext
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat, Thread.isMainThread else { return event }
            let eventBox = HotKeyEventBox(event: event)
            let handled = runHotKeySyncOnMainActor {
                guard let manager = context.manager else { return false }
                return manager.handleLocalKeyDown(eventBox.event)
            }
            return handled ? nil : event
        }
        resources.localMonitor = monitor as AnyObject?
    }

    private func removeLocalMonitorIfNeededIfUnused() {
        if configuredShortcuts.isEmpty {
            removeLocalMonitorIfNeeded()
        }
    }

    private func removeLocalMonitorIfNeeded() {
        if let monitor = resources.localMonitor {
            NSEvent.removeMonitor(monitor)
            resources.localMonitor = nil
        }
    }

    private func handleHotKeyPressed(slot: HotKeySlot) {
        triggerSlotIfNeeded(slot)
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard !isRecordingPaused else { return false }
        let keyCode = UInt32(event.keyCode)
        let carbonModifiers = HotKeyShortcut.carbonModifiers(from: event.modifierFlags)

        guard let matchedSlot = configuredShortcuts.first(where: {
            $0.value.keyCode == keyCode && $0.value.carbonModifiers == carbonModifiers
        })?.key else {
            return false
        }

        triggerSlotIfNeeded(matchedSlot)
        return true
    }

    private func triggerSlotIfNeeded(_ slot: HotKeySlot) {
        guard !isRecordingPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastUptime = lastTriggerUptimes[slot],
           (now - lastUptime) < Self.triggerCooldownSeconds {
            return
        }
        lastTriggerUptimes[slot] = now
        handlers[slot]?()
    }
}
