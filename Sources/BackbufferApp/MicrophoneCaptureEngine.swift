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

private final class MicCaptureRelay: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let stateLock = NSLock()
    private let sessionQueue = DispatchQueue(label: "io.malachiteore.backbuffer.microphone.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "io.malachiteore.backbuffer.microphone.samples", qos: .userInteractive)

    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var ringBuffer: ReplayRingBuffer?
    private var isMuted: Bool = false
    private var enablePreviewMeterOnly: Bool = false
    private var generation: UInt64 = 0
    private var lastMeterUptime: TimeInterval = 0

    weak var engine: MicrophoneCaptureEngine?

    var currentIsRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session != nil
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        isMuted = muted
        let gen = generation
        stateLock.unlock()

        if muted {
            postMeterLevel(0.0, generation: gen)
        }
    }

    func startSession(
        deviceID: String?,
        isMuted: Bool,
        ringBuffer: ReplayRingBuffer?,
        enablePreviewMeterOnly: Bool
    ) async throws {
        stateLock.lock()
        generation &+= 1
        let targetGeneration = generation
        let previousSession = session
        session = nil
        audioOutput = nil
        self.ringBuffer = ringBuffer
        self.isMuted = isMuted
        self.enablePreviewMeterOnly = enablePreviewMeterOnly
        self.lastMeterUptime = 0
        stateLock.unlock()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                previousSession?.stopRunning()

                guard let self else {
                    continuation.resume(returning: ())
                    return
                }

                // Abort startup early if stop() or another start() already superseded this generation.
                self.stateLock.lock()
                let isCurrent = (self.generation == targetGeneration)
                self.stateLock.unlock()
                guard isCurrent else {
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
                    newOutput.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 48_000.0,
                        AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                    newOutput.setSampleBufferDelegate(self, queue: self.sampleQueue)

                    guard newSession.canAddOutput(newOutput) else {
                        newSession.commitConfiguration()
                        continuation.resume(throwing: BackbufferError.captureStartFailed("Unable to configure PCM audio output for microphone."))
                        return
                    }
                    newSession.addOutput(newOutput)
                    newSession.commitConfiguration()

                    newSession.startRunning()

                    self.stateLock.lock()
                    let stillCurrent = (self.generation == targetGeneration)
                    if stillCurrent {
                        self.session = newSession
                        self.audioOutput = newOutput
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
        let oldSession = session
        session = nil
        audioOutput = nil
        ringBuffer = nil
        enablePreviewMeterOnly = false
        lastMeterUptime = 0
        stateLock.unlock()

        if let oldSession {
            sessionQueue.async {
                oldSession.stopRunning()
            }
        }
        postMeterLevel(0.0, generation: gen)
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

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isValid, rawPTS.isNumeric else { return }

        let syncClock = currentSession.synchronizationClock ?? CMClockGetHostTimeClock()
        let hostPTS = CMSyncConvertTime(rawPTS, from: syncClock, to: CMClockGetHostTimeClock())
        guard hostPTS.isValid, hostPTS.isNumeric else { return }

        guard let extracted = Self.extractInterleavedInt16Chunk(
            from: sampleBuffer,
            pts: hostPTS,
            zeroOut: muted
        ) else {
            return
        }

        if !previewOnly, let currentRingBuffer {
            currentRingBuffer.appendMicAudio(extracted.chunk)
        }

        let now = ProcessInfo.processInfo.systemUptime
        var shouldUpdateMeter = false
        stateLock.lock()
        if (now - lastMeterUptime) >= 0.04 {
            lastMeterUptime = now
            shouldUpdateMeter = true
        }
        stateLock.unlock()

        if shouldUpdateMeter {
            postMeterLevel(muted ? 0.0 : extracted.level, generation: gen)
        }
    }

    private func isGenerationCurrent(_ targetGeneration: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == targetGeneration
    }

    private func postMeterLevel(_ level: Double, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.isGenerationCurrent(generation) else { return }
            self.engine?.applyMeasuredLevel(level)
        }
    }

    private static func extractInterleavedInt16Chunk(
        from sampleBuffer: CMSampleBuffer,
        pts: CMTime,
        zeroOut: Bool
    ) -> (chunk: BufferedAudioChunk, level: Double)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        let srcASBD = asbdPtr.pointee
        guard srcASBD.mFormatID == kAudioFormatLinearPCM else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        let outChannels = 2
        let sampleRate = srcASBD.mSampleRate > 0 ? srcASBD.mSampleRate : 48_000.0
        let bytesPerFrame = UInt32(MemoryLayout<Int16>.size * outChannels)
        let outASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(outChannels),
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let rawDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration: CMTime
        if CMTIME_IS_VALID(rawDuration), CMTimeGetSeconds(rawDuration) > 0 {
            duration = rawDuration
        } else {
            duration = CMTime(value: CMTimeValue(numSamples), timescale: Int32(sampleRate.rounded()))
        }

        if zeroOut {
            let zeroData = Data(count: numSamples * outChannels * MemoryLayout<Int16>.size)
            let chunk = BufferedAudioChunk(
                pts: pts,
                duration: duration,
                pcmData: zeroData,
                asbd: outASBD,
                frameCount: UInt32(numSamples)
            )
            return (chunk, 0.0)
        }

        var blockBufferOut: CMBlockBuffer?
        var bufferListSizeNeeded = 0
        let sizeQueryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeQueryStatus == noErr || bufferListSizeNeeded > 0 else { return nil }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: max(bufferListSizeNeeded, MemoryLayout<AudioBufferList>.size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawABL.deallocate() }

        let ablPtr = rawABL.assumingMemoryBound(to: AudioBufferList.self)
        let fetchStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBufferOut
        )
        guard fetchStatus == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        let sourceChannels = max(1, Int(srcASBD.mChannelsPerFrame))
        let isFloat = (srcASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (srcASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bitsPerChannel = Int(srcASBD.mBitsPerChannel)

        var interleaved = [Int16](repeating: 0, count: numSamples * outChannels)

        let copySucceeded = withExtendedLifetime(blockBufferOut) {
            if isFloat && bitsPerChannel == 32 {
                if isNonInterleaved && buffers.count >= 2 {
                    guard let ch0 = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                          let ch1 = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                        return false
                    }
                    let maxFrames = min(
                        numSamples,
                        Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size,
                        Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
                    )
                    for i in 0..<maxFrames {
                        interleaved[i * 2] = floatToInt16(ch0[i])
                        interleaved[i * 2 + 1] = floatToInt16(ch1[i])
                    }
                    return true
                } else if let buf0 = buffers.first, let ptr = buf0.mData?.assumingMemoryBound(to: Float.self) {
                    let totalFloats = Int(buf0.mDataByteSize) / MemoryLayout<Float>.size
                    let maxFrames = isNonInterleaved
                        ? min(numSamples, totalFloats)
                        : min(numSamples, totalFloats / sourceChannels)
                    for i in 0..<maxFrames {
                        let left = isNonInterleaved ? ptr[i] : ptr[i * sourceChannels]
                        let right = (!isNonInterleaved && sourceChannels > 1) ? ptr[i * sourceChannels + 1] : left
                        interleaved[i * 2] = floatToInt16(left)
                        interleaved[i * 2 + 1] = floatToInt16(right)
                    }
                    return true
                }
                return false
            } else if !isFloat && bitsPerChannel == 16 {
                if isNonInterleaved && buffers.count >= 2 {
                    guard let ch0 = buffers[0].mData?.assumingMemoryBound(to: Int16.self),
                          let ch1 = buffers[1].mData?.assumingMemoryBound(to: Int16.self) else {
                        return false
                    }
                    let maxFrames = min(
                        numSamples,
                        Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size,
                        Int(buffers[1].mDataByteSize) / MemoryLayout<Int16>.size
                    )
                    for i in 0..<maxFrames {
                        interleaved[i * 2] = ch0[i]
                        interleaved[i * 2 + 1] = ch1[i]
                    }
                    return true
                } else if let buf0 = buffers.first, let ptr = buf0.mData?.assumingMemoryBound(to: Int16.self) {
                    let totalSamples = Int(buf0.mDataByteSize) / MemoryLayout<Int16>.size
                    let maxFrames = isNonInterleaved
                        ? min(numSamples, totalSamples)
                        : min(numSamples, totalSamples / sourceChannels)
                    for i in 0..<maxFrames {
                        let left = isNonInterleaved ? ptr[i] : ptr[i * sourceChannels]
                        let right = (!isNonInterleaved && sourceChannels > 1) ? ptr[i * sourceChannels + 1] : left
                        interleaved[i * 2] = left
                        interleaved[i * 2 + 1] = right
                    }
                    return true
                }
                return false
            } else if !isFloat && bitsPerChannel == 32 {
                if isNonInterleaved && buffers.count >= 2 {
                    guard let ch0 = buffers[0].mData?.assumingMemoryBound(to: Int32.self),
                          let ch1 = buffers[1].mData?.assumingMemoryBound(to: Int32.self) else {
                        return false
                    }
                    let maxFrames = min(
                        numSamples,
                        Int(buffers[0].mDataByteSize) / MemoryLayout<Int32>.size,
                        Int(buffers[1].mDataByteSize) / MemoryLayout<Int32>.size
                    )
                    for i in 0..<maxFrames {
                        interleaved[i * 2] = Int16(clamping: ch0[i] >> 16)
                        interleaved[i * 2 + 1] = Int16(clamping: ch1[i] >> 16)
                    }
                    return true
                } else if let buf0 = buffers.first, let ptr = buf0.mData?.assumingMemoryBound(to: Int32.self) {
                    let totalSamples = Int(buf0.mDataByteSize) / MemoryLayout<Int32>.size
                    let maxFrames = isNonInterleaved
                        ? min(numSamples, totalSamples)
                        : min(numSamples, totalSamples / sourceChannels)
                    for i in 0..<maxFrames {
                        let left = isNonInterleaved ? ptr[i] : ptr[i * sourceChannels]
                        let right = (!isNonInterleaved && sourceChannels > 1) ? ptr[i * sourceChannels + 1] : left
                        interleaved[i * 2] = Int16(clamping: left >> 16)
                        interleaved[i * 2 + 1] = Int16(clamping: right >> 16)
                    }
                    return true
                }
                return false
            }
            return false
        }
        guard copySucceeded else { return nil }

        var sumSquares: Double = 0.0
        for sample in interleaved {
            let norm = Double(sample) / 32768.0
            sumSquares += norm * norm
        }
        let rms = sqrt(sumSquares / Double(max(1, interleaved.count)))
        let level: Double
        if rms <= 0.0001 {
            level = 0.0
        } else {
            let decibels = 20.0 * log10(rms)
            level = min(1.0, max(0.0, (decibels + 50.0) / 50.0))
        }

        let pcmData = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        let chunk = BufferedAudioChunk(
            pts: pts,
            duration: duration,
            pcmData: pcmData,
            asbd: outASBD,
            frameCount: UInt32(numSamples)
        )
        return (chunk, level)
    }

    private static func floatToInt16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        if clamped >= 1.0 { return Int16.max }
        if clamped <= -1.0 { return Int16.min }
        return Int16((clamped * 32767.0).rounded())
    }
}

@MainActor
final class MicrophoneCaptureEngine: ObservableObject {
    @Published private(set) var availableDevices: [MicrophoneDeviceOption] = []
    @Published private(set) var inputLevel: Double = 0.0
    @Published private(set) var permissionState: MicrophonePermissionState = .notDetermined

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
        let perm = currentPermissionState()
        switch perm {
        case .authorized:
            break
        case .notDetermined:
            let granted = await requestPermissionIfNeeded()
            if !granted {
                stop()
                throw BackbufferError.microphonePermissionDenied
            }
        case .denied, .restricted:
            stop()
            throw BackbufferError.microphonePermissionDenied
        }

        let normalizedID: String? = (deviceID == nil || deviceID == MicrophoneDeviceOption.systemDefaultID || deviceID?.isEmpty == true)
            ? nil
            : deviceID

        if availableDevices.isEmpty {
            refreshDevices()
        }

        try await relay.startSession(
            deviceID: normalizedID,
            isMuted: isMuted,
            ringBuffer: ringBuffer,
            enablePreviewMeterOnly: enablePreviewMeterOnly
        )

        isRunning = relay.currentIsRunning
        activeDeviceID = normalizedID
        isPreviewMeterOnly = enablePreviewMeterOnly
        if isMuted {
            inputLevel = 0.0
        }
    }

    func stop() {
        relay.stopSession()
        isRunning = false
        activeDeviceID = nil
        isPreviewMeterOnly = false
        inputLevel = 0.0
    }

    func setMuted(_ muted: Bool) {
        relay.setMuted(muted)
        if muted {
            inputLevel = 0.0
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

    fileprivate func applyMeasuredLevel(_ level: Double) {
        inputLevel = min(1.0, max(0.0, level))
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
