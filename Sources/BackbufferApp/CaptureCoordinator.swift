import AppKit
import BackbufferCore
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Capture Target & State

enum CaptureTarget: Identifiable, Hashable, @unchecked Sendable {
    case display(SCDisplay)
    case window(SCWindow)

    var id: String {
        switch self {
        case .display(let display):
            return "display-\(display.displayID)"
        case .window(let window):
            return "window-\(window.windowID)"
        }
    }

    var isDisplay: Bool {
        if case .display = self { return true }
        return false
    }

    var systemImageName: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        }
    }

    var title: String {
        switch self {
        case .display(let display):
            if display.displayID == CGMainDisplayID() {
                return "Main Display"
            }
            return "Display \(display.displayID)"
        case .window(let window):
            let appName = window.owningApplication?.applicationName ?? "App"
            let rawTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if rawTitle.isEmpty || rawTitle == appName {
                return appName
            }
            return "\(appName) — \(rawTitle)"
        }
    }

    var subtitle: String {
        switch self {
        case .display(let display):
            return "\(display.width)×\(display.height) pts"
        case .window(let window):
            let w = Int(window.frame.width.rounded())
            let h = Int(window.frame.height.rounded())
            return "\(window.owningApplication?.applicationName ?? "Window") · \(w)×\(h)"
        }
    }

    var logicalSize: CGSize {
        switch self {
        case .display(let display):
            return CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        case .window(let window):
            return window.frame.size
        }
    }

    static func == (lhs: CaptureTarget, rhs: CaptureTarget) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum CaptureState: Equatable, Sendable {
    case idle
    case buffering(secondsBuffered: Double, estimatedRAMBytes: Int64)
    case paused
    case permissionDenied
    case error(String)

    var isActivelyBuffering: Bool {
        if case .buffering = self { return true }
        return false
    }
}

// MARK: - Non-Isolated Stream Callback Relay

private final class StreamPipelineRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let ringBuffer: ReplayRingBuffer
    let encoder: VideoEncoder

    private let pauseLock = NSLock()
    private var _isPaused: Bool = false
    private let onStreamStopped: @Sendable (Error?) -> Void

    init(
        ringBuffer: ReplayRingBuffer,
        encoder: VideoEncoder,
        onStreamStopped: @escaping @Sendable (Error?) -> Void
    ) {
        self.ringBuffer = ringBuffer
        self.encoder = encoder
        self.onStreamStopped = onStreamStopped
        super.init()
    }

    func setPaused(_ paused: Bool) {
        pauseLock.lock()
        _isPaused = paused
        pauseLock.unlock()
        encoder.setKeepalivePaused(paused)
    }

    private var isPaused: Bool {
        pauseLock.lock()
        let val = _isPaused
        pauseLock.unlock()
        return val
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard !isPaused else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleAudioSample(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped(error)
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [NSDictionary],
              let first = attachments.first,
              let rawStatus = first[SCStreamFrameInfo.status.rawValue] as? Int,
              let frameStatus = SCFrameStatus(rawValue: rawStatus),
              frameStatus == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        try? encoder.ingestLivePixelBuffer(pixelBuffer, presentationTimeStamp: pts)
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let chunk = Self.extractInterleavedInt16Chunk(from: sampleBuffer) else {
            return
        }
        ringBuffer.appendAudio(chunk)
    }

    /// Converts incoming ScreenCaptureKit audio (commonly non-interleaved 32-bit float LPCM)
    /// into packed interleaved 16-bit signed integer PCM so `ReplayRingBuffer` stays compact
    /// and `ClipMuxer` receives canonical single-buffer LPCM matching `TestMediaFactory`.
    private static func extractInterleavedInt16Chunk(from sampleBuffer: CMSampleBuffer) -> BufferedAudioChunk? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        let srcASBD = asbdPtr.pointee
        guard srcASBD.mFormatID == kAudioFormatLinearPCM else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

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
        let outChannels = 2
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
                    let maxFrames = min(numSamples, totalFloats / sourceChannels)
                    for i in 0..<maxFrames {
                        let left = ptr[i * sourceChannels]
                        let right = sourceChannels > 1 ? ptr[i * sourceChannels + 1] : left
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
                    let maxFrames = min(numSamples, totalSamples / sourceChannels)
                    for i in 0..<maxFrames {
                        let left = ptr[i * sourceChannels]
                        let right = sourceChannels > 1 ? ptr[i * sourceChannels + 1] : left
                        interleaved[i * 2] = left
                        interleaved[i * 2 + 1] = right
                    }
                    return true
                }
                return false
            }
            return false
        }
        guard copySucceeded else { return nil }

        let bytesPerFrame = UInt32(MemoryLayout<Int16>.size * outChannels)
        let sampleRate = srcASBD.mSampleRate > 0 ? srcASBD.mSampleRate : 48_000.0
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

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let rawDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration: CMTime
        if CMTIME_IS_VALID(rawDuration), CMTimeGetSeconds(rawDuration) > 0 {
            duration = rawDuration
        } else {
            duration = CMTime(value: CMTimeValue(numSamples), timescale: Int32(sampleRate.rounded()))
        }

        let data = interleaved.withUnsafeBytes { Data($0) }
        return BufferedAudioChunk(
            pts: pts,
            duration: duration,
            pcmData: data,
            asbd: outASBD,
            frameCount: UInt32(numSamples)
        )
    }

    @inline(__always)
    private static func floatToInt16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value.isFinite ? value : 0.0))
        return Int16((clamped * 32767.0).rounded())
    }
}

private final class CoordinatorTaskBag: @unchecked Sendable {
    var statsTask: Task<Void, Never>?

    deinit {
        statsTask?.cancel()
    }
}

// MARK: - CaptureCoordinator

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published private(set) var availableWindows: [SCWindow] = []
    @Published private(set) var activeTarget: CaptureTarget?
    @Published private(set) var activePixelDimensions: (width: Int, height: Int)?
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isSaving: Bool = false
    @Published private(set) var lastSavedURL: URL?

    private let videoQueue = DispatchQueue(label: "io.malachiteore.backbuffer.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "io.malachiteore.backbuffer.capture.audio", qos: .userInteractive)

    private var stream: SCStream?
    private var relay: StreamPipelineRelay?
    private let taskBag = CoordinatorTaskBag()
    private var currentSettings: CaptureSettings?

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    func availableTargets() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        guard CGPreflightScreenCaptureAccess() else {
            state = .permissionDenied
            throw BackbufferError.screenRecordingPermissionDenied
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let filteredWindows = content.windows.filter { window in
                guard window.windowLayer == 0 else { return false }
                guard window.frame.width >= 200, window.frame.height >= 150 else { return false }
                guard let app = window.owningApplication else { return false }
                if app.processID == ownPID { return false }
                let bundle = app.bundleIdentifier
                if bundle == "com.apple.dock" || bundle == "com.apple.WindowManager" || bundle == "com.apple.controlcenter" {
                    return false
                }
                return true
            }
            availableDisplays = content.displays
            availableWindows = filteredWindows
            return (content.displays, filteredWindows)
        } catch {
            if Self.isPermissionError(error) {
                state = .permissionDenied
                throw BackbufferError.screenRecordingPermissionDenied
            }
            throw BackbufferError.captureStartFailed(error.localizedDescription)
        }
    }

    func startCapture(target: CaptureTarget, settings: CaptureSettings) async throws {
        await stopCapture()

        guard CGPreflightScreenCaptureAccess() else {
            state = .permissionDenied
            throw BackbufferError.screenRecordingPermissionDenied
        }

        let filter: SCContentFilter
        switch target {
        case .display(let display):
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        case .window(let window):
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let scale = resolvePointPixelScale(for: target, filter: filter)
        let logical = target.logicalSize
        let dims = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: logical.width,
            logicalHeight: logical.height,
            pointPixelScale: scale,
            cap: settings.resolutionCap
        )

        let pixelSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        let bitrates = SettingsStore.bitratePair(
            for: settings.quality,
            resolutionCap: settings.resolutionCap,
            fps: settings.fps,
            targetPixelSize: pixelSize
        )

        let ringBuffer = ReplayRingBuffer(
            maxBufferSeconds: settings.bufferDuration.seconds,
            headroomSeconds: 2.0
        )

        let encoder = try VideoEncoder(
            width: dims.width,
            height: dims.height,
            codec: settings.codec,
            bitrateBps: bitrates.videoBps,
            fps: settings.fps.rawValue,
            maxKeyframeIntervalSeconds: 1.0,
            enableCFRKeepalive: true,
            onPacket: { packet in
                ringBuffer.appendVideo(packet)
            },
            onError: { [weak self] encoderError in
                Task { @MainActor [weak self] in
                    self?.state = .error(encoderError.localizedDescription)
                }
            }
        )

        let newRelay = StreamPipelineRelay(
            ringBuffer: ringBuffer,
            encoder: encoder,
            onStreamStopped: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handleUnexpectedStreamStop(error: error)
                }
            }
        )

        let config = SCStreamConfiguration()
        config.width = dims.width
        config.height = dims.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.fps.rawValue))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let newStream = SCStream(filter: filter, configuration: config, delegate: newRelay)

        do {
            try newStream.addStreamOutput(newRelay, type: .screen, sampleHandlerQueue: videoQueue)
            try newStream.addStreamOutput(newRelay, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()
        } catch {
            encoder.invalidate()
            if Self.isPermissionError(error) {
                state = .permissionDenied
                throw BackbufferError.screenRecordingPermissionDenied
            }
            state = .error(error.localizedDescription)
            throw BackbufferError.captureStartFailed(error.localizedDescription)
        }

        self.stream = newStream
        self.relay = newRelay
        self.activeTarget = target
        self.activePixelDimensions = dims
        self.currentSettings = settings
        self.isPaused = false
        self.state = .buffering(secondsBuffered: 0, estimatedRAMBytes: 0)

        startStatsPolling()
    }

    func stopCapture() async {
        taskBag.statsTask?.cancel()
        taskBag.statsTask = nil

        let oldStream = stream
        let oldRelay = relay
        stream = nil
        relay = nil
        activePixelDimensions = nil
        isPaused = false

        if let oldStream {
            try? await oldStream.stopCapture()
        }
        oldRelay?.encoder.invalidate()
        oldRelay?.ringBuffer.clear()

        if state != .permissionDenied {
            state = .idle
        }
    }

    func pauseBuffering() {
        guard let relay, !isPaused else { return }
        isPaused = true
        relay.setPaused(true)
        state = .paused
    }

    func resumeBuffering() {
        guard let relay, isPaused else { return }
        isPaused = false
        relay.setPaused(false)
        let stats = relay.ringBuffer.currentStats()
        state = .buffering(
            secondsBuffered: stats.bufferedSeconds,
            estimatedRAMBytes: Int64(stats.estimatedBytes)
        )
    }

    func updateBufferDurationIfActive(_ duration: BufferDurationOption) {
        relay?.ringBuffer.updateMaxBufferSeconds(duration.seconds)
        currentSettings?.bufferDuration = duration
    }

    func saveCurrentBuffer(
        libraryStore: ClipLibraryStore,
        activeCap: ShareCapOption,
        audioBitrateBps: Int = 160_000
    ) async throws -> URL {
        _ = activeCap
        guard let relay else {
            throw BackbufferError.emptyBuffer
        }

        isSaving = true
        defer { isSaving = false }

        let snapshot = relay.ringBuffer.snapshot()
        guard !snapshot.video.isEmpty else {
            throw BackbufferError.emptyBuffer
        }

        try libraryStore.ensureDirectoriesExist()
        let outputURL = libraryStore.nextMasterURL(for: Date())
        let audioTracks: [AudioTrackInput] = snapshot.audio.isEmpty
            ? []
            : [AudioTrackInput(trackID: "system", chunks: snapshot.audio, aacBitrateBps: audioBitrateBps)]

        try await ClipMuxer.writeMP4(
            videoPackets: snapshot.video,
            audioTracks: audioTracks,
            to: outputURL
        )

        lastSavedURL = outputURL
        return outputURL
    }

    // MARK: - Helpers

    private func startStatsPolling() {
        taskBag.statsTask?.cancel()
        taskBag.statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { break }
                guard let relay = self.relay else { continue }
                if !self.isPaused {
                    let stats = relay.ringBuffer.currentStats()
                    self.state = .buffering(
                        secondsBuffered: stats.bufferedSeconds,
                        estimatedRAMBytes: Int64(stats.estimatedBytes)
                    )
                }
            }
        }
    }

    private func handleUnexpectedStreamStop(error: Error?) async {
        taskBag.statsTask?.cancel()
        taskBag.statsTask = nil
        let oldRelay = relay
        stream = nil
        relay = nil
        isPaused = false
        oldRelay?.encoder.invalidate()
        oldRelay?.ringBuffer.clear()

        if let error {
            if Self.isPermissionError(error) {
                state = .permissionDenied
            } else {
                state = .error("Capture target closed or interrupted: \(error.localizedDescription)")
            }
        } else {
            state = .idle
        }
    }

    private func resolvePointPixelScale(for target: CaptureTarget, filter: SCContentFilter) -> CGFloat {
        if #available(macOS 14.0, *) {
            let scale = CGFloat(filter.pointPixelScale)
            if scale > 0 {
                return scale
            }
        }

        switch target {
        case .display(let display):
            if let screen = Self.screen(forDisplayID: display.displayID) {
                return screen.backingScaleFactor
            }
        case .window(let window):
            if let bestDisplay = availableDisplays.max(by: { lhs, rhs in
                let areaL = Self.intersectionArea(lhs.frame, window.frame)
                let areaR = Self.intersectionArea(rhs.frame, window.frame)
                return areaL < areaR
            }), Self.intersectionArea(bestDisplay.frame, window.frame) > 0,
               let screen = Self.screen(forDisplayID: bestDisplay.displayID) {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        return inter.width * inter.height
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain, nsError.code == -3801 {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("declined") || message.contains("permission") || message.contains("tcc")
    }
}
