import AVFoundation
import CoreMedia
import Foundation

public enum ClipTrimmer {
    /// Exports a fast lossless passthrough trim of `masterURL` over `range` into `outputURL`.
    /// Falls back to a high-quality transcode export if passthrough is incompatible with the container/stream.
    /// Never modifies `masterURL`.
    @discardableResult
    public static func trimLossless(
        masterURL: URL,
        range: TrimRange,
        outputURL: URL
    ) async throws -> URL {
        guard masterURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw BackbufferError.trimFailed("Trimmed output URL must differ from original master URL.")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: masterURL.path) else {
            throw BackbufferError.libraryIOFailed("Master clip not found at \(masterURL.path)")
        }

        let asset = AVURLAsset(url: masterURL)
        let sourceDuration = try await validatedSourceDuration(asset: asset, range: range)

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else {
            throw BackbufferError.missingAssetTrack("video")
        }
        _ = sourceDuration

        do {
            return try await runExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough,
                timeRange: range.cmTimeRange,
                destinationURL: outputURL
            )
        } catch {
            // Passthrough can occasionally reject non-keyframe or non-MP4 source streams;
            // fall back cleanly to a high-quality transcode export without touching the master.
            return try await runExportSession(
                asset: asset,
                presetName: AVAssetExportPresetHighestQuality,
                timeRange: range.cmTimeRange,
                destinationURL: outputURL
            )
        }
    }

    /// Exports a non-destructive `1:N` Share-trimmed MP4 into `outputURL` strictly `<= capBytes`.
    /// Uses fast passthrough if the trimmed segment already fits under `96%` of `capBytes` and matches
    /// the requested duration cleanly; otherwise runs hardware bitrate-capped compression over `range`.
    @discardableResult
    public static func trimCompressed(
        masterURL: URL,
        range: TrimRange,
        outputURL: URL,
        capBytes: Int64,
        codec: VideoCodecChoice
    ) async throws -> URL {
        guard masterURL.standardizedFileURL != outputURL.standardizedFileURL else {
            throw BackbufferError.trimFailed("Share trim output URL must differ from original master URL.")
        }
        guard capBytes > 0 else {
            throw BackbufferError.compressionFailed("Target capBytes must be positive.")
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: masterURL.path) else {
            throw BackbufferError.libraryIOFailed("Master clip not found at \(masterURL.path)")
        }

        let asset = AVURLAsset(url: masterURL)
        _ = try await validatedSourceDuration(asset: asset, range: range)

        // Attempt lossless passthrough into a temp file first: if the trimmed span already
        // fits comfortably under the cap and honors the requested span, keep it untouched.
        let probeURL = fm.temporaryDirectory.appendingPathComponent("backbuffer-trim-probe-\(UUID().uuidString).mp4")
        defer {
            if fm.fileExists(atPath: probeURL.path) {
                try? fm.removeItem(at: probeURL)
            }
        }

        if (try? await runExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough,
            timeRange: range.cmTimeRange,
            destinationURL: probeURL
        )) != nil {
            if let probeSize = try? ClipCompressor.fileSize(of: probeURL),
               probeSize > 0,
               probeSize <= Int64(Double(capBytes) * 0.96) {
                let probeAsset = AVURLAsset(url: probeURL)
                if let probeDurationCM = try? await probeAsset.load(.duration) {
                    let probeDuration = CMTimeGetSeconds(probeDurationCM)
                    if probeDuration.isFinite, abs(probeDuration - range.durationSeconds) <= 0.25 {
                        try ClipCompressor.moveReplacingExisting(from: probeURL, to: outputURL)
                        return outputURL
                    }
                }
            }
        }

        return try await ClipCompressor.compressRange(
            masterURL: masterURL,
            timeRange: range.cmTimeRange,
            outputURL: outputURL,
            capBytes: capBytes,
            codec: codec
        )
    }

    /// Builder Call 3 convenience overload using `ShareCapOption`, falling back to `20 MB` when `.off`.
    @discardableResult
    public static func trimCompressed(
        masterURL: URL,
        range: TrimRange,
        outputURL: URL,
        shareCap: ShareCapOption,
        codec: VideoCodecChoice
    ) async throws -> URL {
        let effectiveCap = shareCap.capBytes ?? (ShareCapOption.mb20.capBytes ?? 20_000_000)
        return try await trimCompressed(
            masterURL: masterURL,
            range: range,
            outputURL: outputURL,
            capBytes: effectiveCap,
            codec: codec
        )
    }

    // MARK: - Helpers

    private static func validatedSourceDuration(asset: AVAsset, range: TrimRange) async throws -> Double {
        let durationCM = try await asset.load(.duration)
        let sourceDuration = CMTimeGetSeconds(durationCM)
        guard sourceDuration.isFinite,
              sourceDuration > 0,
              range.startSeconds.isFinite,
              range.endSeconds.isFinite,
              range.isValid(sourceDuration: sourceDuration) else {
            throw BackbufferError.trimRangeInvalid
        }
        return sourceDuration
    }

    private static func runExportSession(
        asset: AVAsset,
        presetName: String,
        timeRange: CMTimeRange,
        destinationURL: URL
    ) async throws -> URL {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw BackbufferError.trimFailed("Could not create AVAssetExportSession for preset \(presetName).")
        }

        let fm = FileManager.default
        let tempURL = fm.temporaryDirectory.appendingPathComponent("backbuffer-trim-\(UUID().uuidString).mp4")
        defer {
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
        }

        let fileType: AVFileType = exportSession.supportedFileTypes.contains(.mp4) ? .mp4 : (exportSession.supportedFileTypes.first ?? .mp4)
        exportSession.outputURL = tempURL
        exportSession.outputFileType = fileType
        exportSession.timeRange = timeRange
        exportSession.shouldOptimizeForNetworkUse = false

        final class ExportBox: @unchecked Sendable {
            let session: AVAssetExportSession
            init(_ session: AVAssetExportSession) { self.session = session }
        }

        let box = ExportBox(exportSession)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously {
                continuation.resume()
            }
        }

        guard exportSession.status == .completed else {
            throw BackbufferError.trimFailed(
                exportSession.error?.localizedDescription ?? "Export session failed with status \(exportSession.status.rawValue)."
            )
        }

        let outputSize = try ClipCompressor.fileSize(of: tempURL)
        guard outputSize > 0 else {
            throw BackbufferError.trimFailed("Export session produced an empty output file.")
        }

        try ClipCompressor.moveReplacingExisting(from: tempURL, to: destinationURL)
        return destinationURL
    }
}
