import BackbufferCore
import Carbon
import Foundation

private final class HotKeyResourceBox: @unchecked Sendable {
    var hotKeyRef: EventHotKeyRef?
    var eventHandlerRef: EventHandlerRef?

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }
}

/// Registers a global hotkey using Carbon `RegisterEventHotKey` so Backbuffer
/// requires zero Accessibility or Input Monitoring permissions.
@MainActor
final class HotKeyManager {
    private static let hotKeySignature: OSType = 0x424B_4246 // "BKBF"
    private static let hotKeyNumericID: UInt32 = 1

    private let resources = HotKeyResourceBox()
    private var onTrigger: (() -> Void)?
    private(set) var activeShortcut: HotKeyShortcut?

    init(onTrigger: (() -> Void)? = nil) {
        self.onTrigger = onTrigger
    }

    func setHandler(_ handler: @escaping () -> Void) {
        self.onTrigger = handler
    }

    func register(shortcut: HotKeyShortcut) throws {
        unregister()
        try installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyNumericID
        )
        var newRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &newRef
        )
        guard status == noErr, let registeredRef = newRef else {
            throw BackbufferError.hotKeyRegistrationFailed(status)
        }

        resources.hotKeyRef = registeredRef
        activeShortcut = shortcut
    }

    func unregister() {
        if let ref = resources.hotKeyRef {
            UnregisterEventHotKey(ref)
            resources.hotKeyRef = nil
        }
        activeShortcut = nil
    }

    private func installEventHandlerIfNeeded() throws {
        guard resources.eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
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
                  pressedID.signature == HotKeyManager.hotKeySignature,
                  pressedID.id == HotKeyManager.hotKeyNumericID else {
                return OSStatus(eventNotHandledErr)
            }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor [weak manager] in
                manager?.handleHotKeyPressed()
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            userData,
            &handlerRef
        )
        guard status == noErr, let installedHandler = handlerRef else {
            throw BackbufferError.hotKeyRegistrationFailed(status)
        }
        resources.eventHandlerRef = installedHandler
    }

    private func handleHotKeyPressed() {
        onTrigger?()
    }
}
