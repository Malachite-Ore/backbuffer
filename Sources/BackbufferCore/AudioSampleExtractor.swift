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
        let outASBD = stereoInt16ASBD(sampleRate: effectiveSampleRate)

        if zeroOut {
            let effectiveDuration = resolvedDuration(
                rawDuration: rawDuration,
                actualFrames: numSamples,
                numSamples: numSamples,
                sampleRate: effectiveSampleRate
            )
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

        let conversion = fetchAudioBufferList(
            from: sampleBuffer,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            srcASBD: srcASBD,
            numSamples: numSamples
        ) ?? fetchAudioBufferList(
            from: sampleBuffer,
            flags: 0,
            srcASBD: srcASBD,
            numSamples: numSamples
        )

        guard let conversion, !conversion.samples.isEmpty else {
            return nil
        }

        let actualFrames = conversion.samples.count / 2
        let effectiveDuration = resolvedDuration(
            rawDuration: rawDuration,
            actualFrames: actualFrames,
            numSamples: numSamples,
            sampleRate: effectiveSampleRate
        )
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

    private static func resolvedDuration(
        rawDuration: CMTime,
        actualFrames: Int,
        numSamples: Int,
        sampleRate: Double
    ) -> CMTime {
        if actualFrames == numSamples && rawDuration.isNumeric && CMTimeCompare(rawDuration, .zero) > 0 {
            return rawDuration
        }
        let timescale = CMTimeScale(max(1, Int32(sampleRate.rounded())))
        return CMTime(
            seconds: Double(actualFrames) / sampleRate,
            preferredTimescale: timescale
        )
    }

    private static func fetchAudioBufferList(
        from sampleBuffer: CMSampleBuffer,
        flags: UInt32,
        srcASBD: AudioStreamBasicDescription,
        numSamples: Int
    ) -> (samples: [Int16], rmsLevel: Double, maxAbsSample: Int)? {
        var bufferListSizeNeeded = 0
        let sizeQueryStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: flags,
            blockBufferOut: nil
        )
        guard sizeQueryStatus == noErr, bufferListSizeNeeded >= MemoryLayout<AudioBufferList>.size else {
            return nil
        }

        let rawABL = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSizeNeeded,
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
            flags: flags,
            blockBufferOut: &blockBufferOut
        )
        guard fetchStatus == noErr else { return nil }

        let ablBuffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return withExtendedLifetime(blockBufferOut) {
            var slices: [(raw: UnsafeRawBufferPointer, channels: Int)] = []
            slices.reserveCapacity(ablBuffers.count)
            for buffer in ablBuffers {
                let ptr = UnsafeRawBufferPointer(start: buffer.mData, count: buffer.mData != nil ? Int(buffer.mDataByteSize) : 0)
                slices.append((raw: ptr, channels: max(1, Int(buffer.mNumberChannels))))
            }
            return convertSlicesToStereoInt16(buffers: slices, asbd: srcASBD, frameCount: numSamples)
        }
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

    private static func planarSegmentStride(
        bits: Int,
        declaredBytesPerFrame: Int,
        totalChannels: Int,
        chCount: Int,
        availableByteCount: Int,
        segmentCapacityFrames: Int
    ) -> (sampleBytes: Int, frameStride: Int) {
        let minPacked = max(1, (bits + 7) / 8)
        if chCount == 1 &&
            totalChannels > 1 &&
            declaredBytesPerFrame == minPacked * totalChannels &&
            segmentCapacityFrames > 0 &&
            availableByteCount < segmentCapacityFrames * declaredBytesPerFrame {
            let adjusted = bits == 24
                ? inferredSampleContainerBytes(
                    bits: bits,
                    declaredBytesPerFrame: 0,
                    channelsInStride: 1,
                    availableByteCount: availableByteCount,
                    frameCount: segmentCapacityFrames
                )
                : minPacked
            return (sampleBytes: adjusted, frameStride: adjusted)
        }

        let sampleBytes = inferredSampleContainerBytes(
            bits: bits,
            declaredBytesPerFrame: declaredBytesPerFrame,
            channelsInStride: max(1, chCount),
            availableByteCount: availableByteCount,
            frameCount: segmentCapacityFrames
        )
        let frameStride = declaredBytesPerFrame > 0
            ? max(sampleBytes * max(1, chCount), declaredBytesPerFrame)
            : (sampleBytes * max(1, chCount))
        return (sampleBytes: sampleBytes, frameStride: frameStride)
    }

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

        let totalChannels = max(1, asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : (buffers.first?.channels ?? 1))
        let declaredBytesPerFrame = Int(asbd.mBytesPerFrame)
        let minPacked = max(1, (bits + 7) / 8)
        var interleaved: [Int16] = []
        interleaved.reserveCapacity(frameCount * 2)

        if !isNonInterleaved || totalChannels == 1 {
            // Interleaved stream across 1 or more AudioBuffer slices (e.g. segmented [LR_256, LR_256]).
            var remaining = frameCount
            for slice in buffers {
                guard remaining > 0 else { break }
                guard !slice.raw.isEmpty else { continue }

                let channels = totalChannels == 1 ? 1 : max(totalChannels, slice.channels)
                let sampleBytes = inferredSampleContainerBytes(
                    bits: bits,
                    declaredBytesPerFrame: declaredBytesPerFrame,
                    channelsInStride: channels,
                    availableByteCount: slice.raw.count,
                    frameCount: remaining
                )
                let frameStride = declaredBytesPerFrame > 0
                    ? max(sampleBytes * channels, declaredBytesPerFrame)
                    : (sampleBytes * channels)
                guard frameStride > 0 else { continue }

                let sliceFrames = min(remaining, slice.raw.count / frameStride)
                guard sliceFrames > 0 else { continue }

                for frame in 0..<sliceFrames {
                    let base = frame * frameStride
                    let left = decodeSampleInInt16Units(
                        from: slice.raw,
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
                            from: slice.raw,
                            offset: base + sampleBytes,
                            bits: bits,
                            sampleContainerBytes: sampleBytes,
                            isFloat: isFloat,
                            isSignedInt: isSignedInt,
                            isBigEndian: isBigEndian,
                            isAlignedHigh: isAlignedHigh
                        )
                    interleaved.append(clampToInt16(left))
                    interleaved.append(clampToInt16(right))
                }
                remaining -= sliceFrames
            }
        } else if buffers.count == 1 {
            // Non-interleaved planar packed sequentially in 1 buffer: [ch0 frames][ch1 frames]...
            let raw = buffers[0].raw
            let sampleBytes: Int
            let frameStride: Int
            if declaredBytesPerFrame == minPacked * totalChannels &&
                raw.count < frameCount * totalChannels * declaredBytesPerFrame {
                sampleBytes = bits == 24
                    ? inferredSampleContainerBytes(
                        bits: bits,
                        declaredBytesPerFrame: 0,
                        channelsInStride: 1,
                        availableByteCount: raw.count / totalChannels,
                        frameCount: frameCount
                    )
                    : minPacked
                frameStride = sampleBytes
            } else {
                sampleBytes = inferredSampleContainerBytes(
                    bits: bits,
                    declaredBytesPerFrame: declaredBytesPerFrame,
                    channelsInStride: 1,
                    availableByteCount: raw.count / totalChannels,
                    frameCount: frameCount
                )
                frameStride = declaredBytesPerFrame > 0 ? max(sampleBytes, declaredBytesPerFrame) : sampleBytes
            }

            let totalAcrossPlanes = frameStride * totalChannels
            guard totalAcrossPlanes > 0 else { return nil }

            let actualFrames = min(frameCount, raw.count / totalAcrossPlanes)
            let planeStride = frameCount * frameStride
            guard actualFrames > 0,
                  planeStride + actualFrames * frameStride <= raw.count else {
                return nil
            }

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
                interleaved.append(clampToInt16(left))
                interleaved.append(clampToInt16(right))
            }
        } else {
            // Non-interleaved multi-buffer planar: standard [L, R, ...] or segmented [[L_0, R_0], [L_1, R_1], ...].
            var remaining = frameCount
            var groupBase = 0
            while groupBase + 1 < buffers.count && remaining > 0 {
                let leftSlice = buffers[groupBase]
                let rightSlice = buffers[groupBase + 1]
                groupBase += totalChannels

                let ch0Count = max(1, leftSlice.channels)
                let ch1Count = max(1, rightSlice.channels)
                let leftSpec = planarSegmentStride(
                    bits: bits,
                    declaredBytesPerFrame: declaredBytesPerFrame,
                    totalChannels: totalChannels,
                    chCount: ch0Count,
                    availableByteCount: leftSlice.raw.count,
                    segmentCapacityFrames: remaining
                )
                let rightSpec = planarSegmentStride(
                    bits: bits,
                    declaredBytesPerFrame: declaredBytesPerFrame,
                    totalChannels: totalChannels,
                    chCount: ch1Count,
                    availableByteCount: rightSlice.raw.count,
                    segmentCapacityFrames: remaining
                )
                guard leftSpec.frameStride > 0, rightSpec.frameStride > 0 else { continue }

                let segmentFrames = min(
                    remaining,
                    leftSlice.raw.count / leftSpec.frameStride,
                    rightSlice.raw.count / rightSpec.frameStride
                )
                guard segmentFrames > 0 else { continue }

                for frame in 0..<segmentFrames {
                    let left = decodeSampleInInt16Units(
                        from: leftSlice.raw,
                        offset: frame * leftSpec.frameStride,
                        bits: bits,
                        sampleContainerBytes: leftSpec.sampleBytes,
                        isFloat: isFloat,
                        isSignedInt: isSignedInt,
                        isBigEndian: isBigEndian,
                        isAlignedHigh: isAlignedHigh
                    )
                    let right = decodeSampleInInt16Units(
                        from: rightSlice.raw,
                        offset: frame * rightSpec.frameStride,
                        bits: bits,
                        sampleContainerBytes: rightSpec.sampleBytes,
                        isFloat: isFloat,
                        isSignedInt: isSignedInt,
                        isBigEndian: isBigEndian,
                        isAlignedHigh: isAlignedHigh
                    )
                    interleaved.append(clampToInt16(left))
                    interleaved.append(clampToInt16(right))
                }
                remaining -= segmentFrames
            }
        }

        guard !interleaved.isEmpty else { return nil }
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
