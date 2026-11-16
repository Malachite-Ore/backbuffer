import CoreAudio
import CoreMedia
import Foundation

/// Mixes and canonicalizes system audio and microphone PCM chunks into aligned 48 kHz
/// stereo 16-bit signed integer LPCM tracks for `ClipMuxer`.
public enum AudioPCMTrackMixer {
    public static let canonicalSampleRate: Double = 48_000
    public static let canonicalChannels: UInt32 = 2
    private static let chunkFrameLength: Int = 960 // 20 ms at 48 kHz

    /// Canonical output format emitted by multi-track builds: 48 kHz, 2-channel, interleaved Int16 LPCM.
    public static func canonicalASBD() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: canonicalSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: canonicalChannels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    /// Builds muxer-ready audio track definitions for a clip span `[originPTS, endPTS)`.
    ///
    /// - Case A (`systemChunks` empty & `micChunks` empty): returns `[]`.
    /// - Case B (`micChunks` empty): returns 1 enabled `"Mix"` track carrying valid system chunks.
    /// - Case C (`!micChunks.isEmpty`): canonicalizes and mixes both streams into enabled Track 0 `"Mix"`
    ///   with clamped `micGain` (`0.0...2.0`). When `includeSeparateStems == true`, also appends Track 1
    ///   (`"Game Audio"`, `isEnabledByDefault: false`) and Track 2 (`"Microphone"`, `isEnabledByDefault: false`,
    ///   clean pre-gain canonicalized mic stem for NLE mixing).
    public static func buildAudioTracks(
        systemChunks: [BufferedAudioChunk],
        micChunks: [BufferedAudioChunk],
        originPTS: CMTime,
        endPTS: CMTime,
        micGain: Double,
        aacBitrateBps: Int,
        includeSeparateStems: Bool
    ) throws -> [AudioTrackInput] {
        let validSystem = sanitizedSortedChunks(systemChunks)
        let validMic = sanitizedSortedChunks(micChunks)

        if validSystem.isEmpty && validMic.isEmpty {
            return []
        }

        if validMic.isEmpty {
            return [
                AudioTrackInput(
                    trackID: "Mix",
                    chunks: validSystem,
                    aacBitrateBps: aacBitrateBps,
                    isEnabledByDefault: true
                )
            ]
        }

        guard originPTS.isNumeric else { return [] }

        let resolvedEndPTS: CMTime
        if endPTS.isNumeric && CMTimeCompare(endPTS, originPTS) > 0 {
            resolvedEndPTS = endPTS
        } else {
            var latestEnd: CMTime = originPTS
            for chunk in validSystem {
                let candidate = chunkEndPTS(chunk)
                if candidate.isNumeric && CMTimeCompare(candidate, latestEnd) > 0 {
                    latestEnd = candidate
                }
            }
            for chunk in validMic {
                let candidate = chunkEndPTS(chunk)
                if candidate.isNumeric && CMTimeCompare(candidate, latestEnd) > 0 {
                    latestEnd = candidate
                }
            }
            resolvedEndPTS = latestEnd
        }

        let spanSeconds = CMTimeSubtract(resolvedEndPTS, originPTS).seconds
        guard spanSeconds.isFinite, spanSeconds > 0 else {
            return []
        }

        let totalFrames = max(1, Int((spanSeconds * canonicalSampleRate).rounded(.up)))
        let totalSamples = totalFrames * Int(canonicalChannels)

        let systemTimeline = renderTimeline(chunks: validSystem, originPTS: originPTS, totalFrames: totalFrames)
        let micTimeline = renderTimeline(chunks: validMic, originPTS: originPTS, totalFrames: totalFrames)

        let clampedGain = micGain.isFinite ? min(2.0, max(0.0, micGain)) : 1.0
        var mixSamples = [Int16](repeating: 0, count: totalSamples)
        for index in 0..<totalSamples {
            mixSamples[index] = AudioSampleExtractor.clampToInt16(systemTimeline[index] + micTimeline[index] * clampedGain)
        }

        let mixChunks = makeCanonicalChunks(from: mixSamples, totalFrames: totalFrames, originPTS: originPTS)
        var tracks: [AudioTrackInput] = [
            AudioTrackInput(
                trackID: "Mix",
                chunks: mixChunks,
                aacBitrateBps: aacBitrateBps,
                isEnabledByDefault: true
            )
        ]

        if includeSeparateStems {
            let systemInt16 = systemTimeline.map { AudioSampleExtractor.clampToInt16($0) }
            let micInt16 = micTimeline.map { AudioSampleExtractor.clampToInt16($0) }

            tracks.append(
                AudioTrackInput(
                    trackID: "Game Audio",
                    chunks: makeCanonicalChunks(from: systemInt16, totalFrames: totalFrames, originPTS: originPTS),
                    aacBitrateBps: aacBitrateBps,
                    isEnabledByDefault: false
                )
            )
            tracks.append(
                AudioTrackInput(
                    trackID: "Microphone",
                    chunks: makeCanonicalChunks(from: micInt16, totalFrames: totalFrames, originPTS: originPTS),
                    aacBitrateBps: aacBitrateBps,
                    isEnabledByDefault: false
                )
            )
        }

        return tracks
    }

    // MARK: - Decoding & Resampling

    private static func sanitizedSortedChunks(_ chunks: [BufferedAudioChunk]) -> [BufferedAudioChunk] {
        chunks
            .filter { chunk in
                chunk.pts.isNumeric &&
                !chunk.pcmData.isEmpty &&
                chunk.frameCount > 0 &&
                chunk.asbd.mSampleRate.isFinite &&
                chunk.asbd.mSampleRate > 0 &&
                chunk.asbd.mChannelsPerFrame > 0
            }
            .sorted { CMTimeCompare($0.pts, $1.pts) < 0 }
    }

    private static func chunkEndPTS(_ chunk: BufferedAudioChunk) -> CMTime {
        if chunk.duration.isNumeric && CMTimeCompare(chunk.duration, .zero) > 0 {
            return chunk.endPTS
        }
        if chunk.asbd.mSampleRate > 0 && chunk.frameCount > 0 {
            let computed = CMTime(
                seconds: Double(chunk.frameCount) / chunk.asbd.mSampleRate,
                preferredTimescale: Int32(canonicalSampleRate)
            )
            return CMTimeAdd(chunk.pts, computed)
        }
        return chunk.pts
    }

    /// Renders all chunks in a single stream onto an interleaved stereo `[Double]` buffer in Int16 units (`-32768...32767`).
    private static func renderTimeline(
        chunks: [BufferedAudioChunk],
        originPTS: CMTime,
        totalFrames: Int
    ) -> [Double] {
        var timeline = [Double](repeating: 0, count: totalFrames * Int(canonicalChannels))
        guard !chunks.isEmpty, totalFrames > 0 else { return timeline }

        for chunk in chunks {
            let decoded = decodeChunkToStereoDouble(chunk)
            let srcFrames = decoded.count / 2
            guard srcFrames > 0 else { continue }

            let sourceRate = chunk.asbd.mSampleRate
            let chunkOffsetSec = CMTimeSubtract(chunk.pts, originPTS).seconds
            guard chunkOffsetSec.isFinite else { continue }

            if abs(sourceRate - canonicalSampleRate) < 1e-6 {
                let startDestFrame = Int((chunkOffsetSec * canonicalSampleRate).rounded())
                let firstSrc = max(0, -startDestFrame)
                let lastSrcExclusive = min(srcFrames, totalFrames - startDestFrame)
                guard firstSrc < lastSrcExclusive else { continue }

                for srcIdx in firstSrc..<lastSrcExclusive {
                    let dstBase = (startDestFrame + srcIdx) * 2
                    let srcBase = srcIdx * 2
                    timeline[dstBase] = decoded[srcBase]
                    timeline[dstBase + 1] = decoded[srcBase + 1]
                }
            } else {
                let chunkSpanSec = Double(srcFrames) / sourceRate
                let dstStart = max(0, Int(ceil(chunkOffsetSec * canonicalSampleRate - 1e-9)))
                let dstEnd = min(totalFrames, Int(ceil((chunkOffsetSec + chunkSpanSec) * canonicalSampleRate - 1e-9)))
                guard dstStart < dstEnd else { continue }

                let maxSrcIndex = Double(srcFrames - 1)
                for dstFrame in dstStart..<dstEnd {
                    let localSec = (Double(dstFrame) / canonicalSampleRate) - chunkOffsetSec
                    let rawPos = localSec * sourceRate
                    let clampedPos = min(maxSrcIndex, max(0.0, rawPos))
                    let i0 = Int(clampedPos)
                    let i1 = min(srcFrames - 1, i0 + 1)
                    let frac = clampedPos - Double(i0)

                    let srcBase0 = i0 * 2
                    let srcBase1 = i1 * 2
                    let dstBase = dstFrame * 2

                    timeline[dstBase] = decoded[srcBase0] + (decoded[srcBase1] - decoded[srcBase0]) * frac
                    timeline[dstBase + 1] = decoded[srcBase0 + 1] + (decoded[srcBase1 + 1] - decoded[srcBase0 + 1]) * frac
                }
            }
        }

        return timeline
    }

    /// Decodes an arbitrary LPCM `BufferedAudioChunk` (8/16/24/32-bit int or 32/64-bit float, mono/multi, interleaved/planar)
    /// into interleaved stereo `Double` samples scaled to Int16 units (`-32768.0 ... 32767.0`).
    private static func decodeChunkToStereoDouble(_ chunk: BufferedAudioChunk) -> [Double] {
        let asbd = chunk.asbd
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return [] }

        let channels = Int(asbd.mChannelsPerFrame)
        let bits = Int(asbd.mBitsPerChannel)
        guard channels > 0, bits > 0 else { return [] }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isAlignedHigh = (asbd.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0

        let declaredFrames = Int(chunk.frameCount)
        guard declaredFrames > 0 else { return [] }

        let sampleContainerBytes: Int
        let frameStride: Int
        let actualFrames: Int
        let planeStride: Int

        if isNonInterleaved && channels > 1 {
            sampleContainerBytes = AudioSampleExtractor.inferredSampleContainerBytes(
                bits: bits,
                declaredBytesPerFrame: Int(asbd.mBytesPerFrame),
                channelsInStride: 1,
                availableByteCount: chunk.pcmData.count / channels,
                frameCount: declaredFrames
            )
            frameStride = asbd.mBytesPerFrame > 0 ? max(sampleContainerBytes, Int(asbd.mBytesPerFrame)) : sampleContainerBytes
            let totalBytesPerFrameAcrossPlanes = frameStride * channels
            guard totalBytesPerFrameAcrossPlanes > 0 else { return [] }
            actualFrames = min(declaredFrames, chunk.pcmData.count / totalBytesPerFrameAcrossPlanes)
            // CoreAudio planar AudioBufferList lays out channels sequentially over the buffer's declared frame count.
            planeStride = declaredFrames * frameStride
            guard planeStride * (channels - 1) + actualFrames * frameStride <= chunk.pcmData.count else {
                return []
            }
        } else {
            sampleContainerBytes = AudioSampleExtractor.inferredSampleContainerBytes(
                bits: bits,
                declaredBytesPerFrame: Int(asbd.mBytesPerFrame),
                channelsInStride: channels,
                availableByteCount: chunk.pcmData.count,
                frameCount: declaredFrames
            )
            frameStride = asbd.mBytesPerFrame > 0 ? max(sampleContainerBytes * channels, Int(asbd.mBytesPerFrame)) : (sampleContainerBytes * channels)
            guard frameStride > 0 else { return [] }
            actualFrames = min(declaredFrames, chunk.pcmData.count / frameStride)
            planeStride = 0
        }

        guard actualFrames > 0 else { return [] }

        var stereo = [Double](repeating: 0, count: actualFrames * 2)
        chunk.pcmData.withUnsafeBytes { rawBuffer in
            for frame in 0..<actualFrames {
                let leftOffset: Int
                let rightOffset: Int
                if isNonInterleaved && channels > 1 {
                    leftOffset = frame * frameStride
                    rightOffset = planeStride + frame * frameStride
                } else {
                    let base = frame * frameStride
                    leftOffset = base
                    rightOffset = channels > 1 ? (base + sampleContainerBytes) : base
                }

                stereo[frame * 2] = AudioSampleExtractor.decodeSampleInInt16Units(
                    from: rawBuffer,
                    offset: leftOffset,
                    bits: bits,
                    sampleContainerBytes: sampleContainerBytes,
                    isFloat: isFloat,
                    isSignedInt: isSignedInt,
                    isBigEndian: isBigEndian,
                    isAlignedHigh: isAlignedHigh
                )
                stereo[frame * 2 + 1] = channels == 1
                    ? stereo[frame * 2]
                    : AudioSampleExtractor.decodeSampleInInt16Units(
                        from: rawBuffer,
                        offset: rightOffset,
                        bits: bits,
                        sampleContainerBytes: sampleContainerBytes,
                        isFloat: isFloat,
                        isSignedInt: isSignedInt,
                        isBigEndian: isBigEndian,
                        isAlignedHigh: isAlignedHigh
                    )
            }
        }

        return stereo
    }

    // MARK: - Canonical Chunk Packaging

    private static func makeCanonicalChunks(
        from samples: [Int16],
        totalFrames: Int,
        originPTS: CMTime
    ) -> [BufferedAudioChunk] {
        let asbd = canonicalASBD()
        let timescale = CMTimeScale(canonicalSampleRate)
        let channels = Int(canonicalChannels)
        var chunks: [BufferedAudioChunk] = []
        chunks.reserveCapacity((totalFrames + chunkFrameLength - 1) / chunkFrameLength)

        var frameOffset = 0
        while frameOffset < totalFrames {
            let chunkFrames = min(chunkFrameLength, totalFrames - frameOffset)
            let startSample = frameOffset * channels
            let endSample = startSample + chunkFrames * channels

            let pcmData: Data = samples[startSample..<endSample].withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
            let offsetTime = CMTime(value: CMTimeValue(frameOffset), timescale: timescale)
            let durationTime = CMTime(value: CMTimeValue(chunkFrames), timescale: timescale)

            chunks.append(
                BufferedAudioChunk(
                    pts: CMTimeAdd(originPTS, offsetTime),
                    duration: durationTime,
                    pcmData: pcmData,
                    asbd: asbd,
                    frameCount: UInt32(chunkFrames)
                )
            )
            frameOffset += chunkFrames
        }

        return chunks
    }
}
