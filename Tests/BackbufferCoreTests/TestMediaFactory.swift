import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
@testable import BackbufferCore

enum TestMediaFactoryError: Error {
    case pixelBufferCreationFailed(CVReturn)
    case blockBufferCreationFailed(OSStatus)
    case formatDescriptionFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case assetWriterFailed(String)
}

enum TestMediaFactory {
    /// Creates a synthetic NV12 CVPixelBuffer suitable for headless VideoToolbox encoding on CI.
    static func makeNV12PixelBuffer(
        width: Int,
        height: Int,
        frameIndex: Int = 0,
        highEntropy: Bool = false
    ) throws -> CVPixelBuffer {
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw TestMediaFactoryError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        if let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let yHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)

            if highEntropy {
                let safeHeight = max(1, height)
                let frameU32 = UInt32(truncatingIfNeeded: frameIndex)
                for row in 0..<yHeight {
                    let rowStart = yPtr.advanced(by: row * yStride)
                    let band = (row * 3) / safeHeight
                    let panX: Int
                    let panY: Int
                    switch band {
                    case 0:
                        panX = frameIndex &* 5
                        panY = frameIndex &* 3
                    case 1:
                        panX = -(frameIndex &* 7)
                        panY = frameIndex &* 2
                    default:
                        panX = frameIndex &* 4
                        panY = -(frameIndex &* 5)
                    }

                    let wy = row &+ panY
                    let tileY = wy >> 4
                    let subY = (wy >> 3) & 1
                    let wyRidge = wy & 3
                    let bandSeed = UInt32(truncatingIfNeeded: band) &* 0x45D9F3B
                    let tyMix = (UInt32(truncatingIfNeeded: tileY) &* 0x85EBCA77) ^ bandSeed

                    var col = 0
                    while col < width {
                        let wx = col &+ panX
                        let tileX = wx >> 4
                        let subX = (wx >> 3) & 1
                        let runEnd = min(width, col + (8 - (wx & 7)))

                        var h = (UInt32(truncatingIfNeeded: tileX) &* 0x9E3779B1) ^ tyMix
                        h ^= h >> 15
                        h = h &* 0x2C1B3C6D
                        h ^= h >> 12

                        let baseY = 44 + Int(h % 160)
                        let checkerSign = ((subX ^ subY) & 1) == 0 ? 14 : -14
                        let frameMix = h
                            ^ (UInt32(truncatingIfNeeded: subX) &* 0x45D9F3B)
                            ^ (UInt32(truncatingIfNeeded: subY) &* 0x1B873593)
                            ^ (frameU32 &* 0x9E3779B1)
                        let temporalDelta = Int((frameMix >> 4) % 37) - 18
                        let blockBase = baseY + checkerSign + temporalDelta

                        var curWX = wx
                        for c in col..<runEnd {
                            let ridge = (((curWX & 3) + wyRidge) - 3) * 4
                            let clamped = max(16, min(235, blockBase + ridge))
                            rowStart[c] = UInt8(clamped)
                            curWX &+= 1
                        }
                        col = runEnd
                    }
                }
            } else {
                for row in 0..<yHeight {
                    let rowStart = yPtr.advanced(by: row * yStride)
                    let baseLuma = UInt8(24 + ((row + frameIndex * 5) % 200))
                    for col in 0..<width {
                        rowStart[col] = UInt8((Int(baseLuma) + ((col + frameIndex * 3) / 8)) % 219 + 16)
                    }
                }
            }
        }

        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            let uvWidth = width
            let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)

            if highEntropy {
                let safeHeight = max(1, height)
                let evenLimit = uvWidth & ~1
                for uvRow in 0..<uvHeight {
                    let rowStart = uvPtr.advanced(by: uvRow * uvStride)
                    let lumaRow = uvRow * 2
                    let band = (lumaRow * 3) / safeHeight
                    let panX: Int
                    let panY: Int
                    switch band {
                    case 0:
                        panX = frameIndex &* 5
                        panY = frameIndex &* 3
                    case 1:
                        panX = -(frameIndex &* 7)
                        panY = frameIndex &* 2
                    default:
                        panX = frameIndex &* 4
                        panY = -(frameIndex &* 5)
                    }

                    let wy = lumaRow &+ panY
                    let tileY = wy >> 4
                    let bandSeed = UInt32(truncatingIfNeeded: band) &* 0x45D9F3B
                    let tyMix = (UInt32(truncatingIfNeeded: tileY) &* 0x85EBCA77) ^ bandSeed

                    var col = 0
                    while col < evenLimit {
                        let wx = col &+ panX
                        let tileX = wx >> 4
                        let rem = 16 - (wx & 15)
                        let evenStep = rem >= 2 ? (rem & ~1) : 2
                        let runEnd = min(evenLimit, col + evenStep)

                        var h = (UInt32(truncatingIfNeeded: tileX) &* 0x9E3779B1) ^ tyMix
                        h ^= h >> 15
                        h = h &* 0x2C1B3C6D
                        h ^= h >> 12

                        let uVal = UInt8(40 + ((h >> 8) % 176))
                        let vVal = UInt8(40 + ((h >> 16) % 176))
                        var c = col
                        while c < runEnd {
                            rowStart[c] = uVal
                            rowStart[c + 1] = vVal
                            c += 2
                        }
                        col = runEnd
                    }
                }
            } else {
                for row in 0..<uvHeight {
                    let rowStart = uvPtr.advanced(by: row * uvStride)
                    let uVal = UInt8(80 + ((frameIndex * 7) % 96))
                    let vVal = UInt8(160 - ((frameIndex * 5) % 96))
                    var col = 0
                    while col + 1 < uvWidth {
                        rowStart[col] = uVal
                        rowStart[col + 1] = vVal
                        col += 2
                    }
                }
            }
        }

        return buffer
    }

    /// Creates a synthetic 16-bit interleaved LPCM sine wave audio chunk.
    static func makeSineAudioChunk(
        ptsSeconds: Double,
        durationSeconds: Double = 0.02,
        sampleRate: Double = 48_000,
        channels: UInt32 = 2,
        frequencyHz: Double = 440.0
    ) -> BufferedAudioChunk {
        let frameCount = UInt32(max(1, Int((durationSeconds * sampleRate).rounded())))
        let bytesPerSample = UInt32(MemoryLayout<Int16>.size)
        let bytesPerFrame = bytesPerSample * channels

        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var samples = [Int16](repeating: 0, count: Int(frameCount * channels))
        for frame in 0..<Int(frameCount) {
            let t = ptsSeconds + Double(frame) / sampleRate
            let sampleValue = sin(2.0 * Double.pi * frequencyHz * t)
            let quantized = Int16(max(-32767.0, min(32767.0, sampleValue * 12000.0)))
            for ch in 0..<Int(channels) {
                samples[frame * Int(channels) + ch] = quantized
            }
        }

        let data = samples.withUnsafeBytes { Data($0) }
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: Int32(sampleRate))
        let duration = CMTime(value: CMTimeValue(frameCount), timescale: Int32(sampleRate))

        return BufferedAudioChunk(
            pts: pts,
            duration: duration,
            pcmData: data,
            asbd: asbd,
            frameCount: frameCount
        )
    }

    /// Creates a lightweight dummy compressed video packet (`CMSampleBuffer`) for ReplayRingBuffer unit tests.
    static func makeDummyVideoPacket(
        ptsSeconds: Double,
        durationSeconds: Double = 1.0 / 30.0,
        isKeyframe: Bool,
        width: Int = 320,
        height: Int = 180,
        byteSize: Int = 4096
    ) throws -> BufferedVideoPacket {
        var formatDescription: CMVideoFormatDescription?
        let fmtStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard fmtStatus == noErr, let formatDesc = formatDescription else {
            throw TestMediaFactoryError.formatDescriptionFailed(fmtStatus)
        }

        let clampedBytes = max(64, byteSize)
        var blockBufferOut: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: clampedBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: clampedBytes,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBufferOut
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBufferOut else {
            throw TestMediaFactoryError.blockBufferCreationFailed(blockStatus)
        }

        let fillStatus = CMBlockBufferFillDataBytes(
            with: isKeyframe ? 0x65 : 0x41,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: clampedBytes
        )
        guard fillStatus == kCMBlockBufferNoErr else {
            throw TestMediaFactoryError.blockBufferCreationFailed(fillStatus)
        }

        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 600)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = clampedBytes
        var sampleBufferOut: CMSampleBuffer?

        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBufferOut
        )
        guard sbStatus == noErr, let sampleBuffer = sampleBufferOut else {
            throw TestMediaFactoryError.sampleBufferCreationFailed(sbStatus)
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_NotSync] = !isKeyframe
        }

        return BufferedVideoPacket(
            pts: pts,
            isKeyframe: isKeyframe,
            sampleBuffer: sampleBuffer,
            duration: duration
        )
    }

    /// Generates a genuine playable MP4 file on disk completely headlessly via AVAssetWriter.
    @discardableResult
    static func makeSyntheticMP4(
        to url: URL,
        durationSeconds: Double = 4.0,
        fps: Int = 30,
        width: Int = 640,
        height: Int = 360,
        videoBitrateBps: Int = 4_000_000,
        codec: VideoCodecChoice = .h264,
        includeAudio: Bool = true,
        highEntropy: Bool = false
    ) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avVideoCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitrateBps,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoAllowFrameReorderingKey: false
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw TestMediaFactoryError.assetWriterFailed("Cannot add video input")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioChunks: [BufferedAudioChunk] = []
        var audioFormatDesc: CMAudioFormatDescription?

        if includeAudio {
            let chunkDuration = 0.02
            let audioEndThreshold = max(0.0, durationSeconds - 0.0005)
            var cursor = 0.0
            while cursor < audioEndThreshold {
                audioChunks.append(
                    makeSineAudioChunk(
                        ptsSeconds: cursor,
                        durationSeconds: min(chunkDuration, durationSeconds - cursor)
                    )
                )
                cursor += chunkDuration
            }

            if let firstChunk = audioChunks.first {
                var asbd = firstChunk.asbd
                var descOut: CMAudioFormatDescription?
                let fmtStatus = CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &descOut
                )
                guard fmtStatus == noErr, let desc = descOut else {
                    throw TestMediaFactoryError.formatDescriptionFailed(fmtStatus)
                }
                audioFormatDesc = desc

                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000
                ]
                let aInput = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: audioSettings,
                    sourceFormatHint: desc
                )
                aInput.expectsMediaDataInRealTime = false
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    audioInput = aInput
                }
            }
        }

        guard writer.startWriting() else {
            throw TestMediaFactoryError.assetWriterFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, Int((durationSeconds * Double(fps)).rounded()))
        let pump = SyntheticMP4Pump(
            writer: writer,
            videoInput: videoInput,
            adaptor: adaptor,
            totalFrames: totalFrames,
            fps: fps,
            width: width,
            height: height,
            highEntropy: highEntropy,
            audioInput: audioInput,
            audioChunks: audioChunks,
            audioFormatDescription: audioFormatDesc
        )
        try await pump.run()

        if writer.status != .completed {
            throw TestMediaFactoryError.assetWriterFailed(writer.error?.localizedDescription ?? "finishWriting status \(writer.status.rawValue)")
        }

        return url
    }

    private final class SyntheticMP4Pump: @unchecked Sendable {
        private let writer: AVAssetWriter
        private let videoInput: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let totalFrames: Int
        private let fps: Int
        private let width: Int
        private let height: Int
        private let highEntropy: Bool
        private let audioInput: AVAssetWriterInput?
        private let audioChunks: [BufferedAudioChunk]
        private let audioFormatDescription: CMAudioFormatDescription?

        private let videoQueue = DispatchQueue(label: "io.malachiteore.backbuffer.testfactory.video")
        private let audioQueue = DispatchQueue(label: "io.malachiteore.backbuffer.testfactory.audio")
        private let group = DispatchGroup()
        private let errorLock = NSLock()

        private var frameIndex = 0
        private var videoFinished = false
        private var audioIndex = 0
        private var audioFinished = false
        private var capturedError: Error?

        init(
            writer: AVAssetWriter,
            videoInput: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            totalFrames: Int,
            fps: Int,
            width: Int,
            height: Int,
            highEntropy: Bool,
            audioInput: AVAssetWriterInput?,
            audioChunks: [BufferedAudioChunk],
            audioFormatDescription: CMAudioFormatDescription?
        ) {
            self.writer = writer
            self.videoInput = videoInput
            self.adaptor = adaptor
            self.totalFrames = totalFrames
            self.fps = fps
            self.width = width
            self.height = height
            self.highEntropy = highEntropy
            self.audioInput = audioInput
            self.audioChunks = audioChunks
            self.audioFormatDescription = audioFormatDescription
        }

        func run() async throws {
            group.enter()
            if audioInput != nil && !audioChunks.isEmpty {
                group.enter()
            } else {
                audioFinished = true
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                videoInput.requestMediaDataWhenReady(on: videoQueue) { [self] in
                    pumpVideo()
                }

                if let audioInput, !audioChunks.isEmpty {
                    audioInput.requestMediaDataWhenReady(on: audioQueue) { [self] in
                        pumpAudio()
                    }
                }

                group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { [self] in
                    if writer.status == .writing {
                        writer.finishWriting {
                            continuation.resume()
                        }
                    } else {
                        continuation.resume()
                    }
                }
            }

            if let error = errorLock.withLock({ self.capturedError }) {
                throw error
            }
        }

        private func recordError(_ error: Error) {
            errorLock.withLock {
                if capturedError == nil {
                    capturedError = error
                }
            }
            writer.cancelWriting()
        }

        private func pumpVideo() {
            guard !videoFinished else { return }
            while videoInput.isReadyForMoreMediaData && frameIndex < totalFrames {
                if writer.status == .failed || writer.status == .cancelled {
                    finishVideo()
                    return
                }
                do {
                    let pb = try TestMediaFactory.makeNV12PixelBuffer(
                        width: width,
                        height: height,
                        frameIndex: frameIndex,
                        highEntropy: highEntropy
                    )
                    let pts = CMTime(value: CMTimeValue(frameIndex), timescale: Int32(fps))
                    if !adaptor.append(pb, withPresentationTime: pts) {
                        recordError(TestMediaFactoryError.assetWriterFailed(writer.error?.localizedDescription ?? "video append failed"))
                        finishVideo()
                        return
                    }
                    frameIndex += 1
                } catch {
                    recordError(error)
                    finishVideo()
                    return
                }
            }
            if frameIndex >= totalFrames || writer.status == .failed || writer.status == .cancelled {
                finishVideo()
            }
        }

        private func pumpAudio() {
            guard !audioFinished, let audioInput else { return }
            while audioInput.isReadyForMoreMediaData && audioIndex < audioChunks.count {
                if writer.status == .failed || writer.status == .cancelled {
                    finishAudio()
                    return
                }
                do {
                    let sb = try TestMediaFactory.makePCMSampleBuffer(
                        from: audioChunks[audioIndex],
                        formatDescription: audioFormatDescription
                    )
                    if !audioInput.append(sb) {
                        recordError(TestMediaFactoryError.assetWriterFailed(writer.error?.localizedDescription ?? "audio append failed"))
                        finishAudio()
                        return
                    }
                    audioIndex += 1
                } catch {
                    recordError(error)
                    finishAudio()
                    return
                }
            }
            if audioIndex >= audioChunks.count || writer.status == .failed || writer.status == .cancelled {
                finishAudio()
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

    static func makePCMSampleBuffer(
        from chunk: BufferedAudioChunk,
        formatDescription existingFormatDesc: CMAudioFormatDescription? = nil
    ) throws -> CMSampleBuffer {
        let formatDesc: CMAudioFormatDescription
        if let existingFormatDesc {
            formatDesc = existingFormatDesc
        } else {
            var asbd = chunk.asbd
            var createdDesc: CMAudioFormatDescription?
            let fmtStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &createdDesc
            )
            guard fmtStatus == noErr, let desc = createdDesc else {
                throw TestMediaFactoryError.formatDescriptionFailed(fmtStatus)
            }
            formatDesc = desc
        }

        var blockBufferOut: CMBlockBuffer?
        let byteCount = chunk.pcmData.count
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
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
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBufferOut else {
            throw TestMediaFactoryError.blockBufferCreationFailed(blockStatus)
        }

        let replaceStatus = chunk.pcmData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadLengthParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw TestMediaFactoryError.blockBufferCreationFailed(replaceStatus)
        }

        var sampleBufferOut: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(chunk.frameCount),
            presentationTimeStamp: chunk.pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBufferOut
        )
        guard sbStatus == noErr, let sampleBuffer = sampleBufferOut else {
            throw TestMediaFactoryError.sampleBufferCreationFailed(sbStatus)
        }
        return sampleBuffer
    }

    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
