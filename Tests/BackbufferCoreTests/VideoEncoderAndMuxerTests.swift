import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import BackbufferCore

private final class PacketCollector: @unchecked Sendable {
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

final class VideoEncoderAndMuxerTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbuffer-media-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testEncodeAndMuxNormalizedZeroStartMP4() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let collector = PacketCollector()
        let encoder = try VideoEncoder(
            width: 640,
            height: 360,
            codec: .hevc,
            bitrateBps: 2_000_000,
            fps: 30,
            maxKeyframeIntervalSeconds: 1.0,
            onPacket: { collector.append($0) }
        )

        let baseSeconds = 4123.5
        for frameIndex in 0..<60 {
            let pixelBuffer = try TestMediaFactory.makeNV12PixelBuffer(
                width: 640,
                height: 360,
                frameIndex: frameIndex
            )
            let pts = CMTime(seconds: baseSeconds + Double(frameIndex) / 30.0, preferredTimescale: 600)
            try encoder.encode(pixelBuffer, presentationTimeStamp: pts)
        }
        try encoder.flush()
        encoder.invalidate()

        let packets = collector.packets
        XCTAssertEqual(packets.count, 60)
        XCTAssertEqual(packets.first?.isKeyframe, true)
        XCTAssertGreaterThanOrEqual(packets.filter(\.isKeyframe).count, 2, "Expected periodic 1s IDR keyframes.")

        var audioChunks: [BufferedAudioChunk] = []
        for idx in 0..<100 {
            audioChunks.append(
                TestMediaFactory.makeSineAudioChunk(
                    ptsSeconds: baseSeconds + Double(idx) * 0.02,
                    durationSeconds: 0.02
                )
            )
        }

        let outputURL = tempDir.appendingPathComponent("normalized_hevc.mp4")
        try await ClipMuxer.writeMP4(
            videoPackets: packets,
            audioTracks: [AudioTrackInput(trackID: "system", chunks: audioChunks, aacBitrateBps: 160_000)],
            to: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration)
        XCTAssertTrue((1.8...2.2).contains(duration.seconds), "Expected ~2.0s duration, got \(duration.seconds)")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let videoTimeRange = try await videoTracks[0].load(.timeRange)
        XCTAssertLessThan(abs(videoTimeRange.start.seconds), 0.001, "Muxed clip must start cleanly at 00:00.")

        let videoFormats = try await videoTracks[0].load(.formatDescriptions)
        XCTAssertFalse(videoFormats.isEmpty)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(videoFormats[0]), kCMVideoCodecType_HEVC)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let audioFormats = try await audioTracks[0].load(.formatDescriptions)
        XCTAssertFalse(audioFormats.isEmpty)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(audioFormats[0]), kAudioFormatMPEG4AAC)
    }

    func testMuxVideoOnlyWhenAudioChunksEmpty() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let emptyURL = tempDir.appendingPathComponent("should_not_exist.mp4")
        do {
            try await ClipMuxer.writeMP4(videoPackets: [], audioTracks: [], to: emptyURL)
            XCTFail("Expected BackbufferError.emptyBuffer for empty videoPackets.")
        } catch let error as BackbufferError {
            XCTAssertEqual(error, .emptyBuffer)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path))

        let collector = PacketCollector()
        let encoder = try VideoEncoder(
            width: 320,
            height: 180,
            codec: .h264,
            bitrateBps: 1_200_000,
            fps: 30,
            onPacket: { collector.append($0) }
        )

        for frameIndex in 0..<30 {
            let pb = try TestMediaFactory.makeNV12PixelBuffer(width: 320, height: 180, frameIndex: frameIndex)
            let pts = CMTime(seconds: 100.0 + Double(frameIndex) / 30.0, preferredTimescale: 600)
            try encoder.encode(pb, presentationTimeStamp: pts)
        }
        try encoder.flush()
        encoder.invalidate()

        let videoOnlyURL = tempDir.appendingPathComponent("video_only.mp4")
        try await ClipMuxer.writeMP4(
            videoPackets: collector.packets,
            audioTracks: [AudioTrackInput(trackID: "empty", chunks: [])],
            to: videoOnlyURL
        )

        let asset = AVURLAsset(url: videoOnlyURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)

        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 0, "Empty audio tracks must not emit broken audio tracks.")
        XCTAssertTrue((0.85...1.15).contains(duration.seconds))
    }

    func testEncoderHandlesOddDimensionsSafely() throws {
        let dims = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: 1279,
            logicalHeight: 719,
            pointPixelScale: 1.0,
            cap: .native
        )
        XCTAssertEqual(dims.width, 1278)
        XCTAssertEqual(dims.height, 718)

        let pool = try PixelTransferPool(width: 1279, height: 719)
        XCTAssertEqual(pool.width, 1278)
        XCTAssertEqual(pool.height, 718)

        let collector = PacketCollector()
        let encoder = try VideoEncoder(
            width: 1279,
            height: 719,
            codec: .h264,
            bitrateBps: 2_000_000,
            fps: 30,
            onPacket: { collector.append($0) }
        )
        XCTAssertEqual(encoder.width, 1278)
        XCTAssertEqual(encoder.height, 718)

        for frameIndex in 0..<15 {
            let oddSource = try TestMediaFactory.makeNV12PixelBuffer(width: 1279, height: 719, frameIndex: frameIndex)
            let detached = try pool.copyToDetachedBuffer(oddSource)
            XCTAssertEqual(CVPixelBufferGetWidth(detached), 1278)
            XCTAssertEqual(CVPixelBufferGetHeight(detached), 718)

            let pts = CMTime(seconds: Double(frameIndex) / 30.0, preferredTimescale: 600)
            try encoder.encode(detached, presentationTimeStamp: pts)
        }
        try encoder.flush()
        encoder.invalidate()
        pool.invalidate()

        XCTAssertEqual(collector.packets.count, 15)
        XCTAssertEqual(collector.packets.first?.isKeyframe, true)

        // Verify Intel QuickSync 4096 px width clamp is also enforced at VideoEncoder init.
        let clampedEncoder = try VideoEncoder(
            width: 5120,
            height: 2880,
            codec: .hevc,
            bitrateBps: 10_000_000,
            fps: 60,
            onPacket: { _ in }
        )
        XCTAssertEqual(clampedEncoder.width, 4096)
        XCTAssertEqual(clampedEncoder.height, 2304)
        clampedEncoder.invalidate()
    }

    func testMultiTrackAudioSeamWritesTwoDiscreteAudioTracks() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let collector = PacketCollector()
        let encoder = try VideoEncoder(
            width: 320,
            height: 180,
            codec: .h264,
            bitrateBps: 1_500_000,
            fps: 30,
            onPacket: { collector.append($0) }
        )

        let startSeconds = 500.0
        for frameIndex in 0..<30 {
            let pb = try TestMediaFactory.makeNV12PixelBuffer(width: 320, height: 180, frameIndex: frameIndex)
            let pts = CMTime(seconds: startSeconds + Double(frameIndex) / 30.0, preferredTimescale: 600)
            try encoder.encode(pb, presentationTimeStamp: pts)
        }
        try encoder.flush()
        encoder.invalidate()

        let gameChunks = (0..<50).map { idx in
            TestMediaFactory.makeSineAudioChunk(
                ptsSeconds: startSeconds + Double(idx) * 0.02,
                durationSeconds: 0.02,
                frequencyHz: 440.0
            )
        }
        let micChunks = (0..<50).map { idx in
            TestMediaFactory.makeSineAudioChunk(
                ptsSeconds: startSeconds + Double(idx) * 0.02,
                durationSeconds: 0.02,
                frequencyHz: 880.0
            )
        }

        let outputURL = tempDir.appendingPathComponent("multitrack_3c.mp4")
        try await ClipMuxer.writeMP4(
            videoPackets: collector.packets,
            audioTracks: [
                AudioTrackInput(trackID: "game", chunks: gameChunks, aacBitrateBps: 160_000),
                AudioTrackInput(trackID: "mic", chunks: micChunks, aacBitrateBps: 128_000)
            ],
            to: outputURL
        )

        let asset = AVURLAsset(url: outputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 2, "Expected 2 discrete AAC audio tracks for 3C mic+game readiness.")
    }

    func testCFRKeepaliveEmitsConstantFramesWhenLiveInputStalls() async throws {
        let collector = PacketCollector()
        let encoder = try VideoEncoder(
            width: 320,
            height: 180,
            codec: .h264,
            bitrateBps: 1_000_000,
            fps: 30,
            maxKeyframeIntervalSeconds: 1.0,
            enableCFRKeepalive: true,
            onPacket: { collector.append($0) }
        )

        let frame0 = try TestMediaFactory.makeNV12PixelBuffer(width: 320, height: 180, frameIndex: 0)
        let frame1 = try TestMediaFactory.makeNV12PixelBuffer(width: 320, height: 180, frameIndex: 1)

        try encoder.ingestLivePixelBuffer(frame0, presentationTimeStamp: CMTime(seconds: 10.0, preferredTimescale: 600))
        try encoder.ingestLivePixelBuffer(frame1, presentationTimeStamp: CMTime(seconds: 10.0 + 1.0 / 30.0, preferredTimescale: 600))

        // Pause live input for 300ms so the 30fps CFR keepalive fills the static gap.
        try await Task.sleep(nanoseconds: 300_000_000)

        try encoder.flush()
        encoder.invalidate()

        let packets = collector.packets
        XCTAssertGreaterThanOrEqual(packets.count, 4, "CFR keepalive should synthesize static frames while live input stalls.")
        for index in 1..<packets.count {
            XCTAssertGreaterThan(
                CMTimeCompare(packets[index].pts, packets[index - 1].pts),
                0,
                "Keepalive must preserve strict PTS monotonicity."
            )
        }
    }

    func testClipMuxerNormalizesPlanarAudioAndPreClipOverlap() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let collector = PacketCollector()
        let encoder = try VideoEncoder(
            width: 320,
            height: 180,
            codec: .h264,
            bitrateBps: 1_200_000,
            fps: 30,
            onPacket: { collector.append($0) }
        )

        let clipStart = 10.0
        for frameIndex in 0..<30 {
            let pb = try TestMediaFactory.makeNV12PixelBuffer(width: 320, height: 180, frameIndex: frameIndex)
            try encoder.encode(pb, presentationTimeStamp: CMTime(seconds: clipStart + Double(frameIndex) / 30.0, preferredTimescale: 600))
        }
        try encoder.flush()
        encoder.invalidate()

        // Create planar Float32 stereo chunks starting slightly before clipStart (9.99s).
        let sampleRate = 48_000.0
        let channels: UInt32 = 2
        let frameCount: UInt32 = 960 // 20ms
        let planarASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var planarChunks: [BufferedAudioChunk] = []
        for idx in 0..<50 {
            let ptsSeconds = 9.99 + Double(idx) * 0.02
            var channelData = [Float](repeating: 0, count: Int(frameCount * channels))
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(2.0 * Double.pi * 440.0 * (ptsSeconds + Double(frame) / sampleRate)) * 0.25)
                channelData[frame] = sample
                channelData[Int(frameCount) + frame] = sample
            }
            let data = channelData.withUnsafeBytes { Data($0) }
            planarChunks.append(
                BufferedAudioChunk(
                    pts: CMTime(seconds: ptsSeconds, preferredTimescale: 48_000),
                    duration: CMTime(value: CMTimeValue(frameCount), timescale: 48_000),
                    pcmData: data,
                    asbd: planarASBD,
                    frameCount: frameCount
                )
            )
        }

        let outputURL = tempDir.appendingPathComponent("planar_audio.mp4")
        try await ClipMuxer.writeMP4(
            videoPackets: collector.packets,
            audioTracks: [AudioTrackInput(trackID: "planar", chunks: planarChunks)],
            to: outputURL
        )

        let asset = AVURLAsset(url: outputURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
    }
}
