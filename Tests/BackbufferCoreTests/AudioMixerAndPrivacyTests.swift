import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import XCTest
@testable import BackbufferCore

private final class MixerTestPacketCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BufferedVideoPacket] = []

    func append(_ packet: BufferedVideoPacket) {
        lock.lock()
        storage.append(packet)
        lock.unlock()
    }

    var packets: [BufferedVideoPacket] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AudioMixerAndPrivacyTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbuffer-audiomixer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    // MARK: - ReplayRingBuffer Mic Sync & Eviction

    func testReplayRingBufferMicAppendWindowEvictionAndSyncSnapshot() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 4.0, headroomSeconds: 2.0)

        for index in 0..<300 {
            let packet = try TestMediaFactory.makeDummyVideoPacket(
                ptsSeconds: Double(index) / 30.0,
                durationSeconds: 1.0 / 30.0,
                isKeyframe: index % 30 == 0,
                byteSize: 2048
            )
            buffer.appendVideo(packet)
        }

        // Feed 10.6 seconds of both system audio and out-of-order mic audio chunks.
        for index in 0..<530 {
            let pts = Double(index) * 0.02
            buffer.appendAudio(
                makeConstantInt16StereoChunk(ptsSeconds: pts, durationSeconds: 0.02, sampleRate: 48_000, left: 1000, right: 1000)
            )
        }
        for index in stride(from: 529, through: 0, by: -1) {
            let pts = Double(index) * 0.02
            buffer.appendMicAudio(
                makeConstantInt16StereoChunk(ptsSeconds: pts, durationSeconds: 0.02, sampleRate: 48_000, left: 2000, right: 2000)
            )
        }

        let snap = buffer.snapshotWithMic()
        XCTAssertFalse(snap.video.isEmpty)
        XCTAssertEqual(snap.video.first?.isKeyframe, true)

        let firstVideoPTS = try XCTUnwrap(snap.video.first?.pts)
        let lastVideoPTS = try XCTUnwrap(snap.video.last?.pts)

        XCTAssertFalse(snap.systemAudio.isEmpty)
        XCTAssertFalse(snap.micAudio.isEmpty)

        for chunk in snap.systemAudio {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(chunk.pts, firstVideoPTS), 0)
            XCTAssertLessThanOrEqual(CMTimeCompare(chunk.pts, lastVideoPTS), 0)
        }
        for chunk in snap.micAudio {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(chunk.pts, firstVideoPTS), 0)
            XCTAssertLessThanOrEqual(CMTimeCompare(chunk.pts, lastVideoPTS), 0)
        }

        let detailed = buffer.detailedSnapshot()
        XCTAssertEqual(detailed.audio.count, snap.systemAudio.count)
        XCTAssertEqual(detailed.micAudio.count, snap.micAudio.count)
        XCTAssertLessThan(buffer.currentStats().audioChunkCount, 800, "Expired system + mic chunks should be evicted.")

        // Also confirm mic audio evicts cleanly on video stall.
        buffer.clear()
        buffer.appendVideo(try TestMediaFactory.makeDummyVideoPacket(ptsSeconds: 0.0, isKeyframe: true, byteSize: 1024))
        for index in 0..<1000 {
            buffer.appendMicAudio(
                makeConstantInt16StereoChunk(
                    ptsSeconds: Double(index) * 0.02,
                    durationSeconds: 0.02,
                    sampleRate: 48_000,
                    left: 500,
                    right: 500
                )
            )
        }
        XCTAssertLessThanOrEqual(buffer.currentStats().audioChunkCount, 405)
        XCTAssertGreaterThan(buffer.currentStats().audioChunkCount, 0)
    }

    // MARK: - AudioPCMTrackMixer Clamping, Gain & Stems

    func testAudioPCMTrackMixerMixingClampingAndGainScaling() throws {
        let origin = CMTime(seconds: 10.0, preferredTimescale: 600)
        let end = CMTime(seconds: 10.1, preferredTimescale: 600)

        // Empty both -> empty tracks.
        let emptyTracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: [],
            micChunks: [],
            originPTS: origin,
            endPTS: end,
            micGain: 1.0,
            aacBitrateBps: 160_000,
            includeSeparateStems: true
        )
        XCTAssertTrue(emptyTracks.isEmpty)

        // Mic empty -> 1 enabled "Mix" track.
        let sysSmall = [
            makeConstantInt16StereoChunk(ptsSeconds: 10.0, durationSeconds: 0.1, sampleRate: 48_000, left: 1_000, right: 1_000)
        ]
        let sysOnlyTracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: sysSmall,
            micChunks: [],
            originPTS: origin,
            endPTS: end,
            micGain: 1.5,
            aacBitrateBps: 160_000,
            includeSeparateStems: true
        )
        XCTAssertEqual(sysOnlyTracks.count, 1)
        XCTAssertEqual(sysOnlyTracks[0].trackID, "Mix")
        XCTAssertTrue(sysOnlyTracks[0].isEnabledByDefault)

        // Positive saturation clamp: 30_000 + 20_000 -> 32_767; negative clamp: -30_000 + (-20_000) -> -32_768.
        let sysLoud = [
            makeConstantInt16StereoChunk(ptsSeconds: 10.0, durationSeconds: 0.1, sampleRate: 48_000, left: 30_000, right: -30_000)
        ]
        let micLoud = [
            makeConstantInt16StereoChunk(ptsSeconds: 10.0, durationSeconds: 0.1, sampleRate: 48_000, left: 20_000, right: -20_000)
        ]
        let clampedTracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: sysLoud,
            micChunks: micLoud,
            originPTS: origin,
            endPTS: end,
            micGain: 1.0,
            aacBitrateBps: 160_000,
            includeSeparateStems: false
        )
        XCTAssertEqual(clampedTracks.count, 1)
        XCTAssertTrue(clampedTracks[0].isEnabledByDefault)

        let clampedSamples = extractInterleavedInt16(from: clampedTracks[0].chunks)
        XCTAssertFalse(clampedSamples.isEmpty)
        XCTAssertEqual(clampedSamples[0], Int16.max)
        XCTAssertEqual(clampedSamples[1], Int16.min)

        // Gain scaling tests: 0.0, 0.5, 1.5 + clamping > 2.0, plus 3-track stems enabled flags.
        let micTone = [
            makeConstantInt16StereoChunk(ptsSeconds: 10.0, durationSeconds: 0.1, sampleRate: 48_000, left: 10_000, right: 10_000)
        ]

        let gainZero = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: sysSmall,
            micChunks: micTone,
            originPTS: origin,
            endPTS: end,
            micGain: 0.0,
            aacBitrateBps: 160_000,
            includeSeparateStems: true
        )
        XCTAssertEqual(gainZero.count, 3)
        XCTAssertEqual(gainZero.map(\.trackID), ["Mix", "Game Audio", "Microphone"])
        XCTAssertEqual(gainZero.map(\.isEnabledByDefault), [true, false, false])
        XCTAssertEqual(extractInterleavedInt16(from: gainZero[0].chunks).first, 1_000)
        XCTAssertEqual(extractInterleavedInt16(from: gainZero[1].chunks).first, 1_000)
        XCTAssertEqual(extractInterleavedInt16(from: gainZero[2].chunks).first, 10_000)

        let gainHalf = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: sysSmall,
            micChunks: micTone,
            originPTS: origin,
            endPTS: end,
            micGain: 0.5,
            aacBitrateBps: 160_000,
            includeSeparateStems: false
        )
        XCTAssertEqual(extractInterleavedInt16(from: gainHalf[0].chunks).first, 6_000)

        let gainBoost = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: sysSmall,
            micChunks: micTone,
            originPTS: origin,
            endPTS: end,
            micGain: 1.5,
            aacBitrateBps: 160_000,
            includeSeparateStems: false
        )
        XCTAssertEqual(extractInterleavedInt16(from: gainBoost[0].chunks).first, 16_000)

        // Empty system + active mic still renders Track 0 Mix cleanly.
        let micOnly = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: [],
            micChunks: micTone,
            originPTS: origin,
            endPTS: end,
            micGain: 0.5,
            aacBitrateBps: 160_000,
            includeSeparateStems: true
        )
        XCTAssertEqual(micOnly.count, 3)
        XCTAssertEqual(micOnly.map(\.isEnabledByDefault), [true, false, false])
        XCTAssertEqual(extractInterleavedInt16(from: micOnly[0].chunks).first, 5_000)
        XCTAssertEqual(extractInterleavedInt16(from: micOnly[1].chunks).first, 0)
        XCTAssertEqual(extractInterleavedInt16(from: micOnly[2].chunks).first, 10_000)
    }

    // MARK: - Mono Float32, Planar Stereo & Non-48kHz Resampling

    func testAudioPCMTrackMixerMonoFloatPlanarAndResampling() throws {
        let origin = CMTime(seconds: 5.0, preferredTimescale: 600)
        let end = CMTime(seconds: 5.2, preferredTimescale: 600)

        // Planar Float32 stereo 48kHz system audio (left = +0.25 -> ~8192, right = -0.25 -> ~-8192).
        let planarSystem = makePlanarFloat32StereoChunk(
            ptsSeconds: 5.0,
            durationSeconds: 0.2,
            sampleRate: 48_000,
            left: 0.25,
            right: -0.25
        )
        // Mono Float32 44.1kHz mic audio (0.125 -> ~4096 duplicated into both L and R).
        let monoMic44k = makeMonoFloat32Chunk(
            ptsSeconds: 5.0,
            durationSeconds: 0.2,
            sampleRate: 44_100,
            amplitude: 0.125
        )

        let tracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: [planarSystem],
            micChunks: [monoMic44k],
            originPTS: origin,
            endPTS: end,
            micGain: 1.0,
            aacBitrateBps: 160_000,
            includeSeparateStems: true
        )

        XCTAssertEqual(tracks.count, 3)
        let mixASBD = try XCTUnwrap(tracks[0].chunks.first?.asbd)
        XCTAssertEqual(mixASBD.mSampleRate, 48_000)
        XCTAssertEqual(mixASBD.mChannelsPerFrame, 2)
        XCTAssertEqual(mixASBD.mBitsPerChannel, 16)
        XCTAssertEqual(mixASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved, 0)

        let totalFrames = tracks[0].chunks.reduce(0) { $0 + Int($1.frameCount) }
        XCTAssertEqual(totalFrames, 9_600) // 0.2s * 48_000

        let mixSamples = extractInterleavedInt16(from: tracks[0].chunks)
        let midFrame = 4_800
        let leftSample = Int(mixSamples[midFrame * 2])
        let rightSample = Int(mixSamples[midFrame * 2 + 1])

        // Expected: L = +8192 + 4096 = +12288, R = -8192 + 4096 = -4096.
        XCTAssertEqual(Double(leftSample), 12_288, accuracy: 8.0)
        XCTAssertEqual(Double(rightSample), -4_096, accuracy: 8.0)
    }

    // MARK: - App Privacy Unit Verification

    func testCaptureSettingsPrivacyAllowlistAndBlockedModes() {
        var strict = CaptureSettings.default
        strict.privacyMode = .strictAllowlist
        strict.allowedAppBundleIDs = ["com.valvesoftware.cs2"]

        XCTAssertFalse(strict.isApplicationAllowed(bundleIdentifier: nil))
        XCTAssertFalse(strict.isApplicationAllowed(bundleIdentifier: ""))
        XCTAssertFalse(strict.isApplicationAllowed(bundleIdentifier: "com.apple.Safari"))
        XCTAssertTrue(strict.isApplicationAllowed(bundleIdentifier: "com.valvesoftware.cs2"))

        var blocklist = strict
        blocklist.privacyMode = .allowAllExceptBlocked
        blocklist.blockedAppBundleIDs = ["com.1password.1password"]

        XCTAssertTrue(blocklist.isApplicationAllowed(bundleIdentifier: nil))
        XCTAssertTrue(blocklist.isApplicationAllowed(bundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(blocklist.isApplicationAllowed(bundleIdentifier: "com.1password.1password"))

        var gainCheck = CaptureSettings.default
        gainCheck.microphoneGain = 5.0
        XCTAssertEqual(gainCheck.clampedMicrophoneGain(), 2.0)
        gainCheck.microphoneGain = -1.0
        XCTAssertEqual(gainCheck.clampedMicrophoneGain(), 0.0)
    }

    // MARK: - End-to-End 3-Track Mux & Compression Track Filtering

    func testThreeTrackMuxAndClipCompressorEnabledTrackFiltering() async throws {
        let collector = MixerTestPacketCollector()
        let encoder = try VideoEncoder(
            width: 640,
            height: 360,
            codec: .h264,
            bitrateBps: 8_000_000,
            fps: 30,
            maxKeyframeIntervalSeconds: 1.0,
            onPacket: { collector.append($0) }
        )

        let baseSeconds = 100.0
        let frameCount = 90 // 3.0s @ 30fps
        for index in 0..<frameCount {
            let pixelBuffer = try TestMediaFactory.makeNV12PixelBuffer(
                width: 640,
                height: 360,
                frameIndex: index,
                highEntropy: true
            )
            let pts = CMTime(seconds: baseSeconds + Double(index) / 30.0, preferredTimescale: 600)
            try encoder.encode(pixelBuffer, presentationTimeStamp: pts)
        }
        try encoder.flush()
        encoder.invalidate()

        let packets = collector.packets
        XCTAssertEqual(packets.count, frameCount)
        let originPTS = try XCTUnwrap(packets.first?.pts)
        let lastPacket = try XCTUnwrap(packets.last)
        let endPTS = lastPacket.duration.isNumeric && CMTimeCompare(lastPacket.duration, .zero) > 0
            ? CMTimeAdd(lastPacket.pts, lastPacket.duration)
            : CMTimeAdd(lastPacket.pts, CMTime(value: 1, timescale: 30))

        // Build 3s of digital-zero system audio + loud 440Hz sine mic audio, with micGain = 0.0:
        // Track 0 ("Mix", enabled=true) -> silent;
        // Track 1 ("Game Audio", enabled=false) -> silent;
        // Track 2 ("Microphone", enabled=false) -> loud (~16,000 amplitude).
        var silentSystem: [BufferedAudioChunk] = []
        var loudMic: [BufferedAudioChunk] = []
        for idx in 0..<150 {
            let pts = baseSeconds + Double(idx) * 0.02
            silentSystem.append(
                makeConstantInt16StereoChunk(ptsSeconds: pts, durationSeconds: 0.02, sampleRate: 48_000, left: 0, right: 0)
            )
            loudMic.append(
                TestMediaFactory.makeSineAudioChunk(
                    ptsSeconds: pts,
                    durationSeconds: 0.02,
                    sampleRate: 48_000,
                    frequencyHz: 440.0
                )
            )
        }

        let audioTracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: silentSystem,
            micChunks: loudMic,
            originPTS: originPTS,
            endPTS: endPTS,
            micGain: 0.0,
            aacBitrateBps: 128_000,
            includeSeparateStems: true
        )
        XCTAssertEqual(audioTracks.count, 3)

        let masterURL = tempRoot.appendingPathComponent("three_track_master.mp4")
        try await ClipMuxer.writeMP4(videoPackets: packets, audioTracks: audioTracks, to: masterURL)

        let masterAsset = AVURLAsset(url: masterURL)
        let masterAudioTracks = try await masterAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(masterAudioTracks.count, 3)

        var enabledFlags: [Bool] = []
        for track in masterAudioTracks {
            enabledFlags.append(try await track.load(.isEnabled))
        }
        XCTAssertEqual(enabledFlags, [true, false, false], "Only Track 0 (Mix) must be enabled by default.")

        // Verify Track 2 (Microphone stem) actually contains loud audio while Track 0 (Mix) is silent.
        let track0Peak = try await peakInt16Amplitude(of: masterAudioTracks[0], in: masterAsset)
        let track2Peak = try await peakInt16Amplitude(of: masterAudioTracks[2], in: masterAsset)
        XCTAssertLessThan(track0Peak, 500)
        XCTAssertGreaterThan(track2Peak, 5_000)

        // Force compression pass and verify disabled Track 2 does NOT bleed into compressed share MP4.
        let masterAttrs = try FileManager.default.attributesOfItem(atPath: masterURL.path)
        let masterSize = (masterAttrs[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(masterSize, 300_000)

        let compressedURL = tempRoot.appendingPathComponent("three_track_share.mp4")
        let capBytes = max(Int64(180_000), Int64(Double(masterSize) * 0.55))
        let resultURL = try await ClipCompressor.compressIfNeeded(
            masterURL: masterURL,
            outputURL: compressedURL,
            capBytes: capBytes,
            codec: .h264
        )
        XCTAssertEqual(resultURL.standardizedFileURL, compressedURL.standardizedFileURL)

        let compressedAsset = AVURLAsset(url: compressedURL)
        let compressedAudioTracks = try await compressedAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(compressedAudioTracks.count, 1)
        let compressedPeak = try await peakInt16Amplitude(of: compressedAudioTracks[0], in: compressedAsset)
        XCTAssertLessThan(compressedPeak, 500, "ClipCompressor must ignore disabled stems and only encode Track 0 (Mix).")
    }

    // MARK: - Helpers

    private func makeConstantInt16StereoChunk(
        ptsSeconds: Double,
        durationSeconds: Double,
        sampleRate: Double,
        left: Int16,
        right: Int16
    ) -> BufferedAudioChunk {
        let frameCount = max(1, Int((durationSeconds * sampleRate).rounded()))
        var samples = [Int16](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            samples[frame * 2] = left
            samples[frame * 2 + 1] = right
        }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        return BufferedAudioChunk(
            pts: CMTime(seconds: ptsSeconds, preferredTimescale: 48_000),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 48_000),
            pcmData: data,
            asbd: asbd,
            frameCount: UInt32(frameCount)
        )
    }

    private func makePlanarFloat32StereoChunk(
        ptsSeconds: Double,
        durationSeconds: Double,
        sampleRate: Double,
        left: Float,
        right: Float
    ) -> BufferedAudioChunk {
        let frameCount = max(1, Int((durationSeconds * sampleRate).rounded()))
        var planar = [Float](repeating: left, count: frameCount)
        planar.append(contentsOf: [Float](repeating: right, count: frameCount))
        let data = planar.withUnsafeBufferPointer { Data(buffer: $0) }
        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return BufferedAudioChunk(
            pts: CMTime(seconds: ptsSeconds, preferredTimescale: 48_000),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 48_000),
            pcmData: data,
            asbd: asbd,
            frameCount: UInt32(frameCount)
        )
    }

    private func makeMonoFloat32Chunk(
        ptsSeconds: Double,
        durationSeconds: Double,
        sampleRate: Double,
        amplitude: Float
    ) -> BufferedAudioChunk {
        let frameCount = max(1, Int((durationSeconds * sampleRate).rounded()))
        let mono = [Float](repeating: amplitude, count: frameCount)
        let data = mono.withUnsafeBufferPointer { Data(buffer: $0) }
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
        return BufferedAudioChunk(
            pts: CMTime(seconds: ptsSeconds, preferredTimescale: CMTimeScale(sampleRate)),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: CMTimeScale(sampleRate)),
            pcmData: data,
            asbd: asbd,
            frameCount: UInt32(frameCount)
        )
    }

    private func extractInterleavedInt16(from chunks: [BufferedAudioChunk]) -> [Int16] {
        var result: [Int16] = []
        for chunk in chunks {
            chunk.pcmData.withUnsafeBytes { raw in
                let count = raw.count / MemoryLayout<Int16>.stride
                for i in 0..<count {
                    result.append(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                }
            }
        }
        return result
    }

    private func peakInt16Amplitude(of track: AVAssetTrack, in asset: AVAsset) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading())

        var peak = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length >= 2 else { continue }

            var bytes = [UInt8](repeating: 0, count: length)
            let copyStatus = bytes.withUnsafeMutableBytes { ptr in
                CMBlockBufferCopyDataBytes(blockBuffer, atOffsetToData: 0, dataLength: length, destination: ptr.baseAddress!)
            }
            guard copyStatus == kCMBlockBufferNoErr else { continue }

            bytes.withUnsafeBytes { raw in
                let sampleCount = length / 2
                for idx in 0..<sampleCount {
                    let value = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: idx * 2, as: Int16.self)))
                    peak = max(peak, abs(value))
                }
            }
        }
        return peak
    }
}
