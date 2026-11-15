import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

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
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = max(1, min(240, Int((nominalFPS > 0 ? nominalFPS : 30.0).rounded())))

        let initialPlan = computeTargetBitrate(capBytes: capBytes, durationSeconds: targetDurationSeconds)
        var currentVideoBps = initialPlan.videoBps
        var currentAudioBps = audioTracks.isEmpty ? 0 : initialPlan.audioBps
        var forceDownscale = initialPlan.shouldDownscaleTo720p

        let maxAttempts = 3
        var lastMeasuredBytes: Int64 = 0

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()

            let targetSize = targetDimensions(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                downscaleTo720p: forceDownscale
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
                    : min(0.75, max(0.25, proportionalScale * 0.90))
                currentVideoBps = max(48_000, Int(Double(currentVideoBps) * retryMultiplier))
                if currentVideoBps < 1_200_000 {
                    forceDownscale = true
                }
                if attempt == 2, currentAudioBps > 64_000 {
                    currentAudioBps = 64_000
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
        downscaleTo720p: Bool
    ) -> (width: Int, height: Int) {
        let isRotated = abs(preferredTransform.b) > 0.5 || abs(preferredTransform.c) > 0.5
        if !isRotated {
            return CaptureDimensionCalculator.computeTargetDimensions(
                logicalWidth: naturalSize.width,
                logicalHeight: naturalSize.height,
                pointPixelScale: 1.0,
                cap: downscaleTo720p ? .p720 : .native
            )
        }

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

        return (
            width: CaptureDimensionCalculator.roundDownEven(codedWidth),
            height: CaptureDimensionCalculator.roundDownEven(codedHeight)
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

        let compressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrateBps,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
            AVVideoAllowFrameReorderingKey: false
        ]
        let videoWriteSettings: [String: Any] = [
            AVVideoCodecKey: codec.avVideoCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriteSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else {
            throw BackbufferError.compressionFailed("Cannot add video input to AVAssetWriter.")
        }
        writer.add(videoInput)

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

        guard writer.startWriting() else {
            throw BackbufferError.compressionFailed(writer.error?.localizedDescription ?? "AVAssetWriter failed to start writing.")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw BackbufferError.compressionFailed(reader.error?.localizedDescription ?? "AVAssetReader failed to start reading.")
        }

        let sessionStartTime = timeRange?.start ?? .zero
        writer.startSession(atSourceTime: sessionStartTime)

        let pump = TranscodePump(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput
        )
        await pump.run()

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

private final class TranscodePump: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderOutput?
    private let audioInput: AVAssetWriterInput?

    private let videoQueue = DispatchQueue(label: "io.malachiteore.backbuffer.compressor.video")
    private let audioQueue = DispatchQueue(label: "io.malachiteore.backbuffer.compressor.audio")
    private let group = DispatchGroup()

    private var videoFinished = false
    private var audioFinished = false

    init(
        reader: AVAssetReader,
        writer: AVAssetWriter,
        videoOutput: AVAssetReaderOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderOutput?,
        audioInput: AVAssetWriterInput?
    ) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
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
            guard reader.status == .reading else {
                finishVideo()
                return
            }
            if let sample = videoOutput.copyNextSampleBuffer() {
                if !videoInput.append(sample) {
                    reader.cancelReading()
                    finishVideo()
                    return
                }
            } else {
                finishVideo()
                return
            }
        }
    }

    private func pumpAudio() {
        guard let audioOutput, let audioInput else {
            finishAudio()
            return
        }
        while audioInput.isReadyForMoreMediaData {
            guard reader.status == .reading else {
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
