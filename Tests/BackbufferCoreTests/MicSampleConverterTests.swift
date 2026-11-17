import CoreAudio
import CoreMedia
import Foundation
import XCTest
@testable import BackbufferCore

final class MicSampleConverterTests: XCTestCase {
    func testMono44100Float32ToStereoInt16AndZeroOut() throws {
        let sampleRate: Double = 44_100
        let frameCount = 4_410 // 100 ms
        let samples = [Float](repeating: 0.5, count: frameCount)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let direct = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: data, channels: 1)],
                asbd: asbd,
                frameCount: frameCount
            )
        )
        XCTAssertEqual(direct.samples.count, frameCount * 2)
        XCTAssertEqual(direct.samples[0], 16_384)
        XCTAssertEqual(direct.samples[1], 16_384)
        XCTAssertEqual(direct.maxAbsSample, 16_384)
        XCTAssertGreaterThan(direct.rmsLevel, 0.5)

        let rawChunk = BufferedAudioChunk(
            pts: CMTime(seconds: 2.0, preferredTimescale: 44_100),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 44_100),
            pcmData: data,
            asbd: asbd,
            frameCount: UInt32(frameCount)
        )
        let sb = try TestMediaFactory.makePCMSampleBuffer(from: rawChunk)
        let overridePTS = CMTime(seconds: 12.5, preferredTimescale: 48_000)

        let extracted = try XCTUnwrap(
            AudioSampleExtractor.extractStereoInt16(from: sb, overridePTS: overridePTS, zeroOut: false)
        )
        XCTAssertEqual(CMTimeCompare(extracted.chunk.pts, overridePTS), 0)
        XCTAssertEqual(extracted.chunk.asbd.mSampleRate, 44_100)
        XCTAssertEqual(extracted.chunk.asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(extracted.chunk.asbd.mBitsPerChannel, 16)
        XCTAssertEqual(extracted.chunk.frameCount, UInt32(frameCount))
        XCTAssertGreaterThan(extracted.maxAbsSample, 16_000)
        XCTAssertGreaterThan(extracted.rmsLevel, 0.5)

        let muted = try XCTUnwrap(
            AudioSampleExtractor.extractStereoInt16(from: sb, overridePTS: overridePTS, zeroOut: true)
        )
        XCTAssertEqual(muted.maxAbsSample, 0)
        XCTAssertEqual(muted.rmsLevel, 0.0)
        XCTAssertEqual(muted.chunk.asbd.mSampleRate, 44_100)
        XCTAssertTrue(muted.chunk.pcmData.allSatisfy { $0 == 0 })
    }

    func testMono16000Int16AndMultiChannelSelection() throws {
        let sampleRate: Double = 16_000
        let frameCount = 320 // 20 ms
        let monoSamples = [Int16](repeating: -12_345, count: frameCount)
        let monoData = monoSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let monoASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        let monoChunk = BufferedAudioChunk(
            pts: CMTime(seconds: 1.0, preferredTimescale: 16_000),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 16_000),
            pcmData: monoData,
            asbd: monoASBD,
            frameCount: UInt32(frameCount)
        )
        let sb = try TestMediaFactory.makePCMSampleBuffer(from: monoChunk)
        let extracted = try XCTUnwrap(AudioSampleExtractor.extractStereoInt16(from: sb))
        XCTAssertEqual(extracted.chunk.asbd.mSampleRate, 16_000)
        XCTAssertEqual(extracted.maxAbsSample, 12_345)

        let decoded = extractInt16(from: extracted.chunk.pcmData)
        XCTAssertEqual(decoded.count, frameCount * 2)
        XCTAssertEqual(decoded[0], -12_345)
        XCTAssertEqual(decoded[1], -12_345)

        // 4-channel interleaved Int16: verify ch0 & ch1 are preserved cleanly.
        let quadSamples: [Int16] = [1_000, -2_000, 9_999, 8_888, 1_500, -2_500, 7_777, 6_666]
        let quadData = quadSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let quadASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 4,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let quadConverted = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: quadData, channels: 4)],
                asbd: quadASBD,
                frameCount: 2
            )
        )
        XCTAssertEqual(quadConverted.samples, [1_000, -2_000, 1_500, -2_500])
    }

    func test24BitPackedAndContainerSignedIntLPCM() throws {
        // 3-byte packed little-endian stereo: L = +4_194_304 (+16_384 in Int16), R = -4_194_304 (-16_384 in Int16).
        let frameCount = 480
        var packedLE = Data(capacity: frameCount * 6)
        for _ in 0..<frameCount {
            // 0x400000 little-endian: 00 00 40
            packedLE.append(contentsOf: [0x00, 0x00, 0x40])
            // 0xC00000 little-endian: 00 00 C0
            packedLE.append(contentsOf: [0x00, 0x00, 0xC0])
        }

        let packedLEASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 6,
            mFramesPerPacket: 1,
            mBytesPerFrame: 6,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        )

        let leResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: packedLE, channels: 2)],
                asbd: packedLEASBD,
                frameCount: frameCount
            )
        )
        XCTAssertEqual(leResult.samples[0], 16_384)
        XCTAssertEqual(leResult.samples[1], -16_384)
        XCTAssertEqual(leResult.maxAbsSample, 16_384)

        // Feed the same 24-bit packed chunk into AudioPCMTrackMixer directly to verify 24-bit parity.
        let chunk24 = BufferedAudioChunk(
            pts: CMTime(seconds: 0.0, preferredTimescale: 48_000),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48_000),
            pcmData: packedLE,
            asbd: packedLEASBD,
            frameCount: UInt32(frameCount)
        )
        let mixedTracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: [],
            micChunks: [chunk24],
            originPTS: CMTime(seconds: 0.0, preferredTimescale: 48_000),
            endPTS: CMTime(seconds: 0.01, preferredTimescale: 48_000),
            micGain: 0.5,
            aacBitrateBps: 160_000,
            includeSeparateStems: false
        )
        XCTAssertEqual(mixedTracks.count, 1)
        let mixedSamples = extractInt16(from: try XCTUnwrap(mixedTracks[0].chunks.first?.pcmData))
        XCTAssertEqual(mixedSamples[0], 8_192)
        XCTAssertEqual(mixedSamples[1], -8_192)

        // Packed 3-byte big-endian stereo: L = 0x400000 (+16_384), R = 0xC00000 (-16_384).
        let packedBE = Data([0x40, 0x00, 0x00, 0xC0, 0x00, 0x00])
        let packedBEASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked | kAudioFormatFlagIsBigEndian,
            mBytesPerPacket: 6,
            mFramesPerPacket: 1,
            mBytesPerFrame: 6,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        let beResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: packedBE, channels: 2)],
                asbd: packedBEASBD,
                frameCount: 1
            )
        )
        XCTAssertEqual(beResult.samples, [16_384, -16_384])

        // 4-byte aligned-high 24-bit container (mBytesPerFrame = 8 for stereo).
        let wordsHigh: [Int32] = [0x4000_0000, -0x4000_0000]
        let highData = wordsHigh.withUnsafeBufferPointer { Data(buffer: $0) }
        let highASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        let highResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: highData, channels: 2)],
                asbd: highASBD,
                frameCount: 1
            )
        )
        XCTAssertEqual(highResult.samples, [16_384, -16_384])
    }

    func testPlanarTwoChannelFloat32AndFloat64Stereo() throws {
        let frameCount = 240
        let leftFloats = [Float](repeating: 0.25, count: frameCount)
        let rightFloats = [Float](repeating: -0.25, count: frameCount)
        let leftData = leftFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let rightData = rightFloats.withUnsafeBufferPointer { Data(buffer: $0) }

        let planarASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let multiBufferResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: leftData, channels: 1), (data: rightData, channels: 1)],
                asbd: planarASBD,
                frameCount: frameCount
            )
        )
        XCTAssertEqual(multiBufferResult.samples[0], 8_192)
        XCTAssertEqual(multiBufferResult.samples[1], -8_192)

        // Single sequentially packed planar buffer + Float64 stereo.
        var combinedPlanar = Data(leftData)
        combinedPlanar.append(rightData)
        let packedPlanarResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: combinedPlanar, channels: 2)],
                asbd: planarASBD,
                frameCount: frameCount
            )
        )
        XCTAssertEqual(packedPlanarResult.samples[0], 8_192)
        XCTAssertEqual(packedPlanarResult.samples[1], -8_192)

        let f64Samples: [Double] = [0.5, -0.5]
        let f64Data = f64Samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let f64ASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 16,
            mFramesPerPacket: 1,
            mBytesPerFrame: 16,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 64,
            mReserved: 0
        )
        let f64Result = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: f64Data, channels: 2)],
                asbd: f64ASBD,
                frameCount: 1
            )
        )
        XCTAssertEqual(f64Result.samples, [16_384, -16_384])
    }

    func testZeroSilenceVsQuietRoomNoiseTelemetry() throws {
        let frameCount = 960
        let asbd = AudioSampleExtractor.stereoInt16ASBD(sampleRate: 48_000)

        let zeroSamples = [Int16](repeating: 0, count: frameCount * 2)
        let zeroData = zeroSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let silentResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: zeroData, channels: 2)],
                asbd: asbd,
                frameCount: frameCount
            )
        )
        XCTAssertEqual(silentResult.maxAbsSample, 0)
        XCTAssertEqual(silentResult.rmsLevel, 0.0)

        // Low-level room mic noise (~ -42 dBFS -> Int16 250).
        let quietSamples = [Int16](repeating: 250, count: frameCount * 2)
        let quietData = quietSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let quietResult = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: quietData, channels: 2)],
                asbd: asbd,
                frameCount: frameCount
            )
        )
        XCTAssertEqual(quietResult.maxAbsSample, 250)
        XCTAssertGreaterThan(quietResult.rmsLevel, 0.0)
        XCTAssertLessThan(quietResult.rmsLevel, 0.5)
    }

    func testEndToEndMono44100MicAndSystemViaAudioPCMTrackMixer() throws {
        let frameCount44k = 4_410 // 0.1s @ 44.1 kHz
        let monoMic = [Float](repeating: 0.25, count: frameCount44k) // ~8192 in Int16
        let micData = monoMic.withUnsafeBufferPointer { Data(buffer: $0) }
        let micASBD = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let rawMicChunk = BufferedAudioChunk(
            pts: CMTime(seconds: 10.0, preferredTimescale: 44_100),
            duration: CMTime(value: CMTimeValue(frameCount44k), timescale: 44_100),
            pcmData: micData,
            asbd: micASBD,
            frameCount: UInt32(frameCount44k)
        )
        let micSB = try TestMediaFactory.makePCMSampleBuffer(from: rawMicChunk)
        let extractedMic = try XCTUnwrap(AudioSampleExtractor.extractStereoInt16(from: micSB))

        // 48 kHz Int16 system audio (+1000).
        let sysFrames = 4_800
        let sysSamples = [Int16](repeating: 1_000, count: sysFrames * 2)
        let sysData = sysSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sysChunk = BufferedAudioChunk(
            pts: CMTime(seconds: 10.0, preferredTimescale: 48_000),
            duration: CMTime(value: CMTimeValue(sysFrames), timescale: 48_000),
            pcmData: sysData,
            asbd: AudioPCMTrackMixer.canonicalASBD(),
            frameCount: UInt32(sysFrames)
        )

        let tracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: [sysChunk],
            micChunks: [extractedMic.chunk],
            originPTS: CMTime(seconds: 10.0, preferredTimescale: 600),
            endPTS: CMTime(seconds: 10.1, preferredTimescale: 600),
            micGain: 1.0,
            aacBitrateBps: 160_000,
            includeSeparateStems: true
        )
        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.map(\.isEnabledByDefault), [true, false, false])

        let totalMixFrames = tracks[0].chunks.reduce(0) { $0 + Int($1.frameCount) }
        XCTAssertEqual(totalMixFrames, 4_800)
        let midData = try XCTUnwrap(tracks[0].chunks.first?.pcmData)
        let midSamples = extractInt16(from: midData)
        // 1_000 (system) + 8_192 (mono 44.1kHz resampled to stereo 48kHz) = 9_192
        XCTAssertEqual(Double(midSamples[100]), 9_192.0, accuracy: 8.0)
    }

    func testReplayRingBufferSnapshotWithMicOverlappingBoundaryChunks() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 4.0, headroomSeconds: 2.0)

        // Video covers [1.00s, 2.00s) with 30 frames @ 30fps (lastVideoPTS = 1.9667s, lastVideoEndPTS = 2.00s).
        for index in 0..<30 {
            let packet = try TestMediaFactory.makeDummyVideoPacket(
                ptsSeconds: 1.0 + Double(index) / 30.0,
                durationSeconds: 1.0 / 30.0,
                isKeyframe: index == 0,
                byteSize: 1024
            )
            buffer.appendVideo(packet)
        }

        // Non-overlapping early chunk [0.96s, 0.98s) -> dropped even with includeOverlappingAudio = true.
        buffer.appendMicAudio(makeStereoInt16Chunk(ptsSeconds: 0.96, durationSeconds: 0.02, sample: 100))
        // Leading overlapping boundary chunk [0.99s, 1.01s) -> overlaps firstVideoPTS = 1.00s.
        buffer.appendMicAudio(makeStereoInt16Chunk(ptsSeconds: 0.99, durationSeconds: 0.02, sample: 2_000))
        // Interior chunk [1.50s, 1.52s).
        buffer.appendMicAudio(makeStereoInt16Chunk(ptsSeconds: 1.50, durationSeconds: 0.02, sample: 3_000))
        // Trailing frame-duration chunk [1.98s, 2.00s) -> after lastVideoPTS (1.9667s) but <= lastVideoEndPTS (2.00s).
        buffer.appendMicAudio(makeStereoInt16Chunk(ptsSeconds: 1.98, durationSeconds: 0.02, sample: 4_000))
        // Past-end chunk [2.02s, 2.04s) -> excluded.
        buffer.appendMicAudio(makeStereoInt16Chunk(ptsSeconds: 2.02, durationSeconds: 0.02, sample: 5_000))

        // Strict default mode preserves existing point-in-range contract.
        let strictSnap = buffer.snapshotWithMic()
        XCTAssertEqual(strictSnap.micAudio.count, 1)
        XCTAssertEqual(strictSnap.micAudio[0].pts.seconds, 1.50, accuracy: 0.001)

        // Overlapping mode preserves both boundary chunks overlapping [1.00s, 2.00s].
        let overlappingSnap = buffer.snapshotWithMic(includeOverlappingAudio: true)
        XCTAssertEqual(overlappingSnap.micAudio.count, 3)
        XCTAssertEqual(overlappingSnap.micAudio[0].pts.seconds, 0.99, accuracy: 0.001)
        XCTAssertEqual(overlappingSnap.micAudio[1].pts.seconds, 1.50, accuracy: 0.001)
        XCTAssertEqual(overlappingSnap.micAudio[2].pts.seconds, 1.98, accuracy: 0.001)

        let detailedOverlap = buffer.detailedSnapshot(includeOverlappingAudio: true)
        XCTAssertEqual(detailedOverlap.micAudio.count, 3)

        // Feed overlapping snapshot through AudioPCMTrackMixer to verify leading overlap aligns smoothly.
        let firstPTS = try XCTUnwrap(overlappingSnap.video.first?.pts)
        let lastPacket = try XCTUnwrap(overlappingSnap.video.last)
        let endPTS = CMTimeAdd(lastPacket.pts, lastPacket.duration)
        let tracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: [],
            micChunks: overlappingSnap.micAudio,
            originPTS: firstPTS,
            endPTS: endPTS,
            micGain: 1.0,
            aacBitrateBps: 160_000,
            includeSeparateStems: false
        )
        XCTAssertEqual(tracks.count, 1)
        let mixFirstSamples = extractInt16(from: try XCTUnwrap(tracks[0].chunks.first?.pcmData))
        // Leading [0.99s, 1.01s) chunk contributes sample value 2_000 at t = 1.00s (frame 0).
        XCTAssertEqual(mixFirstSamples[0], 2_000)
    }

    func testSegmentedFourBufferPlanarAndMultiSliceInterleavedAndMBytesPerFrameBug() throws {
        // 1. 4-buffer segmented planar Float32 ([L_256, R_256, L_256, R_256] = 512 frames) -> all 512 frames, zero silence hole.
        let halfFrames = 256
        let totalFrames = 512
        let leftHalf = [Float](repeating: 0.25, count: halfFrames).withUnsafeBufferPointer { Data(buffer: $0) }
        let rightHalf = [Float](repeating: -0.25, count: halfFrames).withUnsafeBufferPointer { Data(buffer: $0) }
        let planarNormalASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let segmentedPlanar = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [
                    (data: leftHalf, channels: 1),
                    (data: rightHalf, channels: 1),
                    (data: leftHalf, channels: 1),
                    (data: rightHalf, channels: 1)
                ],
                asbd: planarNormalASBD,
                frameCount: totalFrames
            )
        )
        XCTAssertEqual(segmentedPlanar.samples.count, totalFrames * 2)
        for frame in 0..<totalFrames {
            XCTAssertEqual(segmentedPlanar.samples[frame * 2], 8_192)
            XCTAssertEqual(segmentedPlanar.samples[frame * 2 + 1], -8_192)
        }

        // 2. 2-buffer multi-slice interleaved Float32 ([LR_256, LR_256] = 512 frames) -> preserves L/R without treating buffer 1 as Right.
        var lrSliceFloats: [Float] = []
        lrSliceFloats.reserveCapacity(halfFrames * 2)
        for _ in 0..<halfFrames {
            lrSliceFloats.append(0.25)  // Left -> +8192
            lrSliceFloats.append(-0.50) // Right -> -16384
        }
        let lrSliceData = lrSliceFloats.withUnsafeBufferPointer { Data(buffer: $0) }
        let interleavedASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let multiSliceInterleaved = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: lrSliceData, channels: 2), (data: lrSliceData, channels: 2)],
                asbd: interleavedASBD,
                frameCount: totalFrames
            )
        )
        XCTAssertEqual(multiSliceInterleaved.samples.count, totalFrames * 2)
        for frame in 0..<totalFrames {
            XCTAssertEqual(multiSliceInterleaved.samples[frame * 2], 8_192)
            XCTAssertEqual(multiSliceInterleaved.samples[frame * 2 + 1], -16_384)
        }

        // 3. 2-buffer planar Float32 (512 frames, 2048 bytes/plane) with erroneous interleaved asbd.mBytesPerFrame == 8 -> 512 frames, not 256.
        let fullLeft = [Float](repeating: 0.375, count: totalFrames).withUnsafeBufferPointer { Data(buffer: $0) }
        let fullRight = [Float](repeating: -0.375, count: totalFrames).withUnsafeBufferPointer { Data(buffer: $0) }
        let buggyPlanarASBD = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let fixedPlanar = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: fullLeft, channels: 1), (data: fullRight, channels: 1)],
                asbd: buggyPlanarASBD,
                frameCount: totalFrames
            )
        )
        XCTAssertEqual(fixedPlanar.samples.count, totalFrames * 2)
        XCTAssertEqual(fixedPlanar.samples[0], 12_288)
        XCTAssertEqual(fixedPlanar.samples[1], -12_288)
        XCTAssertEqual(fixedPlanar.samples[(totalFrames - 1) * 2], 12_288)
        XCTAssertEqual(fixedPlanar.samples[(totalFrames - 1) * 2 + 1], -12_288)

        // Single packed planar with erroneous mBytesPerFrame == 8 should also yield 512 frames.
        var packedBuggyPlanar = Data(fullLeft)
        packedBuggyPlanar.append(fullRight)
        let fixedPackedPlanar = try XCTUnwrap(
            AudioSampleExtractor.convertPlanarOrInterleavedToStereoInt16(
                buffers: [(data: packedBuggyPlanar, channels: 2)],
                asbd: buggyPlanarASBD,
                frameCount: totalFrames
            )
        )
        XCTAssertEqual(fixedPackedPlanar.samples.count, totalFrames * 2)
        XCTAssertEqual(fixedPackedPlanar.samples[(totalFrames - 1) * 2], 12_288)
        XCTAssertEqual(fixedPackedPlanar.samples[(totalFrames - 1) * 2 + 1], -12_288)
    }

    private func makeStereoInt16Chunk(ptsSeconds: Double, durationSeconds: Double, sample: Int16) -> BufferedAudioChunk {
        let rate: Double = 48_000
        let frameCount = max(1, Int((durationSeconds * rate).rounded()))
        let samples = [Int16](repeating: sample, count: frameCount * 2)
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return BufferedAudioChunk(
            pts: CMTime(seconds: ptsSeconds, preferredTimescale: 48_000),
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48_000),
            pcmData: data,
            asbd: AudioSampleExtractor.stereoInt16ASBD(sampleRate: rate),
            frameCount: UInt32(frameCount)
        )
    }

    private func extractInt16(from data: Data) -> [Int16] {
        var result: [Int16] = []
        result.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { raw in
            let count = raw.count / 2
            for i in 0..<count {
                result.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
            }
        }
        return result
    }
}
