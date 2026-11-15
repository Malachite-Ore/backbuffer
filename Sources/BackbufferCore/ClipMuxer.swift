import AVFoundation
import CoreMedia
import Foundation

/// Zero-re-encode MP4 passthrough muxer for compressed video packets plus 0..N discrete AAC audio tracks.
/// All timestamps are rebased relative to the clip's leading keyframe PTS so outputs begin cleanly at CMTime.zero.
public enum ClipMuxer {
    public static func writeMP4(
        videoPackets: [BufferedVideoPacket],
        audioTracks: [AudioTrackInput],
        to outputURL: URL
    ) async throws {
        let sortedPackets = videoPackets
            .filter { $0.pts.isNumeric }
            .sorted { CMTimeCompare($0.pts, $1.pts) < 0 }

        guard let firstKeyframeIdx = sortedPackets.firstIndex(where: { $0.isKeyframe }) else {
            throw BackbufferError.emptyBuffer
        }

        let validVideoPackets = deduplicateMonotonicVideoPackets(Array(sortedPackets[firstKeyframeIdx...]))
        guard let firstVideoPacket = validVideoPackets.first else {
            throw BackbufferError.emptyBuffer
        }

        guard let videoFormatDesc = CMSampleBufferGetFormatDescription(firstVideoPacket.sampleBuffer) else {
            throw BackbufferError.muxerFailed("Missing CMVideoFormatDescription on leading keyframe.")
        }

        let originPTS = firstVideoPacket.pts

        let fileManager = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
        } catch {
            throw BackbufferError.muxerFailed("Failed to prepare output path: \(error.localizedDescription)")
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw BackbufferError.muxerFailed("Failed to create AVAssetWriter: \(error.localizedDescription)")
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatDesc
        )
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            throw BackbufferError.muxerFailed("AVAssetWriter rejected passthrough video input.")
        }
        writer.add(videoInput)

        var audioPipelines: [PreparedAudioPipeline] = []
        for track in audioTracks {
            let rebasedChunks = prepareAudioChunks(track.chunks, relativeTo: originPTS)
            guard let firstChunk = rebasedChunks.first else { continue }

            let asbd = firstChunk.asbd
            let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            let channelCount = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : 2
            let audioFormatDesc = try makeAudioFormatDescription(from: asbd)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: max(64_000, track.aacBitrateBps)
            ]

            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: audioSettings,
                sourceFormatHint: audioFormatDesc
            )
            audioInput.expectsMediaDataInRealTime = false

            guard writer.canAdd(audioInput) else {
                throw BackbufferError.muxerFailed("AVAssetWriter rejected audio track '\(track.trackID)'.")
            }
            writer.add(audioInput)

            audioPipelines.append(
                PreparedAudioPipeline(
                    trackID: track.trackID,
                    input: audioInput,
                    chunks: rebasedChunks,
                    formatDescription: audioFormatDesc
                )
            )
        }

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "AVAssetWriter.startWriting returned false."
            try? fileManager.removeItem(at: outputURL)
            throw BackbufferError.muxerFailed(reason)
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await runMuxSession(
                writer: writer,
                videoInput: videoInput,
                videoPackets: validVideoPackets,
                originPTS: originPTS,
                audioPipelines: audioPipelines
            )
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    // MARK: - Internal Session Runner

    private struct RebasedAudioChunk {
        let rebasedPTS: CMTime
        let pcmData: Data
        let asbd: AudioStreamBasicDescription
        let frameCount: UInt32
    }

    private struct PreparedAudioPipeline {
        let trackID: String
        let input: AVAssetWriterInput
        let chunks: [RebasedAudioChunk]
        let formatDescription: CMAudioFormatDescription
    }

    private final class MuxSessionState: @unchecked Sendable {
        let writer: AVAssetWriter
        let queue = DispatchQueue(label: "io.malachiteore.backbuffer.clipmuxer", qos: .userInitiated)
        let videoInput: AVAssetWriterInput
        let videoPackets: [BufferedVideoPacket]
        let originPTS: CMTime
        let audioStates: [AudioTrackState]
        let totalInputs: Int
        var videoIndex = 0
        var videoFinished = false
        var finishedCount = 0
        var didComplete = false
        var continuation: CheckedContinuation<Void, Error>?

        init(
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            videoPackets: [BufferedVideoPacket],
            originPTS: CMTime,
            audioPipelines: [PreparedAudioPipeline]
        ) {
            self.writer = writer
            self.videoInput = videoInput
            self.videoPackets = videoPackets
            self.originPTS = originPTS
            self.audioStates = audioPipelines.map { AudioTrackState(pipeline: $0) }
            self.totalInputs = 1 + audioPipelines.count
        }
    }

    private final class AudioTrackState: @unchecked Sendable {
        let pipeline: PreparedAudioPipeline
        var index = 0
        var isFinished = false

        init(pipeline: PreparedAudioPipeline) {
            self.pipeline = pipeline
        }
    }

    private static func runMuxSession(
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        videoPackets: [BufferedVideoPacket],
        originPTS: CMTime,
        audioPipelines: [PreparedAudioPipeline]
    ) async throws {
        let session = MuxSessionState(
            writer: writer,
            videoInput: videoInput,
            videoPackets: videoPackets,
            originPTS: originPTS,
            audioPipelines: audioPipelines
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.queue.async {
                session.continuation = continuation

                session.videoInput.requestMediaDataWhenReady(on: session.queue) {
                    guard !session.didComplete, !session.videoFinished else { return }

                    while session.videoInput.isReadyForMoreMediaData && session.videoIndex < session.videoPackets.count {
                        let packet = session.videoPackets[session.videoIndex]
                        session.videoIndex += 1

                        do {
                            let rebasedSample = try rebaseVideoSampleBuffer(packet, relativeTo: session.originPTS)
                            if !session.videoInput.append(rebasedSample) {
                                let detail = session.writer.error?.localizedDescription ?? "Failed to append video sample buffer."
                                failMuxSession(session, with: BackbufferError.muxerFailed(detail))
                                return
                            }
                        } catch {
                            failMuxSession(session, with: error)
                            return
                        }
                    }

                    if session.videoIndex >= session.videoPackets.count && !session.videoFinished {
                        session.videoFinished = true
                        session.videoInput.markAsFinished()
                        session.finishedCount += 1
                        finishMuxSessionIfReady(session)
                    }
                }

                for trackState in session.audioStates {
                    let input = trackState.pipeline.input
                    input.requestMediaDataWhenReady(on: session.queue) {
                        guard !session.didComplete, !trackState.isFinished else { return }

                        let chunks = trackState.pipeline.chunks
                        while input.isReadyForMoreMediaData && trackState.index < chunks.count {
                            let chunk = chunks[trackState.index]
                            trackState.index += 1

                            do {
                                let audioSample = try makePCMSampleBuffer(
                                    from: chunk,
                                    formatDescription: trackState.pipeline.formatDescription
                                )
                                if !input.append(audioSample) {
                                    let detail = session.writer.error?.localizedDescription
                                        ?? "Failed to append audio sample on track '\(trackState.pipeline.trackID)'."
                                    failMuxSession(session, with: BackbufferError.muxerFailed(detail))
                                    return
                                }
                            } catch {
                                failMuxSession(session, with: error)
                                return
                            }
                        }

                        if trackState.index >= chunks.count && !trackState.isFinished {
                            trackState.isFinished = true
                            input.markAsFinished()
                            session.finishedCount += 1
                            finishMuxSessionIfReady(session)
                        }
                    }
                }
            }
        }
    }

    private static func failMuxSession(_ session: MuxSessionState, with error: Error) {
        guard !session.didComplete else { return }
        session.didComplete = true

        if !session.videoFinished {
            session.videoFinished = true
            session.videoInput.markAsFinished()
        }
        for trackState in session.audioStates where !trackState.isFinished {
            trackState.isFinished = true
            trackState.pipeline.input.markAsFinished()
        }

        session.writer.cancelWriting()
        let muxError: BackbufferError
        if let backbufferError = error as? BackbufferError {
            muxError = backbufferError
        } else {
            muxError = .muxerFailed(error.localizedDescription)
        }
        session.continuation?.resume(throwing: muxError)
        session.continuation = nil
    }

    private static func finishMuxSessionIfReady(_ session: MuxSessionState) {
        guard !session.didComplete, session.finishedCount == session.totalInputs else { return }
        session.didComplete = true
        let continuation = session.continuation
        session.continuation = nil

        session.writer.finishWriting {
            if session.writer.status == .completed {
                continuation?.resume(returning: ())
            } else {
                let reason = session.writer.error?.localizedDescription
                    ?? "AVAssetWriter finished with status \(session.writer.status.rawValue)."
                continuation?.resume(throwing: BackbufferError.muxerFailed(reason))
            }
        }
    }

    // MARK: - Packet & Sample Buffer Helpers

    private static func deduplicateMonotonicVideoPackets(_ packets: [BufferedVideoPacket]) -> [BufferedVideoPacket] {
        var result: [BufferedVideoPacket] = []
        result.reserveCapacity(packets.count)
        var lastPTS: CMTime = .invalid

        for packet in packets {
            if lastPTS.isNumeric && CMTimeCompare(packet.pts, lastPTS) <= 0 {
                continue
            }
            result.append(packet)
            lastPTS = packet.pts
        }
        return result
    }

    private static func rebaseVideoSampleBuffer(
        _ packet: BufferedVideoPacket,
        relativeTo originPTS: CMTime
    ) throws -> CMSampleBuffer {
        let source = packet.sampleBuffer
        var timingCount: CMItemCount = 0
        let countStatus = CMSampleBufferGetSampleTimingInfoArray(
            source,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        )
        guard countStatus == noErr else {
            throw BackbufferError.muxerFailed("CMSampleBufferGetSampleTimingInfoArray count failed (OSStatus \(countStatus)).")
        }

        var timings: [CMSampleTimingInfo]
        if timingCount > 0 {
            timings = Array(
                repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid),
                count: Int(timingCount)
            )
            let fillStatus = timings.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                guard let base = ptr.baseAddress else { return kCMSampleBufferError_AllocationFailed }
                return CMSampleBufferGetSampleTimingInfoArray(
                    source,
                    entryCount: timingCount,
                    arrayToFill: base,
                    entriesNeededOut: &timingCount
                )
            }
            guard fillStatus == noErr else {
                throw BackbufferError.muxerFailed("CMSampleBufferGetSampleTimingInfoArray fill failed (OSStatus \(fillStatus)).")
            }

            for index in timings.indices {
                let sourcePTS = timings[index].presentationTimeStamp.isNumeric
                    ? timings[index].presentationTimeStamp
                    : packet.pts
                let shiftedPTS = CMTimeSubtract(sourcePTS, originPTS)
                timings[index].presentationTimeStamp = CMTimeCompare(shiftedPTS, .zero) >= 0 ? shiftedPTS : .zero
                timings[index].decodeTimeStamp = .invalid
                if (!timings[index].duration.isNumeric || CMTimeCompare(timings[index].duration, .zero) <= 0),
                   packet.duration.isNumeric,
                   CMTimeCompare(packet.duration, .zero) > 0 {
                    timings[index].duration = packet.duration
                }
            }
        } else {
            let shiftedPTS = CMTimeSubtract(packet.pts, originPTS)
            let clampedPTS = CMTimeCompare(shiftedPTS, .zero) >= 0 ? shiftedPTS : .zero
            timings = [
                CMSampleTimingInfo(
                    duration: packet.duration,
                    presentationTimeStamp: clampedPTS,
                    decodeTimeStamp: .invalid
                )
            ]
        }

        var copiedOut: CMSampleBuffer?
        let copyStatus = timings.withUnsafeBufferPointer { ptr -> OSStatus in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: source,
                sampleTimingEntryCount: timings.count,
                sampleTimingArray: ptr.baseAddress,
                sampleBufferOut: &copiedOut
            )
        }
        guard copyStatus == noErr, let copied = copiedOut else {
            throw BackbufferError.muxerFailed("CMSampleBufferCreateCopyWithNewTiming failed (OSStatus \(copyStatus)).")
        }
        return copied
    }

    private static func prepareAudioChunks(
        _ chunks: [BufferedAudioChunk],
        relativeTo originPTS: CMTime
    ) -> [RebasedAudioChunk] {
        let sorted = chunks
            .filter { $0.pts.isNumeric && !$0.pcmData.isEmpty && $0.frameCount > 0 }
            .sorted { CMTimeCompare($0.pts, $1.pts) < 0 }

        var output: [RebasedAudioChunk] = []
        output.reserveCapacity(sorted.count)
        var lastRebasedPTS: CMTime = .invalid

        for chunk in sorted {
            let chunkEndPTS = (chunk.duration.isNumeric && CMTimeCompare(chunk.duration, .zero) > 0)
                ? chunk.endPTS
                : chunk.pts

            if CMTimeCompare(chunkEndPTS, originPTS) <= 0 {
                continue
            }

            let (interleavedData, interleavedASBD) = normalizeToInterleavedPCM(
                data: chunk.pcmData,
                asbd: chunk.asbd,
                frameCount: chunk.frameCount
            )

            var rebasedPTS: CMTime
            var effectiveData = interleavedData
            var effectiveFrameCount = chunk.frameCount

            if CMTimeCompare(chunk.pts, originPTS) < 0 {
                let overlapDelta = CMTimeSubtract(originPTS, chunk.pts).seconds
                let bytesPerFrame = Int(interleavedASBD.mBytesPerFrame)
                let sampleRate = interleavedASBD.mSampleRate
                if overlapDelta > 0, bytesPerFrame > 0, sampleRate > 0 {
                    let skipFrames = UInt32(max(0, Int((overlapDelta * sampleRate).rounded(.up))))
                    if skipFrames >= effectiveFrameCount {
                        continue
                    }
                    let dropBytes = Int(skipFrames) * bytesPerFrame
                    guard dropBytes < effectiveData.count else { continue }
                    effectiveData = Data(effectiveData.dropFirst(dropBytes))
                    effectiveFrameCount -= skipFrames
                }
                rebasedPTS = .zero
            } else {
                rebasedPTS = CMTimeSubtract(chunk.pts, originPTS)
            }

            if lastRebasedPTS.isNumeric && CMTimeCompare(rebasedPTS, lastRebasedPTS) <= 0 {
                continue
            }

            output.append(
                RebasedAudioChunk(
                    rebasedPTS: rebasedPTS,
                    pcmData: effectiveData,
                    asbd: interleavedASBD,
                    frameCount: effectiveFrameCount
                )
            )
            lastRebasedPTS = rebasedPTS
        }

        return output
    }

    private static func normalizeToInterleavedPCM(
        data: Data,
        asbd: AudioStreamBasicDescription,
        frameCount: UInt32
    ) -> (Data, AudioStreamBasicDescription) {
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = Int(frameCount)
        guard isNonInterleaved, channels > 1, frames > 0 else {
            return (data, asbd)
        }

        let bytesPerSample = asbd.mBytesPerFrame > 0
            ? Int(asbd.mBytesPerFrame)
            : max(1, Int(asbd.mBitsPerChannel) / 8)
        let expectedBytes = frames * bytesPerSample * channels
        guard data.count >= expectedBytes else {
            return (data, asbd)
        }

        var interleaved = Data(count: expectedBytes)
        data.withUnsafeBytes { srcRaw in
            interleaved.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dst = dstRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                let planeStride = frames * bytesPerSample
                let frameStride = channels * bytesPerSample
                for frame in 0..<frames {
                    let dstFrameOffset = frame * frameStride
                    for channel in 0..<channels {
                        let srcOffset = channel * planeStride + frame * bytesPerSample
                        let dstOffset = dstFrameOffset + channel * bytesPerSample
                        for byteIndex in 0..<bytesPerSample {
                            dst[dstOffset + byteIndex] = src[srcOffset + byteIndex]
                        }
                    }
                }
            }
        }

        var updatedASBD = asbd
        updatedASBD.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
        updatedASBD.mBytesPerFrame = UInt32(bytesPerSample * channels)
        updatedASBD.mBytesPerPacket = UInt32(bytesPerSample * channels)
        updatedASBD.mFramesPerPacket = 1
        return (interleaved, updatedASBD)
    }

    private static func makeAudioFormatDescription(
        from asbd: AudioStreamBasicDescription
    ) throws -> CMAudioFormatDescription {
        var mutableASBD = asbd
        var formatDescOut: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &mutableASBD,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescOut
        )
        guard status == noErr, let formatDesc = formatDescOut else {
            throw BackbufferError.muxerFailed("CMAudioFormatDescriptionCreate failed (OSStatus \(status)).")
        }
        return formatDesc
    }

    private static func makePCMSampleBuffer(
        from chunk: RebasedAudioChunk,
        formatDescription: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let byteCount = chunk.pcmData.count
        var blockBufferOut: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBufferOut
        )
        guard allocStatus == kCMBlockBufferNoErr, let blockBuffer = blockBufferOut else {
            throw BackbufferError.muxerFailed("CMBlockBufferCreateWithMemoryBlock failed (OSStatus \(allocStatus)).")
        }

        let copyStatus = chunk.pcmData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMBlockBufferBadLengthParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw BackbufferError.muxerFailed("CMBlockBufferReplaceDataBytes failed (OSStatus \(copyStatus)).")
        }

        var sampleBufferOut: CMSampleBuffer?
        let sampleStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(chunk.frameCount),
            presentationTimeStamp: chunk.rebasedPTS,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBufferOut
        )
        guard sampleStatus == noErr, let sampleBuffer = sampleBufferOut else {
            throw BackbufferError.muxerFailed("CMAudioSampleBufferCreateReadyWithPacketDescriptions failed (OSStatus \(sampleStatus)).")
        }
        return sampleBuffer
    }
}
