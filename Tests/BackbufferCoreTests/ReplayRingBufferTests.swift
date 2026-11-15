import CoreMedia
import Foundation
import XCTest
@testable import BackbufferCore

final class ReplayRingBufferTests: XCTestCase {
    func testSnapshotStartsOnKeyframeAndTrimsExpiredSegments() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 4.0, headroomSeconds: 2.0)

        // Feed 10 seconds at 30 FPS with 1-second IDR GOPs (keyframes at index 0, 30, 60, ..., 270).
        for index in 0..<300 {
            let ptsSeconds = Double(index) / 30.0
            let packet = try TestMediaFactory.makeDummyVideoPacket(
                ptsSeconds: ptsSeconds,
                durationSeconds: 1.0 / 30.0,
                isKeyframe: index % 30 == 0,
                byteSize: 4096
            )
            buffer.appendVideo(packet)
        }

        let snap = buffer.snapshot()
        XCTAssertFalse(snap.video.isEmpty)
        XCTAssertEqual(snap.video.first?.isKeyframe, true, "Snapshot must always begin on an IDR keyframe.")

        let firstPTS = try XCTUnwrap(snap.video.first?.pts.seconds)
        let lastPTS = try XCTUnwrap(snap.video.last?.pts.seconds)
        let snapshotSpan = lastPTS - firstPTS
        XCTAssertGreaterThanOrEqual(snapshotSpan, 4.0 - 0.05, "Snapshot must cover at least maxBufferSeconds.")
        XCTAssertGreaterThanOrEqual(firstPTS, lastPTS - 6.0, "Snapshot must not include expired packets older than latestVideoPTS - 6.0s.")

        // Ensure ring buffer itself evicted older GOPs instead of keeping all 300 packets (1,228,800 bytes).
        XCTAssertLessThan(buffer.currentEstimatedBytes(), 300 * 4096)
    }

    func testAudioEvictionDecoupledWhenVideoStalls() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 4.0, headroomSeconds: 2.0)

        // Initial short video GOP, then video callbacks stop.
        buffer.appendVideo(try TestMediaFactory.makeDummyVideoPacket(ptsSeconds: 0.0, isKeyframe: true, byteSize: 4096))
        buffer.appendVideo(try TestMediaFactory.makeDummyVideoPacket(ptsSeconds: 1.0 / 30.0, isKeyframe: false, byteSize: 1024))

        // Advance audio for 20 seconds (1,000 chunks of 20ms each) with zero new video frames.
        for index in 0..<1000 {
            let chunk = TestMediaFactory.makeSineAudioChunk(ptsSeconds: Double(index) * 0.02, durationSeconds: 0.02)
            buffer.appendAudio(chunk)
        }

        let stats = buffer.currentStats()
        // Max retained audio duration during stall is maxBufferSeconds + 4.0s = 8.0s (~400 chunks).
        XCTAssertLessThanOrEqual(stats.audioChunkCount, 405, "Audio must be evicted by PTS even when video stalls.")
        XCTAssertGreaterThan(stats.audioChunkCount, 0)
    }

    func testSnapshotClampsAudioToVideoSpan() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 4.0, headroomSeconds: 2.0)

        for index in 0..<300 {
            let packet = try TestMediaFactory.makeDummyVideoPacket(
                ptsSeconds: Double(index) / 30.0,
                durationSeconds: 1.0 / 30.0,
                isKeyframe: index % 30 == 0
            )
            buffer.appendVideo(packet)
        }

        // Feed audio extending past the last video frame (0.0s ..< 10.6s).
        for index in 0..<530 {
            let chunk = TestMediaFactory.makeSineAudioChunk(ptsSeconds: Double(index) * 0.02, durationSeconds: 0.02)
            buffer.appendAudio(chunk)
        }

        let snap = buffer.snapshot()
        let firstVideoPTS = try XCTUnwrap(snap.video.first?.pts)
        let lastVideoPTS = try XCTUnwrap(snap.video.last?.pts)

        XCTAssertFalse(snap.audio.isEmpty)
        for chunk in snap.audio {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(chunk.pts, firstVideoPTS), 0)
            XCTAssertLessThanOrEqual(CMTimeCompare(chunk.pts, lastVideoPTS), 0)
        }
    }

    func testSnapshotShortAndEmptyBuffer() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 30.0, headroomSeconds: 2.0)

        let emptySnap = buffer.snapshot()
        XCTAssertTrue(emptySnap.video.isEmpty)
        XCTAssertTrue(emptySnap.audio.isEmpty)
        XCTAssertEqual(buffer.currentEstimatedBytes(), 0)
        XCTAssertEqual(buffer.currentBufferedSeconds(), 0)

        // Orphaned leading P-frames before any keyframe must not leak into snapshots.
        buffer.appendVideo(try TestMediaFactory.makeDummyVideoPacket(ptsSeconds: 0.1, isKeyframe: false))
        buffer.appendVideo(try TestMediaFactory.makeDummyVideoPacket(ptsSeconds: 0.2, isKeyframe: false))
        XCTAssertTrue(buffer.snapshot().video.isEmpty)

        // Feed 0.8s partial capture starting with an IDR keyframe at t = 1.0s (24 frames @ 30fps).
        for index in 0..<24 {
            let packet = try TestMediaFactory.makeDummyVideoPacket(
                ptsSeconds: 1.0 + Double(index) / 30.0,
                durationSeconds: 1.0 / 30.0,
                isKeyframe: index == 0,
                byteSize: 2048
            )
            buffer.appendVideo(packet)
        }

        let shortSnap = buffer.detailedSnapshot()
        XCTAssertEqual(shortSnap.video.count, 24)
        XCTAssertEqual(shortSnap.video.first?.isKeyframe, true)
        XCTAssertGreaterThan(shortSnap.bufferedSeconds, 0.75)
        XCTAssertEqual(shortSnap.estimatedBytes, 24 * 2048)

        buffer.clear()
        XCTAssertTrue(buffer.snapshot().video.isEmpty)
        XCTAssertEqual(buffer.currentEstimatedBytes(), 0)
    }

    func testUpdateMaxBufferSecondsShrinksRetainedPackets() throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 6.0, headroomSeconds: 2.0)
        for index in 0..<300 {
            let packet = try TestMediaFactory.makeDummyVideoPacket(
                ptsSeconds: Double(index) / 30.0,
                durationSeconds: 1.0 / 30.0,
                isKeyframe: index % 30 == 0,
                byteSize: 4096
            )
            buffer.appendVideo(packet)
        }

        let bytesBefore = buffer.currentEstimatedBytes()
        buffer.updateMaxBufferSeconds(2.0)
        let bytesAfter = buffer.currentEstimatedBytes()

        XCTAssertLessThan(bytesAfter, bytesBefore)
        let snap = buffer.detailedSnapshot()
        XCTAssertEqual(snap.video.first?.isKeyframe, true)
        XCTAssertGreaterThanOrEqual(snap.bufferedSeconds, 2.0)
    }

    func testConcurrentAppendAndSnapshotThreadSafety() async throws {
        let buffer = ReplayRingBuffer(maxBufferSeconds: 2.0, headroomSeconds: 1.0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<180 {
                    let packet = try TestMediaFactory.makeDummyVideoPacket(
                        ptsSeconds: Double(index) / 30.0,
                        durationSeconds: 1.0 / 30.0,
                        isKeyframe: index % 30 == 0,
                        byteSize: 1024
                    )
                    buffer.appendVideo(packet)
                }
            }
            group.addTask {
                for index in 0..<300 {
                    let chunk = TestMediaFactory.makeSineAudioChunk(ptsSeconds: Double(index) * 0.02)
                    buffer.appendAudio(chunk)
                }
            }
            group.addTask {
                for _ in 0..<40 {
                    let snap = buffer.snapshot()
                    if let first = snap.video.first {
                        XCTAssertTrue(first.isKeyframe)
                    }
                    _ = buffer.currentStats()
                    try await Task.sleep(nanoseconds: 500_000)
                }
            }
            try await group.waitForAll()
        }
    }
}
