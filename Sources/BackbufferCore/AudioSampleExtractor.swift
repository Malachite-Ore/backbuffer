import CoreAudio
import CoreMedia
import Foundation

/// Decoded canonical stereo 16-bit PCM result plus signal telemetry from a captured audio buffer.
public struct ExtractedAudioResult: Sendable {
    public let chunk: BufferedAudioChunk
    public let rmsLevel: Double
    public let maxAbsSample: Int

    public init(chunk: BufferedAudioChunk, rmsLevel: Double, maxAbsSample: Int) {
        self.chunk = chunk
        self.rmsLevel = rmsLevel
        self.maxAbsSample = maxAbsSample
    }
}

/// Decodes native macOS CoreAudio LPCM `CMSampleBuffer` / `AudioBufferList` frames (8/16/24/32-bit int
/// and 32/64-bit float, mono/stereo/multi-channel, interleaved or planar, little/big endian)
/// into interleaved stereo 16-bit integer LPCM while preserving the source sample rate.
public enum AudioSampleExtractor {
    public static func extractStereoInt16(
        from sampleBuffer: CMSampleBuffer,
        overridePTS: CMTime? = nil,
        zeroOut: Bool = false
    ) -> ExtractedAudioResult? {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer) else {
            return nil
        }

        let numSamples = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard numSamples > 0 else { return nil }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let srcASBD = asbdPtr.pointee
        guard srcASBD.mFormatID == kAudioFormatLinearPCM else { return nil }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let effectivePTS: CMTime
        if let overridePTS, overridePTS.isNumeric {
            effectivePTS = overridePTS
        } else {
            effectivePTS = rawPTS
        }
        guard effectivePTS.isNumeric else { return nil }

        let effectiveSampleRate = (srcASBD.mSampleRate.isFinite && srcASBD.mSampleRate > 0)
            ? srcASBD.mSampleRate
            : 48_000

        let rawDuration = CMSampleBufferGetDuration(sampleBuffer)
        let effectiveDuration: CMTime
        if rawDuration.isNumeric && CMTimeCompare(rawDuration, .zero) > 0 {
            effectiveDuration = rawDuration
        } else {
            let timescale = CMTimeScale(max(1, Int32(effectiveSampleRate.rounded())))
            effectiveDuration = CMTime(
                seconds: Double(numSamples) / effectiveSampleRate,
                preferredTimescale: timescale
            )
        }

        let outASBD = stereoInt16ASBD(sampleRate: effectiveSampleRate)

        if zeroOut {
            let silentData = Data(count: numSamples * 4)
            let chunk = BufferedAudioChunk(
                pts: effectivePTS,
                duration: effectiveDuration,
                pcmData: silentData,
                asbd: outASBD,
                frameCount: UInt32(numSamples)
            )
            return ExtractedAudioResult(chunk: chunk, rmsLevel: 0.0, maxAbsSample: 0)
        }

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
        guard sizeQueryStatus == noErr || bufferListSizeNeeded > 0 else {
            return nil
        }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: max(bufferListSizeNeeded, MemoryLayout<AudioBufferList>.size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawABL.deallocate() }

        let ablPtr = rawABL.assumingMemoryBound(to: AudioBufferList.self)
        var blockBufferOut: CMBlockBuffer?
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

        let ablBuffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        let conversion: (samples: [Int16], rmsLevel: Double, maxAbsSample: Int)? = withExtendedLifetime(blockBufferOut) {
            var slices: [(raw: UnsafeRawBufferPointer, channels: Int)] = []
            slices.reserveCapacity(ablBuffers.count)
            for buffer in ablBuffers {
                let ptr = UnsafeRawBufferPointer(start: buffer.mData, count: buffer.mData != nil ? Int(buffer.mDataByteSize) : 0)
                slices.append((raw: ptr, channels: max(1, Int(buffer.mNumberChannels))))
            }
            return convertSlicesToStereoInt16(buffers: slices, asbd: srcASBD, frameCount: numSamples)
        }

        guard let conversion, !conversion.samples.isEmpty else {
            return nil
        }

        let actualFrames = conversion.samples.count / 2
        let pcmData: Data = conversion.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let chunk = BufferedAudioChunk(
            pts: effectivePTS,
            duration: effectiveDuration,
            pcmData: pcmData,
            asbd: outASBD,
            frameCount: UInt32(actualFrames)
        )
        return ExtractedAudioResult(
            chunk: chunk,
            rmsLevel: conversion.rmsLevel,
            maxAbsSample: conversion.maxAbsSample
        )
    }

    public static func convertPlanarOrInterleavedToStereoInt16(
        buffers: [(data: Data, channels: Int)],
        asbd: AudioStreamBasicDescription,
        frameCount: Int
    ) -> (samples: [Int16], rmsLevel: Double, maxAbsSample: Int)? {
        guard !buffers.isEmpty, frameCount > 0 else { return nil }
        return withRawBuffers(buffers) { slices in
            convertSlicesToStereoInt16(buffers: slices, asbd: asbd, frameCount: frameCount)
        }
    }

    // MARK: - Shared LPCM Decoding Helpers (Also used by AudioPCMTrackMixer)

    static func stereoInt16ASBD(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: (sampleRate.isFinite && sampleRate > 0) ? sampleRate : 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    /// Reads one LPCM sample from `raw` at `offset` and returns its value scaled to Int16 units (`-32768.0 ... 32767.0`).
    static func decodeSampleInInt16Units(
        from raw: UnsafeRawBufferPointer,
        offset: Int,
        bits: Int,
        sampleContainerBytes: Int,
        isFloat: Bool,
        isSignedInt: Bool,
        isBigEndian: Bool,
        isAlignedHigh: Bool
    ) -> Double {
        switch (isFloat, bits) {
        case (true, 32):
            guard offset + 4 <= raw.count else { return 0 }
            let rawBits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            let ordered = isBigEndian ? UInt32(bigEndian: rawBits) : UInt32(littleEndian: rawBits)
            let sample = Double(Float(bitPattern: ordered))
            return sample.isFinite ? sample * 32_768.0 : 0
        case (true, 64):
            guard offset + 8 <= raw.count else { return 0 }
            let rawBits = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            let ordered = isBigEndian ? UInt64(bigEndian: rawBits) : UInt64(littleEndian: rawBits)
            let sample = Double(bitPattern: ordered)
            return sample.isFinite ? sample * 32_768.0 : 0
        case (false, 16) where isSignedInt:
            guard offset + 2 <= raw.count else { return 0 }
            let rawVal = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            let ordered = isBigEndian ? Int16(bigEndian: rawVal) : Int16(littleEndian: rawVal)
            return Double(ordered)
        case (false, 24) where isSignedInt:
            if sampleContainerBytes >= 4 {
                guard offset + 4 <= raw.count else { return 0 }
                let rawBits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                let ordered = Int32(bitPattern: isBigEndian ? UInt32(bigEndian: rawBits) : UInt32(littleEndian: rawBits))
                if isAlignedHigh {
                    return Double(ordered) / 65_536.0
                }
                let signed24 = (ordered << 8) >> 8
                return Double(signed24) / 256.0
            } else {
                guard offset + 3 <= raw.count else { return 0 }
                let b0 = raw[offset]
                let b1 = raw[offset + 1]
                let b2 = raw[offset + 2]
                let signed24: Int32
                if isBigEndian {
                    signed24 = (Int32(Int8(bitPattern: b0)) << 16) | (Int32(b1) << 8) | Int32(b2)
                } else {
                    signed24 = Int32(b0) | (Int32(b1) << 8) | (Int32(Int8(bitPattern: b2)) << 16)
                }
                return Double(signed24) / 256.0
            }
        case (false, 32) where isSignedInt:
            guard offset + 4 <= raw.count else { return 0 }
            let rawVal = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            let ordered = isBigEndian ? Int32(bigEndian: rawVal) : Int32(littleEndian: rawVal)
            return Double(ordered) / 65_536.0
        case (false, 8):
            guard offset + 1 <= raw.count else { return 0 }
            if isSignedInt {
                let s = raw.loadUnaligned(fromByteOffset: offset, as: Int8.self)
                return Double(s) * 256.0
            } else {
                let u = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
                return (Double(u) - 128.0) * 256.0
            }
        default:
            return 0
        }
    }

    static func clampToInt16(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int16.max) { return Int16.max }
        if rounded <= Double(Int16.min) { return Int16.min }
        return Int16(rounded)
    }

    static func inferredSampleContainerBytes(
        bits: Int,
        declaredBytesPerFrame: Int,
        channelsInStride: Int,
        availableByteCount: Int,
        frameCount: Int
    ) -> Int {
        let minPacked = max(1, (bits + 7) / 8)
        if declaredBytesPerFrame > 0 && channelsInStride > 0 {
            let candidate = declaredBytesPerFrame / channelsInStride
            if candidate >= minPacked {
                return candidate
            }
        }
        if bits == 24 && frameCount > 0 && channelsInStride > 0 && availableByteCount >= frameCount * channelsInStride * 4 {
            return 4
        }
        return minPacked
    }

    // MARK: - Internal Buffer Conversion

    private static func convertSlicesToStereoInt16(
        buffers: [(raw: UnsafeRawBufferPointer, channels: Int)],
        asbd: AudioStreamBasicDescription,
        frameCount: Int
    ) -> (samples: [Int16], rmsLevel: Double, maxAbsSample: Int)? {
        guard !buffers.isEmpty, frameCount > 0 else { return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return nil }

        let bits = Int(asbd.mBitsPerChannel)
        guard bits > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isAlignedHigh = (asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0

        guard isSupportedFormat(isFloat: isFloat, isSignedInt: isSignedInt, bits: bits) else {
            return nil
        }

        var interleaved: [Int16]
        if buffers.count >= 2 {
            // Multi-buffer AudioBufferList (e.g. planar 2ch+ Float32/Int24/Int16/Int32).
            let raw0 = buffers[0].raw
            let raw1 = buffers[1].raw
            let ch0Count = max(1, buffers[0].channels)
            let ch1Count = max(1, buffers[1].channels)
            let sampleBytes0 = inferredSampleContainerBytes(
                bits: bits,
                declaredBytesPerFrame: Int(asbd.mBytesPerFrame),
                channelsInStride: ch0Count,
                availableByteCount: raw0.count,
                frameCount: frameCount
            )
            let sampleBytes1 = inferredSampleContainerBytes(
                bits: bits,
                declaredBytesPerFrame: Int(asbd.mBytesPerFrame),
                channelsInStride: ch1Count,
                availableByteCount: raw1.count,
                frameCount: frameCount
            )
            let stride0 = asbd.mBytesPerFrame > 0 ? max(sampleBytes0 * ch0Count, Int(asbd.mBytesPerFrame)) : (sampleBytes0 * ch0Count)
            let stride1 = asbd.mBytesPerFrame > 0 ? max(sampleBytes1 * ch1Count, Int(asbd.mBytesPerFrame)) : (sampleBytes1 * ch1Count)
            guard stride0 > 0, stride1 > 0 else { return nil }

            let actualFrames = min(frameCount, raw0.count / stride0, raw1.count / stride1)
            guard actualFrames > 0 else { return nil }

            interleaved = [Int16](repeating: 0, count: actualFrames * 2)
            for frame in 0..<actualFrames {
                let left = decodeSampleInInt16Units(
                    from: raw0,
                    offset: frame * stride0,
                    bits: bits,
                    sampleContainerBytes: sampleBytes0,
                    isFloat: isFloat,
                    isSignedInt: isSignedInt,
                    isBigEndian: isBigEndian,
                    isAlignedHigh: isAlignedHigh
                )
                let right = decodeSampleInInt16Units(
                    from: raw1,
                    offset: frame * stride1,
                    bits: bits,
                    sampleContainerBytes: sampleBytes1,
                    isFloat: isFloat,
                    isSignedInt: isSignedInt,
                    isBigEndian: isBigEndian,
                    isAlignedHigh: isAlignedHigh
                )
                interleaved[frame * 2] = clampToInt16(left)
                interleaved[frame * 2 + 1] = clampToInt16(right)
            }
        } else {
            // Single buffer: either interleaved (1ch, 2ch, >2ch) or planar-packed sequentially inside 1 Data.
            let raw = buffers[0].raw
            let totalChannels = max(1, asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : buffers[0].channels)
            let packedPlanar = isNonInterleaved && totalChannels > 1

            if packedPlanar {
                let sampleBytes = inferredSampleContainerBytes(
                    bits: bits,
                    declaredBytesPerFrame: Int(asbd.mBytesPerFrame),
                    channelsInStride: 1,
                    availableByteCount: raw.count / totalChannels,
                    frameCount: frameCount
                )
                let frameStride = asbd.mBytesPerFrame > 0 ? max(sampleBytes, Int(asbd.mBytesPerFrame)) : sampleBytes
                let totalAcrossPlanes = frameStride * totalChannels
                guard totalAcrossPlanes > 0 else { return nil }

                let actualFrames = min(frameCount, raw.count / totalAcrossPlanes)
                let planeStride = frameCount * frameStride
                guard actualFrames > 0,
                      planeStride + actualFrames * frameStride <= raw.count else {
                    return nil
                }

                interleaved = [Int16](repeating: 0, count: actualFrames * 2)
                for frame in 0..<actualFrames {
                    let left = decodeSampleInInt16Units(
                        from: raw,
                        offset: frame * frameStride,
                        bits: bits,
                        sampleContainerBytes: sampleBytes,
                        isFloat: isFloat,
                        isSignedInt: isSignedInt,
                        isBigEndian: isBigEndian,
                        isAlignedHigh: isAlignedHigh
                    )
                    let right = decodeSampleInInt16Units(
                        from: raw,
                        offset: planeStride + frame * frameStride,
                        bits: bits,
                        sampleContainerBytes: sampleBytes,
                        isFloat: isFloat,
                        isSignedInt: isSignedInt,
                        isBigEndian: isBigEndian,
                        isAlignedHigh: isAlignedHigh
                    )
                    interleaved[frame * 2] = clampToInt16(left)
                    interleaved[frame * 2 + 1] = clampToInt16(right)
                }
            } else {
                let channels = totalChannels
                let sampleBytes = inferredSampleContainerBytes(
                    bits: bits,
                    declaredBytesPerFrame: Int(asbd.mBytesPerFrame),
                    channelsInStride: channels,
                    availableByteCount: raw.count,
                    frameCount: frameCount
                )
                let frameStride = asbd.mBytesPerFrame > 0 ? max(sampleBytes * channels, Int(asbd.mBytesPerFrame)) : (sampleBytes * channels)
                guard frameStride > 0 else { return nil }

                let actualFrames = min(frameCount, raw.count / frameStride)
                guard actualFrames > 0 else { return nil }

                interleaved = [Int16](repeating: 0, count: actualFrames * 2)
                for frame in 0..<actualFrames {
                    let base = frame * frameStride
                    let left = decodeSampleInInt16Units(
                        from: raw,
                        offset: base,
                        bits: bits,
                        sampleContainerBytes: sampleBytes,
                        isFloat: isFloat,
                        isSignedInt: isSignedInt,
                        isBigEndian: isBigEndian,
                        isAlignedHigh: isAlignedHigh
                    )
                    let right = channels == 1
                        ? left
                        : decodeSampleInInt16Units(
                            from: raw,
                            offset: base + sampleBytes,
                            bits: bits,
                            sampleContainerBytes: sampleBytes,
                            isFloat: isFloat,
                            isSignedInt: isSignedInt,
                            isBigEndian: isBigEndian,
                            isAlignedHigh: isAlignedHigh
                        )
                    interleaved[frame * 2] = clampToInt16(left)
                    interleaved[frame * 2 + 1] = clampToInt16(right)
                }
            }
        }

        let telemetry = computeTelemetry(for: interleaved)
        return (samples: interleaved, rmsLevel: telemetry.rmsLevel, maxAbsSample: telemetry.maxAbsSample)
    }

    private static func isSupportedFormat(isFloat: Bool, isSignedInt: Bool, bits: Int) -> Bool {
        switch (isFloat, bits) {
        case (true, 32), (true, 64):
            return true
        case (false, 16) where isSignedInt,
             (false, 24) where isSignedInt,
             (false, 32) where isSignedInt,
             (false, 8):
            return true
        default:
            return false
        }
    }

    private static func computeTelemetry(for samples: [Int16]) -> (rmsLevel: Double, maxAbsSample: Int) {
        guard !samples.isEmpty else { return (0.0, 0) }
        var sumSquares: Double = 0
        var maxAbs = 0
        for sample in samples {
            let intVal = Int(sample)
            let absVal = abs(intVal)
            if absVal > maxAbs {
                maxAbs = absVal
            }
            let normalized = Double(intVal) / 32_768.0
            sumSquares += normalized * normalized
        }

        guard sumSquares > 0, maxAbs > 0 else {
            return (0.0, 0)
        }

        let rms = sqrt(sumSquares / Double(samples.count))
        guard rms > 0 else {
            return (0.0, maxAbs)
        }

        let db = 20.0 * log10(rms)
        let normalizedLevel = min(1.0, max(0.0, (db + 55.0) / 55.0))
        return (normalizedLevel, maxAbs)
    }

    private static func withRawBuffers<Result>(
        _ buffers: [(data: Data, channels: Int)],
        body: ([(raw: UnsafeRawBufferPointer, channels: Int)]) -> Result
    ) -> Result {
        var collected: [(raw: UnsafeRawBufferPointer, channels: Int)] = []
        collected.reserveCapacity(buffers.count)

        func recurse(_ index: Int) -> Result {
            if index >= buffers.count {
                return body(collected)
            }
            return buffers[index].data.withUnsafeBytes { rawPtr in
                collected.append((raw: rawPtr, channels: buffers[index].channels))
                return recurse(index + 1)
            }
        }

        return recurse(0)
    }
}
