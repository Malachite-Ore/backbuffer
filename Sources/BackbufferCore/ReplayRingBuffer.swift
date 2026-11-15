import CoreMedia
import Foundation

public struct ReplayBufferStats: Equatable, Hashable, Sendable {
    public let bufferedSeconds: Double
    public let estimatedBytes: Int
    public let videoPacketCount: Int
    public let audioChunkCount: Int

    public init(
        bufferedSeconds: Double,
        estimatedBytes: Int,
        videoPacketCount: Int,
        audioChunkCount: Int
    ) {
        self.bufferedSeconds = bufferedSeconds
        self.estimatedBytes = estimatedBytes
        self.videoPacketCount = videoPacketCount
        self.audioChunkCount = audioChunkCount
    }
}

public struct ReplayBufferSnapshot: @unchecked Sendable {
    public let video: [BufferedVideoPacket]
    public let audio: [BufferedAudioChunk]
    public let bufferedSeconds: Double
    public let estimatedBytes: Int

    public init(
        video: [BufferedVideoPacket],
        audio: [BufferedAudioChunk],
        bufferedSeconds: Double,
        estimatedBytes: Int
    ) {
        self.video = video
        self.audio = audio
        self.bufferedSeconds = bufferedSeconds
        self.estimatedBytes = estimatedBytes
    }
}

/// Thread-safe, lock-guarded circular packet buffer keeping compressed video GOPs and LPCM audio chunks in RAM.
/// All video eviction aligns strictly to IDR keyframe boundaries so snapshots never contain orphaned trailing P/B frames.
public final class ReplayRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var maxBufferSeconds: Double
    private let headroomSeconds: Double
    private var videoPackets: [BufferedVideoPacket] = []
    private var audioChunks: [BufferedAudioChunk] = []
    private var totalVideoBytes: Int = 0
    private var totalAudioBytes: Int = 0

    public init(maxBufferSeconds: Double, headroomSeconds: Double = 2.0) {
        self.maxBufferSeconds = max(0.1, maxBufferSeconds)
        self.headroomSeconds = max(0.0, headroomSeconds)
    }

    public convenience init(maxDurationSeconds: Double, headroomSeconds: Double = 2.0) {
        self.init(maxBufferSeconds: maxDurationSeconds, headroomSeconds: headroomSeconds)
    }

    public func updateMaxBufferSeconds(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        maxBufferSeconds = max(0.1, seconds)
        evictExpiredLocked()
    }

    public func updateMaxDurationSeconds(_ seconds: Double) {
        updateMaxBufferSeconds(seconds)
    }

    public func appendVideo(_ packet: BufferedVideoPacket) {
        guard packet.pts.isNumeric else { return }

        lock.lock()
        defer { lock.unlock() }

        if videoPackets.isEmpty {
            // Never retain orphaned leading P/B frames prior to the first IDR keyframe.
            guard packet.isKeyframe else { return }
            videoPackets.append(packet)
            totalVideoBytes += packet.byteCount
        } else if CMTimeCompare(packet.pts, videoPackets[videoPackets.count - 1].pts) >= 0 {
            videoPackets.append(packet)
            totalVideoBytes += packet.byteCount
        } else {
            let insertionIndex = videoPackets.firstIndex { CMTimeCompare($0.pts, packet.pts) > 0 } ?? videoPackets.count
            if insertionIndex == 0 && !packet.isKeyframe {
                return
            }
            videoPackets.insert(packet, at: insertionIndex)
            totalVideoBytes += packet.byteCount
        }

        evictExpiredLocked()
    }

    public func appendAudio(_ chunk: BufferedAudioChunk) {
        guard chunk.pts.isNumeric, !chunk.pcmData.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if audioChunks.isEmpty || CMTimeCompare(chunk.pts, audioChunks[audioChunks.count - 1].pts) >= 0 {
            audioChunks.append(chunk)
            totalAudioBytes += chunk.pcmData.count
        } else {
            let insertionIndex = audioChunks.firstIndex { CMTimeCompare($0.pts, chunk.pts) > 0 } ?? audioChunks.count
            audioChunks.insert(chunk, at: insertionIndex)
            totalAudioBytes += chunk.pcmData.count
        }

        evictAudioLocked()
    }

    public func snapshot() -> (video: [BufferedVideoPacket], audio: [BufferedAudioChunk]) {
        let detailed = detailedSnapshot()
        return (video: detailed.video, audio: detailed.audio)
    }

    public func detailedSnapshot() -> ReplayBufferSnapshot {
        lock.lock()
        defer { lock.unlock() }

        guard let latestPacket = videoPackets.last else {
            return ReplayBufferSnapshot(video: [], audio: [], bufferedSeconds: 0, estimatedBytes: 0)
        }

        let targetDuration = CMTime(seconds: maxBufferSeconds, preferredTimescale: 600)
        let targetStartPTS = CMTimeSubtract(latestPacket.pts, targetDuration)

        // Pick the latest keyframe at or before (latestVideoPTS - maxBufferSeconds) so we keep
        // at least maxBufferSeconds when available, falling back to the earliest keyframe if newer.
        var startIndex: Int?
        for index in stride(from: videoPackets.count - 1, through: 0, by: -1) {
            let packet = videoPackets[index]
            if packet.isKeyframe && CMTimeCompare(packet.pts, targetStartPTS) <= 0 {
                startIndex = index
                break
            }
        }

        if startIndex == nil {
            startIndex = videoPackets.firstIndex { $0.isKeyframe }
        }

        guard let resolvedStartIndex = startIndex else {
            return ReplayBufferSnapshot(video: [], audio: [], bufferedSeconds: 0, estimatedBytes: 0)
        }

        let snapshotVideo = Array(videoPackets[resolvedStartIndex...])
        let firstVideoPTS = snapshotVideo[0].pts
        let lastVideoPacket = snapshotVideo[snapshotVideo.count - 1]
        let lastVideoPTS = lastVideoPacket.pts

        let snapshotAudio = audioChunks.filter { chunk in
            CMTimeCompare(chunk.pts, firstVideoPTS) >= 0 &&
            CMTimeCompare(chunk.pts, lastVideoPTS) <= 0
        }

        let bufferedSeconds = Self.spanSeconds(first: snapshotVideo[0], last: lastVideoPacket)
        let videoBytes = snapshotVideo.reduce(0) { $0 + $1.byteCount }
        let audioBytes = snapshotAudio.reduce(0) { $0 + $1.pcmData.count }

        return ReplayBufferSnapshot(
            video: snapshotVideo,
            audio: snapshotAudio,
            bufferedSeconds: bufferedSeconds,
            estimatedBytes: videoBytes + audioBytes
        )
    }

    public func currentEstimatedBytes() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return totalVideoBytes + totalAudioBytes
    }

    public func currentBufferedSeconds() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let first = videoPackets.first, let last = videoPackets.last else {
            return 0
        }
        return Self.spanSeconds(first: first, last: last)
    }

    public func currentStats() -> ReplayBufferStats {
        lock.lock()
        defer { lock.unlock() }
        let seconds: Double
        if let first = videoPackets.first, let last = videoPackets.last {
            seconds = Self.spanSeconds(first: first, last: last)
        } else {
            seconds = 0
        }
        return ReplayBufferStats(
            bufferedSeconds: seconds,
            estimatedBytes: totalVideoBytes + totalAudioBytes,
            videoPacketCount: videoPackets.count,
            audioChunkCount: audioChunks.count
        )
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        videoPackets.removeAll(keepingCapacity: false)
        audioChunks.removeAll(keepingCapacity: false)
        totalVideoBytes = 0
        totalAudioBytes = 0
    }

    // MARK: - Eviction (Caller holds lock)

    private func evictExpiredLocked() {
        evictVideoLocked()
        evictAudioLocked()
    }

    private func evictVideoLocked() {
        // Ensure prefix invariant: drop any accidental leading non-keyframes.
        if let first = videoPackets.first, !first.isKeyframe {
            if let firstKeyframe = videoPackets.firstIndex(where: { $0.isKeyframe }) {
                let removed = videoPackets[0..<firstKeyframe].reduce(0) { $0 + $1.byteCount }
                totalVideoBytes = max(0, totalVideoBytes - removed)
                videoPackets.removeFirst(firstKeyframe)
            } else {
                videoPackets.removeAll(keepingCapacity: false)
                totalVideoBytes = 0
                return
            }
        }

        guard let latestPacket = videoPackets.last, videoPackets.count > 1 else {
            return
        }

        let retentionWindow = CMTime(seconds: maxBufferSeconds + headroomSeconds, preferredTimescale: 600)
        let evictionCutoffPTS = CMTimeSubtract(latestPacket.pts, retentionWindow)

        // Retain from the latest keyframe at or before (latestVideoPTS - (maxBufferSeconds + headroomSeconds)).
        var latestEligibleKeyframeIndex: Int?
        for index in stride(from: videoPackets.count - 1, through: 0, by: -1) {
            let packet = videoPackets[index]
            if packet.isKeyframe && CMTimeCompare(packet.pts, evictionCutoffPTS) <= 0 {
                latestEligibleKeyframeIndex = index
                break
            }
        }

        if let evictToIndex = latestEligibleKeyframeIndex, evictToIndex > 0 {
            let removedBytes = videoPackets[0..<evictToIndex].reduce(0) { $0 + $1.byteCount }
            totalVideoBytes = max(0, totalVideoBytes - removedBytes)
            videoPackets.removeFirst(evictToIndex)
        }
    }

    private func evictAudioLocked() {
        guard let latestAudio = audioChunks.last else { return }

        let audioHeadroom = max(4.0, headroomSeconds + 2.0)
        let fallbackWindow = CMTime(seconds: maxBufferSeconds + audioHeadroom, preferredTimescale: 600)
        let fallbackCutoffPTS = CMTimeSubtract(latestAudio.pts, fallbackWindow)

        let audioCutoffPTS: CMTime
        if let oldestVideoPTS = videoPackets.first?.pts {
            // Take the later cutoff so audio never exceeds fallbackWindow during a video stall,
            // while normally aligning cleanly to the earliest retained video keyframe PTS.
            audioCutoffPTS = CMTimeMaximum(oldestVideoPTS, fallbackCutoffPTS)
        } else {
            audioCutoffPTS = fallbackCutoffPTS
        }

        var firstRetainedIndex = audioChunks.count
        for index in audioChunks.indices {
            let chunk = audioChunks[index]
            let chunkEndPTS = (chunk.duration.isNumeric && CMTimeCompare(chunk.duration, .zero) > 0)
                ? chunk.endPTS
                : chunk.pts
            if CMTimeCompare(chunkEndPTS, audioCutoffPTS) > 0 {
                firstRetainedIndex = index
                break
            }
        }

        if firstRetainedIndex > 0 {
            let removedBytes = audioChunks[0..<firstRetainedIndex].reduce(0) { $0 + $1.pcmData.count }
            totalAudioBytes = max(0, totalAudioBytes - removedBytes)
            audioChunks.removeFirst(firstRetainedIndex)
        }
    }

    private static func spanSeconds(first: BufferedVideoPacket, last: BufferedVideoPacket) -> Double {
        let endPTS: CMTime
        if last.duration.isNumeric && CMTimeCompare(last.duration, .zero) > 0 {
            endPTS = CMTimeAdd(last.pts, last.duration)
        } else {
            endPTS = last.pts
        }
        return max(0.0, CMTimeSubtract(endPTS, first.pts).seconds)
    }
}
