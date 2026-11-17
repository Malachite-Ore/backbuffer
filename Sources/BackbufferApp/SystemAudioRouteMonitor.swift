import CoreAudio
import Foundation

struct OutputAudioRouteSnapshot: Equatable, Sendable {
    let deviceID: UInt32
    let nominalSampleRate: Double
    let bufferFrameSize: UInt32

    static let empty = OutputAudioRouteSnapshot(
        deviceID: 0,
        nominalSampleRate: 0,
        bufferFrameSize: 0
    )
}

private final class RouteListenerWorker: @unchecked Sendable {
    private struct ListenerEntry {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let debounceSeconds: TimeInterval = 0.35

    private let queue = DispatchQueue(label: "io.malachiteore.backbuffer.audioroute.monitor", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    private var systemEntries: [ListenerEntry] = []
    private var deviceEntries: [ListenerEntry] = []
    private var observedDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var lastEmittedSnapshot: OutputAudioRouteSnapshot = .empty
    private var debounceWorkItem: DispatchWorkItem?

    weak var owner: SystemAudioRouteMonitor?

    deinit {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        removeListeners(&deviceEntries)
        removeListeners(&systemEntries)
    }

    @discardableResult
    func start(initialSnapshot: OutputAudioRouteSnapshot) -> UInt64 {
        let targetGeneration = bumpGeneration()
        queue.async { [weak self] in
            guard let self, self.isGenerationCurrent(targetGeneration) else { return }
            self.teardownListenersOnQueue()
            self.lastEmittedSnapshot = initialSnapshot
            self.attachSystemListeners(generation: targetGeneration)
            self.syncDeviceListeners(to: AudioObjectID(initialSnapshot.deviceID), generation: targetGeneration)
        }
        return targetGeneration
    }

    func stop() {
        _ = bumpGeneration()
        queue.async { [weak self] in
            self?.teardownListenersOnQueue()
        }
    }

    private func bumpGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    private func isGenerationCurrent(_ targetGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == targetGeneration
    }

    private func teardownListenersOnQueue() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        removeListeners(&deviceEntries)
        removeListeners(&systemEntries)
        observedDeviceID = AudioObjectID(kAudioObjectUnknown)
        lastEmittedSnapshot = .empty
    }

    private func attachSystemListeners(generation targetGeneration: UInt64) {
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handlePropertyChange(isSystemProperty: true, generation: targetGeneration)
            }
            let status = AudioObjectAddPropertyListenerBlock(systemObjectID, &address, queue, block)
            if status == noErr {
                systemEntries.append(ListenerEntry(objectID: systemObjectID, address: address, block: block))
            }
        }
    }

    private func syncDeviceListeners(to newDeviceID: AudioObjectID, generation targetGeneration: UInt64) {
        guard observedDeviceID != newDeviceID else { return }
        removeListeners(&deviceEntries)
        observedDeviceID = newDeviceID

        guard newDeviceID != AudioObjectID(kAudioObjectUnknown), newDeviceID != 0 else {
            return
        }

        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyNominalSampleRate,
            kAudioDevicePropertyBufferFrameSize,
            kAudioDevicePropertyDeviceIsAlive
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handlePropertyChange(isSystemProperty: false, generation: targetGeneration)
            }
            let status = AudioObjectAddPropertyListenerBlock(newDeviceID, &address, queue, block)
            if status == noErr {
                deviceEntries.append(ListenerEntry(objectID: newDeviceID, address: address, block: block))
            }
        }
    }

    private func handlePropertyChange(isSystemProperty: Bool, generation targetGeneration: UInt64) {
        guard isGenerationCurrent(targetGeneration) else { return }

        if isSystemProperty {
            let activeDeviceID = Self.readDefaultOutputDeviceID()
            syncDeviceListeners(to: activeDeviceID, generation: targetGeneration)
        }

        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isGenerationCurrent(targetGeneration) else { return }

            let activeDeviceID = Self.readDefaultOutputDeviceID()
            self.syncDeviceListeners(to: activeDeviceID, generation: targetGeneration)

            let snapshot = Self.readCurrentSnapshot()
            guard snapshot.deviceID != 0, snapshot != self.lastEmittedSnapshot else {
                return
            }

            self.lastEmittedSnapshot = snapshot
            Task { @MainActor [weak owner = self.owner] in
                owner?.deliverRouteSnapshot(snapshot, expectedWorkerGeneration: targetGeneration)
            }
        }

        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: workItem)
    }

    private func removeListeners(_ entries: inout [ListenerEntry]) {
        for var entry in entries {
            AudioObjectRemovePropertyListenerBlock(entry.objectID, &entry.address, queue, entry.block)
        }
        entries.removeAll()
    }

    static func readCurrentSnapshot() -> OutputAudioRouteSnapshot {
        let deviceID = readDefaultOutputDeviceID()
        guard deviceID != AudioObjectID(kAudioObjectUnknown), deviceID != 0 else {
            return .empty
        }

        let sampleRate = readFloat64Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) ?? 0
        let bufferFrames = readUInt32Property(
            objectID: deviceID,
            selector: kAudioDevicePropertyBufferFrameSize
        ) ?? 0

        return OutputAudioRouteSnapshot(
            deviceID: UInt32(deviceID),
            nominalSampleRate: sampleRate,
            bufferFrameSize: bufferFrames
        )
    }

    private static func readDefaultOutputDeviceID() -> AudioObjectID {
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        if let primary = readUInt32Property(
            objectID: systemID,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ), primary != 0 {
            return AudioObjectID(primary)
        }
        if let fallback = readUInt32Property(
            objectID: systemID,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice
        ), fallback != 0 {
            return AudioObjectID(fallback)
        }
        return AudioObjectID(kAudioObjectUnknown)
    }

    private static func readFloat64Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Double? {
        for scope in [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
            if status == noErr, value.isFinite, value > 0 {
                return value
            }
        }
        return nil
    }

    private static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        for scope in [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
            if status == noErr {
                return value
            }
        }
        return nil
    }
}

@MainActor
final class SystemAudioRouteMonitor {
    private let worker = RouteListenerWorker()
    private var onRouteChanged: ((OutputAudioRouteSnapshot) -> Void)?
    private var isMonitoring: Bool = false
    private var activeWorkerGeneration: UInt64 = 0

    init() {
        worker.owner = self
    }

    func currentSnapshot() -> OutputAudioRouteSnapshot {
        RouteListenerWorker.readCurrentSnapshot()
    }

    func start(onRouteChanged: @escaping @MainActor (OutputAudioRouteSnapshot) -> Void) {
        self.onRouteChanged = onRouteChanged
        self.isMonitoring = true
        let initial = RouteListenerWorker.readCurrentSnapshot()
        self.activeWorkerGeneration = worker.start(initialSnapshot: initial)
    }

    func stop() {
        isMonitoring = false
        onRouteChanged = nil
        activeWorkerGeneration &+= 1
        worker.stop()
    }

    fileprivate func deliverRouteSnapshot(
        _ snapshot: OutputAudioRouteSnapshot,
        expectedWorkerGeneration: UInt64
    ) {
        guard isMonitoring, expectedWorkerGeneration == activeWorkerGeneration else { return }
        onRouteChanged?(snapshot)
    }
}
