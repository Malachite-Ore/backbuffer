import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum ClipCompressor {
    /// Computes target video & AAC audio bitrates and whether to downscale to 720p
    /// so the resulting Share MP4 reliably fits under `capBytes`.
    public static func computeTargetBitrate(
        capBytes: Int64,
        durationSeconds: Double
    ) -> (videoBps: Int, audioBps: Int, shouldDownscaleTo720p: Bool) {
        let safeDuration = max(0.25, durationSeconds.isFinite ? durationSeconds : 1.0)
        let safeCapBytes = max(Int64(64_000), capBytes)
        let targetBytes = Double(safeCapBytes) * 0.94
        let totalBudgetBps = (targetBytes * 8.0) / safeDuration

        let tenMegabytesBytes: Int64 = 10 * 1024 * 1024
        var audioBps = (safeDuration > 90.0 && safeCapBytes <= tenMegabytesBytes) ? 96_000 : 128_000
        if totalBudgetBps < 480_000 {
            audioBps = min(audioBps, max(48_000, Int(totalBudgetBps * 0.20)))
        }

        let rawVideoBps = Int(totalBudgetBps) - audioBps
        let videoFloor = min(350_000, max(48_000, Int(totalBudgetBps * 0.72)))
        let videoBps = max(videoFloor, rawVideoBps)
        let shouldDownscaleTo720p = videoBps < 1_200_000

        return (
            videoBps: videoBps,
            audioBps: audioBps,
            shouldDownscaleTo720p: shouldDownscaleTo720p
        )
    }

    /// Compresses `masterURL` into `outputURL` targeting `<= capBytes` if `masterURL`
    /// exceeds the 96% container safety threshold; otherwise returns `masterURL` untouched
    /// without writing a redundant file at `outputURL`.
    @discardableResult
    public static func compressIfNeeded(
        masterURL: URL,
        outputURL: URL,
        capBytes: Int64,
        codec: VideoCodecChoice
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: masterURL.path) else {
            throw BackbufferError.libraryIOFailed("Master clip not found at \(masterURL.path)")
        }
        guard capBytes > 0 else {
            throw BackbufferError.compressionFailed("Target capBytes must be positive.")
        }

        let masterBytes = try fileSize(of: masterURL)
        let passthroughThreshold = Int64(Double(capBytes) * 0.96)
        if masterBytes <= passthroughThreshold {
            return masterURL
        }

        return try await compressInternal(
            sourceURL: masterURL,
            outputURL: outputURL,
            timeRange: nil,
            capBytes: capBytes,
            codec: codec
        )
    }

    /// Transcodes a sub-range of `masterURL` into `outputURL` capped strictly to `<= capBytes`.
    @discardableResult
    public static func compressRange(
        masterURL: URL,
        timeRange: CMTimeRange,
        outputURL: URL,
        capBytes: Int64,
        codec: VideoCodecChoice
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: masterURL.path) else {
            throw BackbufferError.libraryIOFailed("Master clip not found at \(masterURL.path)")
        }
        guard capBytes > 0 else {
            throw BackbufferError.compressionFailed("Target capBytes must be positive.")
        }
        guard CMTIME_IS_VALID(timeRange.start),
              CMTIME_IS_VALID(timeRange.duration),
              CMTimeGetSeconds(timeRange.duration) > 0 else {
            throw BackbufferError.trimRangeInvalid
        }

        return try await compressInternal(
            sourceURL: masterURL,
            outputURL: outputURL,
            timeRange: timeRange,
            capBytes: capBytes,
            codec: codec
        )
    }

    // MARK: - Internal Transcode Pipeline

    private static func compressInternal(
        sourceURL: URL,
        outputURL: URL,
        timeRange: CMTimeRange?,
        capBytes: Int64,
        codec: VideoCodecChoice
    ) async throws -> URL {
        guard sourceURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw BackbufferError.compressionFailed("Share output URL must differ from source master URL.")
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw BackbufferError.libraryIOFailed("Failed to create output directory: \(error.localizedDescription)")
        }

        let asset = AVURLAsset(url: sourceURL)
        let fullDuration = try await asset.load(.duration)
        let fullDurationSeconds = CMTimeGetSeconds(fullDuration)
        guard fullDurationSeconds.isFinite, fullDurationSeconds > 0 else {
            throw BackbufferError.compressionFailed("Source clip has invalid duration.")
        }

        let targetDurationSeconds: Double
        if let timeRange {
            let rangeSeconds = CMTimeGetSeconds(timeRange.duration)
            guard rangeSeconds.isFinite, rangeSeconds > 0 else {
                throw BackbufferError.trimRangeInvalid
            }
            targetDurationSeconds = rangeSeconds
        } else {
            targetDurationSeconds = fullDurationSeconds
        }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw BackbufferError.missingAssetTrack("video")
        }
        let allAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioTracks: [AVAssetTrack] = []
        audioTracks.reserveCapacity(allAudioTracks.count)
        for track in allAudioTracks {
            if (try? await track.load(.isEnabled)) == true {
                audioTracks.append(track)
            }
        }
        if audioTracks.isEmpty, let firstTrack = allAudioTracks.first {
            // Legacy fallback if a source file has all audio tracks marked disabled.
            audioTracks = [firstTrack]
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = max(1, min(240, Int((nominalFPS > 0 ? nominalFPS : 30.0).rounded())))

        let initialPlan = computeTargetBitrate(capBytes: capBytes, durationSeconds: targetDurationSeconds)
        var currentVideoBps = initialPlan.videoBps
        var currentAudioBps = audioTracks.isEmpty ? 0 : initialPlan.audioBps
        var forceDownscale = initialPlan.shouldDownscaleTo720p
        var emergencyScaleFactor: CGFloat = 1.0

        let maxAttempts = 3
        var lastMeasuredBytes: Int64 = 0

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()

            let targetSize = targetDimensions(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                downscaleTo720p: forceDownscale,
                additionalScaleFactor: emergencyScaleFactor
            )

            let tempURL = fm.temporaryDirectory.appendingPathComponent("backbuffer-compress-\(UUID().uuidString).mp4")
            defer {
                if fm.fileExists(atPath: tempURL.path) {
                    try? fm.removeItem(at: tempURL)
                }
            }

            try await runTranscodePass(
                asset: asset,
                videoTrack: videoTrack,
                audioTracks: audioTracks,
                preferredTransform: preferredTransform,
                timeRange: timeRange,
                destinationURL: tempURL,
                codec: codec,
                width: targetSize.width,
                height: targetSize.height,
                fps: fps,
                videoBitrateBps: currentVideoBps,
                audioBitrateBps: currentAudioBps
            )

            let producedBytes = try fileSize(of: tempURL)
            lastMeasuredBytes = producedBytes

            if producedBytes <= capBytes {
                try moveReplacingExisting(from: tempURL, to: outputURL)
                return outputURL
            }

            if attempt < maxAttempts {
                let proportionalScale = (Double(capBytes) * 0.88) / Double(max(1, producedBytes))
                let retryMultiplier = attempt == 1
                    ? min(0.85, max(0.30, proportionalScale))
                    : min(0.75, max(0.25, proportionalScale * 0.85))
                currentVideoBps = max(48_000, Int(Double(currentVideoBps) * retryMultiplier))
                if currentVideoBps < 1_200_000 {
                    forceDownscale = true
                }
                if attempt == 2 {
                    if currentAudioBps > 64_000 {
                        currentAudioBps = 64_000
                    }
                    // Step down spatial resolution only as a final safeguard if bitrate throttling alone
                    // hit the codec's minimum QP floor on high-entropy frames.
                    emergencyScaleFactor = 0.65
                }
            }
        }

        throw BackbufferError.compressionFailed(
            "Compressed output (\(lastMeasuredBytes) bytes) still exceeds cap (\(capBytes) bytes)."
        )
    }

    private static func targetDimensions(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        downscaleTo720p: Bool,
        additionalScaleFactor: CGFloat
    ) -> (width: Int, height: Int) {
        let isRotated = abs(preferredTransform.b) > 0.5 || abs(preferredTransform.c) > 0.5
        let baseDims: (width: Int, height: Int)
        if !isRotated {
            baseDims = CaptureDimensionCalculator.computeTargetDimensions(
                logicalWidth: naturalSize.width,
                logicalHeight: naturalSize.height,
                pointPixelScale: 1.0,
                cap: downscaleTo720p ? .p720 : .native
            )
        } else {
            let transformed = naturalSize.applying(preferredTransform)
            let visualHeight = abs(transformed.height)
            var codedWidth = max(2.0, naturalSize.width)
            var codedHeight = max(2.0, naturalSize.height)

            if downscaleTo720p, visualHeight > 720.0 {
                let scale = 720.0 / visualHeight
                codedWidth *= scale
                codedHeight *= scale
            }

            let maxCodedWidth = CGFloat(CaptureDimensionCalculator.maxIntelQuickSyncWidth)
            if codedWidth > maxCodedWidth {
                let scale = maxCodedWidth / codedWidth
                codedWidth *= scale
                codedHeight *= scale
            }

            baseDims = (
                width: CaptureDimensionCalculator.roundDownEven(codedWidth),
                height: CaptureDimensionCalculator.roundDownEven(codedHeight)
            )
        }

        guard additionalScaleFactor < 0.999 else {
            return baseDims
        }

        let scaledW = max(320.0, CGFloat(baseDims.width) * additionalScaleFactor)
        let scaledH = max(180.0, CGFloat(baseDims.height) * additionalScaleFactor)
        return (
            width: min(baseDims.width, CaptureDimensionCalculator.roundDownEven(scaledW)),
            height: min(baseDims.height, CaptureDimensionCalculator.roundDownEven(scaledH))
        )
    }

    private static func runTranscodePass(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        audioTracks: [AVAssetTrack],
        preferredTransform: CGAffineTransform,
        timeRange: CMTimeRange?,
        destinationURL: URL,
        codec: VideoCodecChoice,
        width: Int,
        height: Int,
        fps: Int,
        videoBitrateBps: Int,
        audioBitrateBps: Int
    ) async throws {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: .mp4)
        } catch {
            throw BackbufferError.compressionFailed("Failed to initialize reader/writer: \(error.localizedDescription)")
        }

        if let timeRange {
            reader.timeRange = timeRange
        }

        let videoReadSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReadSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw BackbufferError.compressionFailed("Cannot add video track output to AVAssetReader.")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?

        if !audioTracks.isEmpty, audioBitrateBps > 0 {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
            mixOutput.alwaysCopiesSampleData = false
            if reader.canAdd(mixOutput) {
                let aacSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: audioBitrateBps
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
                aInput.expectsMediaDataInRealTime = false
                if writer.canAdd(aInput) {
                    reader.add(mixOutput)
                    writer.add(aInput)
                    audioOutput = mixOutput
                    audioInput = aInput
                }
            }
        }

        guard reader.startReading() else {
            throw BackbufferError.compressionFailed(reader.error?.localizedDescription ?? "AVAssetReader failed to start reading.")
        }

        let vtTranscoder = try OfflineVTEncoder(
            width: width,
            height: height,
            codec: codec,
            bitrateBps: videoBitrateBps,
            fps: fps
        )
        defer {
            vtTranscoder.invalidate()
        }

        // Pull and encode the leading video frame first so we obtain an exact CMFormatDescription
        // for passthrough AVAssetWriterInput(outputSettings: nil).
        guard let firstDecodedSample = videoOutput.copyNextSampleBuffer() else {
            reader.cancelReading()
            throw BackbufferError.compressionFailed(
                reader.error?.localizedDescription ?? "Source video track contained no decodable frames."
            )
        }
        try vtTranscoder.encodeAndFlushLeadingSample(firstDecodedSample)

        guard let firstCompressedSample = vtTranscoder.peekLeadingPacket(),
              let videoFormatHint = CMSampleBufferGetFormatDescription(firstCompressedSample) else {
            reader.cancelReading()
            throw BackbufferError.compressionFailed("VideoToolbox did not emit a leading compressed frame.")
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatHint
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else {
            reader.cancelReading()
            throw BackbufferError.compressionFailed("Cannot add passthrough video input to AVAssetWriter.")
        }
        writer.add(videoInput)

        guard writer.startWriting() else {
            reader.cancelReading()
            throw BackbufferError.compressionFailed(writer.error?.localizedDescription ?? "AVAssetWriter failed to start writing.")
        }

        let sessionStartTime = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: sessionStartTime)

        let pump = TranscodePump(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            vtEncoder: vtTranscoder,
            audioOutput: audioOutput,
            audioInput: audioInput
        )
        await pump.run()

        if let encoderError = vtTranscoder.consumeError() {
            throw encoderError
        }
        if reader.status == .failed {
            throw BackbufferError.compressionFailed(reader.error?.localizedDescription ?? "AVAssetReader failed during transcode.")
        }
        if writer.status != .completed {
            throw BackbufferError.compressionFailed(writer.error?.localizedDescription ?? "AVAssetWriter finished with status \(writer.status.rawValue).")
        }
    }

    static func fileSize(of url: URL) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let sizeNumber = attributes[.size] as? NSNumber {
                return sizeNumber.int64Value
            }
            return 0
        } catch {
            throw BackbufferError.libraryIOFailed("Could not read file size at \(url.path): \(error.localizedDescription)")
        }
    }

    static func moveReplacingExisting(from sourceURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BackbufferError.libraryIOFailed("Failed to place output clip at \(destinationURL.path): \(error.localizedDescription)")
        }
    }
}

// MARK: - Offline VideoToolbox Transcoder (AVAssetReader -> VTCompressionSession -> AVAssetWriter)

private final class OfflineEncoderCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingPackets: [CMSampleBuffer] = []
    private var asyncError: BackbufferError?
    private var invalidated = false

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard !invalidated else { return }
            pendingPackets.append(sampleBuffer)
        }
    }

    func recordError(_ error: BackbufferError) {
        lock.withLock {
            if asyncError == nil {
                asyncError = error
            }
        }
    }

    func popPacket() -> CMSampleBuffer? {
        lock.withLock {
            guard !pendingPackets.isEmpty else { return nil }
            return pendingPackets.removeFirst()
        }
    }

    func peekPacket() -> CMSampleBuffer? {
        lock.withLock {
            pendingPackets.first
        }
    }

    func consumeError() -> BackbufferError? {
        lock.withLock {
            let err = asyncError
            asyncError = nil
            return err
        }
    }

    func markInvalidated() {
        lock.withLock {
            invalidated = true
            pendingPackets.removeAll()
        }
    }

    var isInvalidated: Bool {
        lock.withLock { invalidated }
    }
}

private func offlineCompressorOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let context = Unmanaged<OfflineEncoderCallbackContext>.fromOpaque(refCon).takeUnretainedValue()
    guard !context.isInvalidated else { return }

    if status != noErr {
        context.recordError(.compressionFailed("VideoToolbox compression callback failed (OSStatus \(status))."))
        return
    }
    if infoFlags.contains(.frameDropped) {
        return
    }
    guard let sampleBuffer,
          CMSampleBufferDataIsReady(sampleBuffer),
          CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
        return
    }
    context.append(sampleBuffer)
}

private final class OfflineVTEncoder: @unchecked Sendable {
    let width: Int
    let height: Int
    let fps: Int

    private var session: VTCompressionSession?
    private var transferPool: PixelTransferPool?
    private let context = OfflineEncoderCallbackContext()
    private var retainedRefCon: UnsafeMutableRawPointer?
    private var lastEncodedPTS: CMTime = .invalid
    private let fallbackFrameDuration: CMTime
    private var isInvalidated = false

    init(
        width: Int,
        height: Int,
        codec: VideoCodecChoice,
        bitrateBps: Int,
        fps: Int
    ) throws {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.fallbackFrameDuration = CMTime(value: 1, timescale: Int32(max(1, fps)))

        let refCon = Unmanaged.passRetained(context).toOpaque()

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        let hardwareSpec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
        ]

        var sessionOut: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.cmVideoCodecType,
            encoderSpecification: hardwareSpec as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: offlineCompressorOutputCallback,
            refcon: refCon,
            compressionSessionOut: &sessionOut
        )

        if status != noErr || sessionOut == nil {
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: codec.cmVideoCodecType,
                encoderSpecification: nil,
                imageBufferAttributes: sourceAttributes as CFDictionary,
                compressedDataAllocator: nil,
                outputCallback: offlineCompressorOutputCallback,
                refcon: refCon,
                compressionSessionOut: &sessionOut
            )
        }

        guard status == noErr, let compressionSession = sessionOut else {
            Unmanaged<OfflineEncoderCallbackContext>.fromOpaque(refCon).release()
            throw BackbufferError.compressionFailed("VTCompressionSessionCreate failed (OSStatus \(status)).")
        }

        self.session = compressionSession
        self.retainedRefCon = refCon

        // Configure offline bitrate-constrained compression. Use optional setters for hints that
        // virtualized CI encoders may decline with kVTPropertyNotSupportedErr.
        _ = VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        let keyframeIntervalSeconds = 2.0
        let keyframeIntervalFrames = max(1, Int((Double(self.fps) * keyframeIntervalSeconds).rounded()))
        _ = VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: NSNumber(value: keyframeIntervalFrames)
        )
        _ = VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: NSNumber(value: keyframeIntervalSeconds)
        )
        _ = VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: NSNumber(value: max(48_000, bitrateBps))
        )
        _ = VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: self.fps)
        )

        let maxBytesPerSecond = max(8_192, Int((Double(bitrateBps) * 1.05 / 8.0).rounded()))
        let dataRateLimits: [NSNumber] = [NSNumber(value: maxBytesPerSecond), NSNumber(value: 1.0)]
        _ = VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_DataRateLimits,
            value: dataRateLimits as CFArray
        )

        let profileLevel: CFString = (codec == .hevc)
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel
        _ = VTSessionSetProperty(compressionSession, key: kVTCompressionPropertyKey_ProfileLevel, value: profileLevel)

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(compressionSession)
        if prepareStatus != noErr {
            invalidate()
            throw BackbufferError.compressionFailed("VTCompressionSessionPrepareToEncodeFrames failed (OSStatus \(prepareStatus)).")
        }
    }

    func encodeAndFlushLeadingSample(_ sampleBuffer: CMSampleBuffer) throws {
        try encodeDecodedSample(sampleBuffer)
        try flushPendingFrames()
    }

    func encodeDecodedSample(_ sampleBuffer: CMSampleBuffer) throws {
        guard !isInvalidated, let compressionSession = session else {
            throw BackbufferError.compressionFailed("OfflineVTEncoder was invalidated.")
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isNumeric else { return }

        let pts: CMTime
        if lastEncodedPTS.isNumeric && CMTimeCompare(rawPTS, lastEncodedPTS) <= 0 {
            let bump = CMTime(value: 1, timescale: Int32(max(fps * 10, 600)))
            pts = CMTimeAdd(lastEncodedPTS, bump)
        } else {
            pts = rawPTS
        }

        let rawDuration = CMSampleBufferGetDuration(sampleBuffer)
        let duration = rawDuration.isNumeric ? rawDuration : fallbackFrameDuration

        let inputPixelBuffer: CVPixelBuffer
        if CVPixelBufferGetWidth(imageBuffer) != width || CVPixelBufferGetHeight(imageBuffer) != height {
            let pool: PixelTransferPool
            if let existing = transferPool {
                pool = existing
            } else {
                let created = try PixelTransferPool(
                    width: width,
                    height: height,
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    minimumBufferCount: 2
                )
                transferPool = created
                pool = created
            }
            inputPixelBuffer = try pool.copyToDetachedBuffer(imageBuffer)
        } else {
            inputPixelBuffer = imageBuffer
        }

        var flagsOut = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: inputPixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
        guard status == noErr else {
            throw BackbufferError.compressionFailed("VTCompressionSessionEncodeFrame failed (OSStatus \(status)).")
        }
        lastEncodedPTS = pts
    }

    func flushPendingFrames() throws {
        guard !isInvalidated, let compressionSession = session else { return }
        let status = VTCompressionSessionCompleteFrames(compressionSession, untilPresentationTimeStamp: .invalid)
        if status != noErr {
            throw BackbufferError.compressionFailed("VTCompressionSessionCompleteFrames failed (OSStatus \(status)).")
        }
    }

    func popPendingPacket() -> CMSampleBuffer? {
        context.popPacket()
    }

    func peekLeadingPacket() -> CMSampleBuffer? {
        context.peekPacket()
    }

    func recordExternalError(_ error: BackbufferError) {
        context.recordError(error)
    }

    func consumeError() -> BackbufferError? {
        context.consumeError()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        context.markInvalidated()
        if let compressionSession = session {
            VTCompressionSessionInvalidate(compressionSession)
            session = nil
        }
        transferPool?.invalidate()
        transferPool = nil
        if let refCon = retainedRefCon {
            Unmanaged<OfflineEncoderCallbackContext>.fromOpaque(refCon).release()
            retainedRefCon = nil
        }
    }

    deinit {
        invalidate()
    }
}

private final class TranscodePump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderOutput
    private let videoInput: AVAssetWriterInput
    private let vtEncoder: OfflineVTEncoder
    private let audioOutput: AVAssetReaderOutput?
    private let audioInput: AVAssetWriterInput?

    private let videoQueue = DispatchQueue(label: "io.malachiteore.backbuffer.compressor.video")
    private let audioQueue = DispatchQueue(label: "io.malachiteore.backbuffer.compressor.audio")
    private let group = DispatchGroup()

    private var videoFinished = false
    private var audioFinished = false
    private var flushedEncoder = false
    private var encodedSinceFlush = 0

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        vtEncoder: OfflineVTEncoder,
        audioOutput: AVAssetReaderOutput?,
        audioInput: AVAssetWriterInput?
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.vtEncoder = vtEncoder
        self.audioOutput = audioOutput
        self.audioInput = audioInput
    }

    func run() async {
        group.enter()
        if audioOutput != nil && audioInput != nil {
            group.enter()
        } else {
            audioFinished = true
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.videoInput.requestMediaDataWhenReady(on: self.videoQueue) { [self] in
                self.pumpVideo()
            }

            if let audioInput = self.audioInput {
                audioInput.requestMediaDataWhenReady(on: self.audioQueue) { [self] in
                    self.pumpAudio()
                }
            }

            self.group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [self] in
                self.writer.finishWriting {
                    continuation.resume()
                }
            }
        }
    }

    private func pumpVideo() {
        while videoInput.isReadyForMoreMediaData {
            if let packet = vtEncoder.popPendingPacket() {
                if !videoInput.append(packet) {
                    reader.cancelReading()
                    finishVideo()
                    return
                }
                continue
            }

            if flushedEncoder {
                finishVideo()
                return
            }

            if reader.status == .failed || reader.status == .cancelled {
                finishVideo()
                return
            }

            if let sample = videoOutput.copyNextSampleBuffer() {
                do {
                    try vtEncoder.encodeDecodedSample(sample)
                    encodedSinceFlush += 1
                    if encodedSinceFlush >= 12 {
                        try vtEncoder.flushPendingFrames()
                        encodedSinceFlush = 0
                    }
                } catch let error as BackbufferError {
                    vtEncoder.recordExternalError(error)
                    reader.cancelReading()
                    finishVideo()
                    return
                } catch {
                    vtEncoder.recordExternalError(.compressionFailed(error.localizedDescription))
                    reader.cancelReading()
                    finishVideo()
                    return
                }
            } else {
                flushedEncoder = true
                do {
                    try vtEncoder.flushPendingFrames()
                } catch let error as BackbufferError {
                    vtEncoder.recordExternalError(error)
                    reader.cancelReading()
                    finishVideo()
                    return
                } catch {
                    vtEncoder.recordExternalError(.compressionFailed(error.localizedDescription))
                    reader.cancelReading()
                    finishVideo()
                    return
                }
            }
        }
    }

    private func pumpAudio() {
        guard let audioOutput, let audioInput else {
            finishAudio()
            return
        }
        while audioInput.isReadyForMoreMediaData {
            if reader.status == .failed || reader.status == .cancelled {
                finishAudio()
                return
            }
            if let sample = audioOutput.copyNextSampleBuffer() {
                if !audioInput.append(sample) {
                    reader.cancelReading()
                    finishAudio()
                    return
                }
            } else {
                finishAudio()
                return
            }
        }
    }

    private func finishVideo() {
        if !videoFinished {
            videoFinished = true
            videoInput.markAsFinished()
            group.leave()
        }
    }

    private func finishAudio() {
        if !audioFinished {
            audioFinished = true
            audioInput?.markAsFinished()
            group.leave()
        }
    }
}
