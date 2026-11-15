import AVFoundation
import CoreMedia
import Foundation
import XCTest
@testable import BackbufferCore

final class ClipCompressorAndTrimmerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackbufferCompressorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testBitrateCalculationAndSmart720pDownscale() {
        let longLowCap = ClipCompressor.computeTargetBitrate(
            capBytes: 10_000_000,
            durationSeconds: 120.0
        )
        XCTAssertEqual(longLowCap.audioBps, 96_000)
        XCTAssertLessThan(longLowCap.videoBps, 1_200_000)
        XCTAssertTrue(longLowCap.shouldDownscaleTo720p)

        let standard30s = ClipCompressor.computeTargetBitrate(
            capBytes: 20_000_000,
            durationSeconds: 30.0
        )
        XCTAssertEqual(standard30s.audioBps, 128_000)
        XCTAssertGreaterThanOrEqual(standard30s.videoBps, 1_200_000)
        XCTAssertFalse(standard30s.shouldDownscaleTo720p)
    }

    func testCompressorEnforcesHardByteCeilingAndPreservesMasterSHA256() async throws {
        let mastersDir = tempRoot.appendingPathComponent("Masters", isDirectory: true)
        let sharedDir = tempRoot.appendingPathComponent("Shared", isDirectory: true)
        let masterURL = mastersDir.appendingPathComponent("Backbuffer_2026-11-15_16-00-00.mp4")
        let shareURL = sharedDir.appendingPathComponent("Backbuffer_2026-11-15_16-00-00_share.mp4")

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 4.0,
            fps: 30,
            width: 640,
            height: 360,
            videoBitrateBps: 8_000_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: true
        )

        let masterSHA = try TestMediaFactory.sha256Hex(of: masterURL)
        let masterSize = try fileSize(of: masterURL)
        XCTAssertGreaterThan(masterSize, 900_000, "Expected high-entropy master to exceed 900 KB, got \(masterSize)")

        let capBytes = min(Int64(1_500_000), max(Int64(450_000), Int64(Double(masterSize) * 0.55)))
        let resultURL = try await ClipCompressor.compressIfNeeded(
            masterURL: masterURL,
            outputURL: shareURL,
            capBytes: capBytes,
            codec: .h264
        )

        XCTAssertEqual(resultURL.standardizedFileURL, shareURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shareURL.path))

        let compressedSize = try fileSize(of: shareURL)
        XCTAssertGreaterThan(compressedSize, 0)
        XCTAssertLessThanOrEqual(compressedSize, capBytes, "Compressed share clip (\(compressedSize)) exceeded cap (\(capBytes))")

        let compressedAsset = AVURLAsset(url: shareURL)
        let duration = CMTimeGetSeconds(try await compressedAsset.load(.duration))
        XCTAssertEqual(duration, 4.0, accuracy: 0.35)
        let videoTracks = try await compressedAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)

        let postMasterSHA = try TestMediaFactory.sha256Hex(of: masterURL)
        XCTAssertEqual(postMasterSHA, masterSHA, "Master clip was unexpectedly modified during compression")
    }

    func testCompressorSkipsAlreadySmallMaster() async throws {
        let masterURL = tempRoot.appendingPathComponent("Masters/small_clip.mp4")
        let shareURL = tempRoot.appendingPathComponent("Shared/small_clip_share.mp4")

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 2.0,
            fps: 30,
            width: 320,
            height: 180,
            videoBitrateBps: 800_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: false
        )

        let masterSize = try fileSize(of: masterURL)
        XCTAssertLessThan(masterSize, 2_000_000)

        let resultURL = try await ClipCompressor.compressIfNeeded(
            masterURL: masterURL,
            outputURL: shareURL,
            capBytes: 10_000_000,
            codec: .hevc
        )

        XCTAssertEqual(resultURL.standardizedFileURL, masterURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareURL.path))
    }

    func testCompressorDownscales1080pTo720pWhenTargetBitrateLow() async throws {
        let masterURL = tempRoot.appendingPathComponent("Masters/hd_900p.mp4")
        let shareURL = tempRoot.appendingPathComponent("Shared/hd_900p_share.mp4")

        // Use 1440x810 (> 720p) at 10 fps over 6s (60 high-entropy frames) so the master
        // is genuinely large (~2.5-3 MB) while remaining fast to synthesize in Debug CI.
        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 6.0,
            fps: 10,
            width: 1440,
            height: 810,
            videoBitrateBps: 4_000_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: true
        )

        let capBytes: Int64 = 750_000
        let plan = ClipCompressor.computeTargetBitrate(capBytes: capBytes, durationSeconds: 6.0)
        XCTAssertTrue(plan.shouldDownscaleTo720p)

        let outputURL = try await ClipCompressor.compressIfNeeded(
            masterURL: masterURL,
            outputURL: shareURL,
            capBytes: capBytes,
            codec: .h264
        )

        XCTAssertEqual(outputURL.standardizedFileURL, shareURL.standardizedFileURL)
        let outputSize = try fileSize(of: shareURL)
        XCTAssertLessThanOrEqual(outputSize, capBytes)

        let asset = AVURLAsset(url: shareURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width.rounded()), 1280)
        XCTAssertEqual(Int(naturalSize.height.rounded()), 720)
    }

    func testTrimLosslessAndTrimCompressed() async throws {
        let masterURL = tempRoot.appendingPathComponent("Masters/Backbuffer_2026-11-15_16-05-00.mp4")
        let losslessTrimURL = tempRoot.appendingPathComponent("Masters/Backbuffer_2026-11-15_16-05-00_trim_01s-03s.mp4")
        let compressedTrimURL = tempRoot.appendingPathComponent("Shared/Backbuffer_2026-11-15_16-05-00_trim_01s-03s_share.mp4")
        let fallbackTrimURL = tempRoot.appendingPathComponent("Shared/Backbuffer_2026-11-15_16-05-00_trim_01s-03s_fallback_share.mp4")

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 5.0,
            fps: 30,
            width: 640,
            height: 360,
            videoBitrateBps: 6_000_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: true
        )

        let masterSHA = try TestMediaFactory.sha256Hex(of: masterURL)
        let range = TrimRange(startSeconds: 1.0, endSeconds: 3.0)

        let losslessResult = try await ClipTrimmer.trimLossless(
            masterURL: masterURL,
            range: range,
            outputURL: losslessTrimURL
        )
        XCTAssertEqual(losslessResult.standardizedFileURL, losslessTrimURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: losslessTrimURL.path))

        let losslessAsset = AVURLAsset(url: losslessTrimURL)
        let losslessDuration = CMTimeGetSeconds(try await losslessAsset.load(.duration))
        XCTAssertEqual(losslessDuration, 2.0, accuracy: 0.35)
        let losslessVideoTracks = try await losslessAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(losslessVideoTracks.count, 1)

        let losslessBytes = try fileSize(of: losslessTrimURL)
        let tightCapBytes = min(Int64(700_000), max(Int64(280_000), Int64(Double(losslessBytes) * 0.55)))

        let compressedResult = try await ClipTrimmer.trimCompressed(
            masterURL: masterURL,
            range: range,
            outputURL: compressedTrimURL,
            capBytes: tightCapBytes,
            codec: .h264
        )
        XCTAssertEqual(compressedResult.standardizedFileURL, compressedTrimURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressedTrimURL.path))

        let compressedBytes = try fileSize(of: compressedTrimURL)
        XCTAssertGreaterThan(compressedBytes, 0)
        XCTAssertLessThanOrEqual(compressedBytes, tightCapBytes)

        let compressedAsset = AVURLAsset(url: compressedTrimURL)
        let compressedDuration = CMTimeGetSeconds(try await compressedAsset.load(.duration))
        XCTAssertEqual(compressedDuration, 2.0, accuracy: 0.35)

        // Verify Builder Call 3 ShareCapOption.off fallback (targets 20 MB Discord limit)
        let fallbackResult = try await ClipTrimmer.trimCompressed(
            masterURL: masterURL,
            range: range,
            outputURL: fallbackTrimURL,
            shareCap: .off,
            codec: .h264
        )
        XCTAssertEqual(fallbackResult.standardizedFileURL, fallbackTrimURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fallbackTrimURL.path))
        let fallbackBytes = try fileSize(of: fallbackTrimURL)
        XCTAssertLessThanOrEqual(fallbackBytes, 20_000_000)

        let postMasterSHA = try TestMediaFactory.sha256Hex(of: masterURL)
        XCTAssertEqual(postMasterSHA, masterSHA)
    }

    func testTrimRangeValidationRejectsInvalidBounds() async throws {
        let masterURL = tempRoot.appendingPathComponent("Masters/validation_clip.mp4")
        let outputURL = tempRoot.appendingPathComponent("Masters/validation_clip_trim.mp4")

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 3.0,
            fps: 30,
            width: 320,
            height: 180,
            videoBitrateBps: 1_000_000,
            codec: .h264,
            includeAudio: false,
            highEntropy: false
        )

        let invalidRanges = [
            TrimRange(startSeconds: -0.5, endSeconds: 1.5),
            TrimRange(startSeconds: 2.0, endSeconds: 2.0),
            TrimRange(startSeconds: 2.5, endSeconds: 1.0),
            TrimRange(startSeconds: 1.0, endSeconds: 4.5)
        ]

        for badRange in invalidRanges {
            do {
                try await ClipTrimmer.trimLossless(masterURL: masterURL, range: badRange, outputURL: outputURL)
                XCTFail("Expected trimRangeInvalid for \(badRange)")
            } catch let error as BackbufferError {
                XCTAssertEqual(error, .trimRangeInvalid)
            }

            do {
                try await ClipTrimmer.trimCompressed(
                    masterURL: masterURL,
                    range: badRange,
                    outputURL: outputURL,
                    capBytes: 500_000,
                    codec: .h264
                )
                XCTFail("Expected trimRangeInvalid for \(badRange)")
            } catch let error as BackbufferError {
                XCTAssertEqual(error, .trimRangeInvalid)
            }
        }
    }

    func testCompressorSupportsHEVCCodec() async throws {
        let masterURL = tempRoot.appendingPathComponent("Masters/hevc_source.mp4")
        let shareURL = tempRoot.appendingPathComponent("Shared/hevc_source_share.mp4")

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 3.0,
            fps: 30,
            width: 640,
            height: 360,
            videoBitrateBps: 6_000_000,
            codec: .hevc,
            includeAudio: true,
            highEntropy: true
        )

        let masterSize = try fileSize(of: masterURL)
        let capBytes = max(Int64(450_000), Int64(Double(masterSize) * 0.55))
        let resultURL = try await ClipCompressor.compressIfNeeded(
            masterURL: masterURL,
            outputURL: shareURL,
            capBytes: capBytes,
            codec: .hevc
        )

        XCTAssertEqual(resultURL.standardizedFileURL, shareURL.standardizedFileURL)
        let compressedSize = try fileSize(of: shareURL)
        XCTAssertGreaterThan(compressedSize, 0)
        XCTAssertLessThanOrEqual(compressedSize, capBytes)
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
