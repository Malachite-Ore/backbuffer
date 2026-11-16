import AVFoundation
import BackbufferCore
import CoreMedia
import Foundation

struct MicrophoneDeviceOption: Identifiable, Equatable, Hashable, Sendable {
    static let systemDefaultID = "__system_default__"

    let id: String
    let name: String
    let isDefault: Bool
    let localizedDetail: String
}

enum MicrophonePermissionState: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
}

private final class CaptureSessionBox: @unchecked Sendable {
    let session: AVCaptureSession

    init(session: AVCaptureSession) {
        self.session = session
    }

    func stopRunning() {
        session.stopRunning()
    }
}

private final class RuntimeObserverBox: @unchecked Sendable {
    var runtimeErrorObserver: AnyObject?

    func replace(with newObserver: AnyObject?) {
        if let old = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(old)
        }
        runtimeErrorObserver = newObserver
    }

    func remove() {
        if let old = runtimeErrorObserver {
            NotificationCenter.default.removeObserver(old)
            runtimeErrorObserver = nil
        }
    }

    deinit {
        remove()
    }
}

private final class MicCaptureRelay: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private let sessionQueue = DispatchQueue(label: "io.malachiteore.backbuffer.microphone.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "io.malachiteore.backbuffer.microphone.samples", qos: .userInteractive)
    private let runtimeObserverBox = RuntimeObserverBox()

    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var ringBuffer: ReplayRingBuffer?
    private var isMuted: Bool = false
    private var enablePreviewMeterOnly: Bool = false
    private var generation: UInt64 = 0
    private var lastMeterUptime: TimeInterval = 0
    private var consecutiveSilentSeconds: TimeInterval = 0
    private var lastPublishedSilentLock: Bool = false

    weak var engine: MicrophoneCaptureEngine?

    var currentIsRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session != nil
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        isMuted = muted
        if muted {
            consecutiveSilentSeconds = 0
            lastPublishedSilentLock = false
        }
        let gen = generation
        stateLock.unlock()

        if muted {
            postMeterState(level: 0.0, suspectedSilent: false, generation: gen)
        }
    }

    func updateOutputTarget(
        ringBuffer: ReplayRingBuffer?,
        enablePreviewMeterOnly: Bool,
        isMuted: Bool
    ) {
        stateLock.lock()
        self.ringBuffer = ringBuffer
        self.enablePreviewMeterOnly = enablePreviewMeterOnly
        self.isMuted = isMuted
        if isMuted {
            consecutiveSilentSeconds = 0
            lastPublishedSilentLock = false
        }
        let gen = generation
        stateLock.unlock()

        if isMuted {
            postMeterState(level: 0.0, suspectedSilent: false, generation: gen)
        }
    }

    private func prepareStartGeneration(
        isMuted: Bool,
        ringBuffer: ReplayRingBuffer?,
        enablePreviewMeterOnly: Bool
    ) -> (targetGeneration: UInt64, previousSession: CaptureSessionBox?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation &+= 1
        let previousSession = session.map(CaptureSessionBox.init)
        session = nil
        audioOutput = nil
        self.ringBuffer = ringBuffer
        self.isMuted = isMuted
        self.enablePreviewMeterOnly = enablePreviewMeterOnly
        self.lastMeterUptime = 0
        self.consecutiveSilentSeconds = 0
        self.lastPublishedSilentLock = false
        runtimeObserverBox.remove()
        return (generation, previousSession)
    }

    func startSession(
        deviceID: String?,
        isMuted: Bool,
        ringBuffer: ReplayRingBuffer?,
        enablePreviewMeterOnly: Bool
    ) async throws {
        let (targetGeneration, previousSession) = prepareStartGeneration(
            isMuted: isMuted,
            ringBuffer: ringBuffer,
            enablePreviewMeterOnly: enablePreviewMeterOnly
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                previousSession?.stopRunning()

                guard let self else {
                    continuation.resume(returning: ())
                    return
                }

                // Abort startup early if stop() or another start() already superseded this generation.
                guard self.isGenerationCurrent(targetGeneration) else {
                    continuation.resume(returning: ())
                    return
                }

                let resolvedDevice: AVCaptureDevice?
                if let deviceID, !deviceID.isEmpty, deviceID != MicrophoneDeviceOption.systemDefaultID {
                    resolvedDevice = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .audio)
                } else {
                    resolvedDevice = AVCaptureDevice.default(for: .audio)
                }

                guard let device = resolvedDevice else {
                    continuation.resume(throwing: BackbufferError.captureStartFailed("No active audio input device was found."))
                    return
                }

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    let newSession = AVCaptureSession()
                    newSession.beginConfiguration()

                    guard newSession.canAddInput(input) else {
                        newSession.commitConfiguration()
                        continuation.resume(throwing: BackbufferError.captureStartFailed("Unable to attach selected microphone to capture session."))
                        return
                    }
                    newSession.addInput(input)

                    let newOutput = AVCaptureAudioDataOutput()
                    // Deliver native hardware LPCM (mono/44.1kHz/24-bit/USB) without internal sample-rate conversion failure.
                    newOutput.audioSettings = nil
                    newOutput.setSampleBufferDelegate(self, queue: self.sampleQueue)

                    guard newSession.canAddOutput(newOutput) else {
                        newSession.commitConfiguration()
                        continuation.resume(throwing: BackbufferError.captureStartFailed("Unable to configure audio output for microphone."))
                        return
                    }
                    newSession.addOutput(newOutput)
                    newSession.commitConfiguration()

                    let runtimeObserver = NotificationCenter.default.addObserver(
                        forName: .AVCaptureSessionRuntimeError,
                        object: newSession,
                        queue: nil
                    ) { [weak self] notification in
                        let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?
                            .localizedDescription
                            ?? "Microphone capture session encountered a runtime error."
                        self?.postRuntimeError(message, generation: targetGeneration)
                    } as AnyObject

                    newSession.startRunning()

                    self.stateLock.lock()
                    let stillCurrent = (self.generation == targetGeneration)
                    if stillCurrent {
                        self.session = newSession
                        self.audioOutput = newOutput
                        self.runtimeObserverBox.replace(with: runtimeObserver)
                    } else {
                        NotificationCenter.default.removeObserver(runtimeObserver)
                    }
                    self.stateLock.unlock()

                    if !stillCurrent {
                        newSession.stopRunning()
                    }
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: BackbufferError.captureStartFailed("Microphone capture failed to start: \(error.localizedDescription)"))
                }
            }
        }
    }

    func stopSession() {
        stateLock.lock()
        generation &+= 1
        let gen = generation
        let oldSessionBox = session.map(CaptureSessionBox.init)
        session = nil
        audioOutput = nil
        ringBuffer = nil
        enablePreviewMeterOnly = false
        lastMeterUptime = 0
        consecutiveSilentSeconds = 0
        lastPublishedSilentLock = false
        runtimeObserverBox.remove()
        stateLock.unlock()

        if let oldSessionBox {
            sessionQueue.async {
                oldSessionBox.stopRunning()
            }
        }
        postMeterState(level: 0.0, suspectedSilent: false, generation: gen)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        _ = connection
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }

        stateLock.lock()
        guard let currentSession = session,
              let expectedOutput = audioOutput,
              output === expectedOutput else {
            stateLock.unlock()
            return
        }
        let currentRingBuffer = ringBuffer
        let muted = isMuted
        let previewOnly = enablePreviewMeterOnly
        let gen = generation
        stateLock.unlock()

        let hostPTS = Self.resolvedHostPTS(for: sampleBuffer, session: currentSession)

        guard let extracted = AudioSampleExtractor.extractStereoInt16(
            from: sampleBuffer,
            overridePTS: hostPTS,
            zeroOut: muted
        ) else {
            return
        }

        if !previewOnly, let currentRingBuffer {
            currentRingBuffer.appendMicAudio(extracted.chunk)
        }

        let chunkDurationSeconds: TimeInterval
        if extracted.chunk.duration.isValid,
           extracted.chunk.duration.isNumeric,
           extracted.chunk.duration.seconds > 0 {
            chunkDurationSeconds = extracted.chunk.duration.seconds
        } else {
            let sr = extracted.chunk.asbd.mSampleRate > 0 ? extracted.chunk.asbd.mSampleRate : 48_000.0
            chunkDurationSeconds = Double(extracted.chunk.frameCount) / sr
        }

        let now = ProcessInfo.processInfo.systemUptime
        var shouldPublish = false
        var suspectedSilent = false

        stateLock.lock()
        if muted {
            consecutiveSilentSeconds = 0
        } else if extracted.maxAbsSample == 0 {
            consecutiveSilentSeconds += max(0.0, chunkDurationSeconds)
        } else {
            consecutiveSilentSeconds = 0
        }

        suspectedSilent = !muted && (consecutiveSilentSeconds >= 2.5)
        let silentStateChanged = (suspectedSilent != lastPublishedSilentLock)
        if silentStateChanged {
            lastPublishedSilentLock = suspectedSilent
            shouldPublish = true
        } else if (now - lastMeterUptime) >= 0.04 {
            lastMeterUptime = now
            shouldPublish = true
        }
        stateLock.unlock()

        if shouldPublish {
            postMeterState(
                level: muted ? 0.0 : extracted.rmsLevel,
                suspectedSilent: suspectedSilent,
                generation: gen
            )
        }
    }

    private func isGenerationCurrent(_ targetGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == targetGeneration
    }

    private func postMeterState(level: Double, suspectedSilent: Bool, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.isGenerationCurrent(generation) else { return }
            self.engine?.applyMeasuredState(level: level, suspectedSilent: suspectedSilent)
        }
    }

    private func postRuntimeError(_ message: String, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.isGenerationCurrent(generation) else { return }
            self.engine?.applyRuntimeError(message)
        }
    }

    private static func resolvedHostPTS(
        for sampleBuffer: CMSampleBuffer,
        session: AVCaptureSession
    ) -> CMTime {
        let hostClock = CMClockGetHostTimeClock()
        let nowHost = CMClockGetTime(hostClock)
        let sampleDuration = CMSampleBufferGetDuration(sampleBuffer)
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if rawPTS.isValid, rawPTS.isNumeric, let syncClock = session.synchronizationClock {
            let converted = CMSyncConvertTime(rawPTS, from: syncClock, to: hostClock)
            if converted.isValid,
               converted.isNumeric,
               abs(CMTimeSubtract(converted, nowHost).seconds) <= 5.0 {
                return converted
            }
        }

        if sampleDuration.isValid, sampleDuration.isNumeric, sampleDuration.seconds > 0 {
            return CMTimeSubtract(nowHost, sampleDuration)
        }
        return nowHost
    }
}

@MainActor
final class MicrophoneCaptureEngine: ObservableObject {
    @Published private(set) var availableDevices: [MicrophoneDeviceOption] = []
    @Published private(set) var inputLevel: Double = 0.0
    @Published private(set) var permissionState: MicrophonePermissionState = .notDetermined
    @Published private(set) var lastErrorMessage: String? = nil
    @Published private(set) var suspectedSilentTCCLock: Bool = false

    private let relay = MicCaptureRelay()
    private(set) var isRunning: Bool = false
    private(set) var activeDeviceID: String?
    private(set) var isPreviewMeterOnly: Bool = false

    init() {
        relay.engine = self
        permissionState = Self.readPermissionState()
    }

    func refreshDevices() {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [
                AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeBuiltInMicrophone"),
                AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")
            ]
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID

        let options = discovery.devices.map { device in
            let isDefault = (device.uniqueID == defaultID)
            let manufacturer = device.manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseDetail: String
            if #available(macOS 14.0, *) {
                if !manufacturer.isEmpty {
                    baseDetail = manufacturer
                } else {
                    baseDetail = (device.deviceType == .microphone) ? "Built-in Microphone" : "External Audio"
                }
            } else {
                baseDetail = manufacturer.isEmpty ? "Audio Input" : manufacturer
            }
            let detail = isDefault ? "\(baseDetail) · System Default" : baseDetail

            return MicrophoneDeviceOption(
                id: device.uniqueID,
                name: device.localizedName,
                isDefault: isDefault,
                localizedDetail: detail
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        availableDevices = options
    }

    @discardableResult
    func currentPermissionState() -> MicrophonePermissionState {
        let resolved = Self.readPermissionState()
        if permissionState != resolved {
            permissionState = resolved
        }
        return resolved
    }

    @discardableResult
    func requestPermissionIfNeeded() async -> Bool {
        let current = currentPermissionState()
        switch current {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            _ = currentPermissionState()
            return granted
        }
    }

    func start(
        deviceID: String?,
        isMuted: Bool,
        ringBuffer: ReplayRingBuffer?,
        enablePreviewMeterOnly: Bool = false
    ) async throws {
        lastErrorMessage = nil
        suspectedSilentTCCLock = false

        let perm = currentPermissionState()
        switch perm {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestPermissionIfNeeded()
            if !granted {
                stop()
                lastErrorMessage = BackbufferError.microphonePermissionDenied.localizedDescription
                throw BackbufferError.microphonePermissionDenied
            }
        case .denied, .restricted:
            stop()
            lastErrorMessage = BackbufferError.microphonePermissionDenied.localizedDescription
            throw BackbufferError.microphonePermissionDenied
        }

        let normalizedID: String? = (deviceID == nil || deviceID == MicrophoneDeviceOption.systemDefaultID || deviceID?.isEmpty == true)
            ? nil
            : deviceID

        if availableDevices.isEmpty {
            refreshDevices()
        }

        do {
            try await relay.startSession(
                deviceID: normalizedID,
                isMuted: isMuted,
                ringBuffer: ringBuffer,
                enablePreviewMeterOnly: enablePreviewMeterOnly
            )
        } catch {
            relay.stopSession()
            isRunning = false
            activeDeviceID = nil
            isPreviewMeterOnly = false
            inputLevel = 0.0
            suspectedSilentTCCLock = false
            lastErrorMessage = error.localizedDescription
            throw error
        }

        isRunning = relay.currentIsRunning
        activeDeviceID = normalizedID
        isPreviewMeterOnly = enablePreviewMeterOnly
        if isMuted {
            inputLevel = 0.0
            suspectedSilentTCCLock = false
        }
    }

    func updateOutputTarget(
        ringBuffer: ReplayRingBuffer?,
        enablePreviewMeterOnly: Bool,
        isMuted: Bool
    ) {
        isPreviewMeterOnly = enablePreviewMeterOnly
        if isMuted {
            inputLevel = 0.0
            suspectedSilentTCCLock = false
        }
        relay.updateOutputTarget(
            ringBuffer: ringBuffer,
            enablePreviewMeterOnly: enablePreviewMeterOnly,
            isMuted: isMuted
        )
    }

    func stop() {
        relay.stopSession()
        isRunning = false
        activeDeviceID = nil
        isPreviewMeterOnly = false
        inputLevel = 0.0
        lastErrorMessage = nil
        suspectedSilentTCCLock = false
    }

    func setMuted(_ muted: Bool) {
        relay.setMuted(muted)
        if muted {
            inputLevel = 0.0
            suspectedSilentTCCLock = false
        }
    }

    func setPreviewState(
        devices: [MicrophoneDeviceOption],
        level: Double,
        permission: MicrophonePermissionState
    ) {
        availableDevices = devices
        inputLevel = min(1.0, max(0.0, level))
        permissionState = permission
    }

    fileprivate func applyMeasuredState(level: Double, suspectedSilent: Bool) {
        inputLevel = min(1.0, max(0.0, level))
        if suspectedSilentTCCLock != suspectedSilent {
            suspectedSilentTCCLock = suspectedSilent
        }
        if level > 0.0, lastErrorMessage != nil {
            lastErrorMessage = nil
        }
    }

    fileprivate func applyRuntimeError(_ message: String) {
        lastErrorMessage = message
    }

    private static func readPermissionState() -> MicrophonePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }
}
