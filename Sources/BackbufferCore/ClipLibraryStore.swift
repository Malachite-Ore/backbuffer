import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

public final class ClipLibraryStore: @unchecked Sendable {
    public let rootDirectory: URL
    public let mastersDirectory: URL
    public let sharedDirectory: URL

    private let lock = NSLock()
    private var reservedMasterFilenames: Set<String> = []
    private var thumbnailCache: [String: CGImage] = [:]
    private var thumbnailCacheOrder: [String] = []
    private let maxCachedThumbnails = 256

    private static let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        self.mastersDirectory = rootDirectory.appendingPathComponent("Masters", isDirectory: true)
        self.sharedDirectory = rootDirectory.appendingPathComponent("Shared", isDirectory: true)
        try ensureDirectoriesExist()
    }

    public convenience init(settings: CaptureSettings) throws {
        try self.init(rootDirectory: settings.outputRootURL)
    }

    public func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: mastersDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        } catch {
            throw BackbufferError.libraryIOFailed("Failed to create Masters/Shared directories: \(error.localizedDescription)")
        }
    }

    // MARK: - Deterministic & Collision-Safe URL Naming

    public func nextMasterURL(for date: Date = Date()) -> URL {
        try? ensureDirectoriesExist()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let baseStem = "Backbuffer_\(formatter.string(from: date))"
        return uniqueMasterURL(baseStem: baseStem)
    }

    public func nextTrimMasterURL(from masterURL: URL, range: TrimRange) -> URL {
        try? ensureDirectoriesExist()
        let stem = masterURL.deletingPathExtension().lastPathComponent
        let baseStem = "\(stem)_trim_\(range.fileTag)"
        return uniqueMasterURL(baseStem: baseStem)
    }

    public func shareURL(for masterURL: URL, trimRange: TrimRange? = nil) -> URL {
        let stem = masterURL.deletingPathExtension().lastPathComponent
        if let trimRange {
            return sharedDirectory.appendingPathComponent("\(stem)_trim_\(trimRange.fileTag)_share.mp4")
        }
        return sharedDirectory.appendingPathComponent("\(stem)_share.mp4")
    }

    private func uniqueMasterURL(baseStem: String) -> URL {
        lock.withLock {
            let fm = FileManager.default
            var suffix = 1
            while true {
                let filename = suffix == 1 ? "\(baseStem).mp4" : "\(baseStem)-\(suffix).mp4"
                let candidate = mastersDirectory.appendingPathComponent(filename)
                if !reservedMasterFilenames.contains(filename) && !fm.fileExists(atPath: candidate.path) {
                    reservedMasterFilenames.insert(filename)
                    return candidate
                }
                suffix += 1
            }
        }
    }

    // MARK: - Library Scanning & Lazy Share Status (Q7 = A)

    public func loadClips(activeCap: ShareCapOption) async throws -> [ClipPairRecord] {
        try await loadClips(maxCapBytes: activeCap.capBytes)
    }

    public func loadClips(maxCapBytes: Int64?) async throws -> [ClipPairRecord] {
        try ensureDirectoriesExist()

        let fm = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]

        let masterCandidates: [URL]
        do {
            masterCandidates = try fm.contentsOfDirectory(
                at: mastersDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw BackbufferError.libraryIOFailed("Failed to scan Masters directory: \(error.localizedDescription)")
        }

        let videoURLs = masterCandidates.filter { url in
            Self.supportedVideoExtensions.contains(url.pathExtension.lowercased())
        }

        var records: [ClipPairRecord] = []
        records.reserveCapacity(videoURLs.count)

        for masterURL in videoURLs {
            try Task.checkCancellation()

            let values = try? masterURL.resourceValues(forKeys: resourceKeys)
            if values?.isRegularFile == false {
                continue
            }

            let masterBytes = Int64(values?.fileSize ?? Int((try? ClipCompressor.fileSize(of: masterURL)) ?? 0))
            let createdAt = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast

            let companionShareURL = shareURL(for: masterURL)
            let shareExists = fm.fileExists(atPath: companionShareURL.path)
            let shareBytes: Int64? = shareExists ? (try? ClipCompressor.fileSize(of: companionShareURL)) : nil

            let shareStatus = Self.evaluateShareStatus(
                masterBytes: masterBytes,
                shareBytes: shareBytes,
                maxCapBytes: maxCapBytes
            )

            let metadata = await Self.inspectMediaMetadata(for: masterURL)
            let record = ClipPairRecord(
                masterURL: masterURL,
                shareURL: shareExists ? companionShareURL : nil,
                createdAt: createdAt,
                durationSeconds: metadata.durationSeconds,
                width: metadata.width,
                height: metadata.height,
                fps: metadata.fps,
                codecName: metadata.codecName,
                masterBytes: masterBytes,
                shareStatus: shareStatus
            )
            records.append(record)
        }

        return records.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.stem > rhs.stem
        }
    }

    public static func evaluateShareStatus(
        masterBytes: Int64,
        shareBytes: Int64?,
        maxCapBytes: Int64?
    ) -> ShareStatus {
        guard let cap = maxCapBytes, cap > 0 else {
            if let shareBytes {
                return .compressed(bytes: shareBytes)
            }
            return .disabled
        }

        let directThreshold = Int64(Double(cap) * 0.96)
        if masterBytes <= directThreshold {
            return .fitsDirectly
        }

        if let shareBytes {
            return shareBytes <= cap ? .compressed(bytes: shareBytes) : .overNewCap(bytes: shareBytes)
        }

        return .overNewCap(bytes: masterBytes)
    }

    @discardableResult
    public func resolveShareClip(
        for record: ClipPairRecord,
        activeCap: ShareCapOption,
        codec: VideoCodecChoice
    ) async throws -> URL {
        try await resolveShareClip(for: record, maxCapBytes: activeCap.capBytes, codec: codec)
    }

    @discardableResult
    public func resolveShareClip(
        for record: ClipPairRecord,
        maxCapBytes: Int64?,
        codec: VideoCodecChoice
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: record.masterURL.path) else {
            throw BackbufferError.libraryIOFailed("Original master clip not found at \(record.masterURL.path)")
        }

        guard let capBytes = maxCapBytes, capBytes > 0 else {
            return record.masterURL
        }

        let masterBytes = try ClipCompressor.fileSize(of: record.masterURL)
        let directThreshold = Int64(Double(capBytes) * 0.96)
        if masterBytes <= directThreshold {
            return record.masterURL
        }

        let destinationShareURL = shareURL(for: record.masterURL)
        if fm.fileExists(atPath: destinationShareURL.path) {
            let existingShareBytes = try ClipCompressor.fileSize(of: destinationShareURL)
            if existingShareBytes > 0 && existingShareBytes <= capBytes {
                return destinationShareURL
            }
        }

        return try await ClipCompressor.compressIfNeeded(
            masterURL: record.masterURL,
            outputURL: destinationShareURL,
            capBytes: capBytes,
            codec: codec
        )
    }

    // MARK: - Deletion (Pair or Share Only)

    public func deleteClipPair(_ record: ClipPairRecord) throws {
        try deleteClip(record, shareOnly: false)
    }

    public func deleteShareCopy(for record: ClipPairRecord) throws {
        try deleteClip(record, shareOnly: true)
    }

    public func deleteClip(_ record: ClipPairRecord, shareOnly: Bool = false) throws {
        let fm = FileManager.default
        var shareTargets: [URL] = [shareURL(for: record.masterURL)]
        if let explicitShare = record.shareURL, explicitShare.standardizedFileURL != shareTargets[0].standardizedFileURL {
            shareTargets.append(explicitShare)
        }

        do {
            for target in shareTargets where fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
                invalidateThumbnailCache(for: target)
            }

            if !shareOnly {
                if fm.fileExists(atPath: record.masterURL.path) {
                    try fm.removeItem(at: record.masterURL)
                }
                invalidateThumbnailCache(for: record.masterURL)

                lock.withLock {
                    _ = reservedMasterFilenames.remove(record.masterURL.lastPathComponent)
                }
            }
        } catch {
            throw BackbufferError.libraryIOFailed("Failed to delete clip file: \(error.localizedDescription)")
        }
    }

    // MARK: - Cached Thumbnails (AVAssetImageGenerator)

    public func thumbnail(
        for assetURL: URL,
        atSeconds: Double = 0.5,
        maximumSize: CGSize = CGSize(width: 480, height: 270)
    ) async throws -> CGImage {
        try await generateCachedThumbnail(
            for: assetURL,
            atSeconds: atSeconds,
            maximumSize: maximumSize,
            toleranceSeconds: 0.25
        )
    }

    public func filmstripThumbnails(
        for assetURL: URL,
        count: Int = 8,
        maximumSize: CGSize = CGSize(width: 240, height: 135)
    ) async throws -> [CGImage] {
        guard count > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw BackbufferError.libraryIOFailed("Clip not found for filmstrip at \(assetURL.path)")
        }

        let asset = AVURLAsset(url: assetURL)
        let durationCM = try await asset.load(.duration)
        let duration = max(0, CMTimeGetSeconds(durationCM))

        var images: [CGImage] = []
        images.reserveCapacity(count)

        for index in 0..<count {
            try Task.checkCancellation()
            let fraction: Double
            if count == 1 {
                fraction = 0.5
            } else {
                fraction = Double(index) / Double(count - 1)
            }
            let targetTime = duration > 0.05
                ? min(max(0, duration * fraction), max(0, duration - 0.02))
                : 0.0

            let image = try await generateCachedThumbnail(
                for: assetURL,
                atSeconds: targetTime,
                maximumSize: maximumSize,
                toleranceSeconds: 0.05
            )
            images.append(image)
        }

        return images
    }

    public func invalidateThumbnailCache(for assetURL: URL? = nil) {
        lock.withLock {
            guard let assetURL else {
                thumbnailCache.removeAll()
                thumbnailCacheOrder.removeAll()
                return
            }

            let prefix = "\(assetURL.standardizedFileURL.path)|"
            let matchingKeys = thumbnailCache.keys.filter { $0.hasPrefix(prefix) }
            for key in matchingKeys {
                thumbnailCache.removeValue(forKey: key)
            }
            thumbnailCacheOrder.removeAll { $0.hasPrefix(prefix) }
        }
    }

    private func generateCachedThumbnail(
        for assetURL: URL,
        atSeconds: Double,
        maximumSize: CGSize,
        toleranceSeconds: Double
    ) async throws -> CGImage {
        guard FileManager.default.fileExists(atPath: assetURL.path) else {
            throw BackbufferError.libraryIOFailed("Clip not found for thumbnail at \(assetURL.path)")
        }

        let modStamp = ((try? assetURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970) ?? 0
        let bucketedSeconds = Int((max(0, atSeconds) * 100.0).rounded())
        let cacheKey = "\(assetURL.standardizedFileURL.path)|\(Int(modStamp))|\(bucketedSeconds)|\(Int(maximumSize.width))x\(Int(maximumSize.height))"

        if let cached = lock.withLock({ thumbnailCache[cacheKey] }) {
            return cached
        }

        let asset = AVURLAsset(url: assetURL)
        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)
        let clampedSeconds: Double
        if duration.isFinite, duration > 0.05 {
            clampedSeconds = min(max(0, atSeconds), max(0, duration - 0.02))
        } else {
            clampedSeconds = 0
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        let tolerance = CMTime(seconds: max(0, toleranceSeconds), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let requestedTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: requestedTime)

        lock.withLock {
            if thumbnailCache[cacheKey] == nil {
                thumbnailCache[cacheKey] = cgImage
                thumbnailCacheOrder.append(cacheKey)
                if thumbnailCacheOrder.count > maxCachedThumbnails, let oldest = thumbnailCacheOrder.first {
                    thumbnailCacheOrder.removeFirst()
                    thumbnailCache.removeValue(forKey: oldest)
                }
            }
        }

        return cgImage
    }

    // MARK: - Media Metadata Inspection

    private static func inspectMediaMetadata(
        for url: URL
    ) async -> (durationSeconds: Double, width: Int, height: Int, fps: Double, codecName: String) {
        let asset = AVURLAsset(url: url)
        let durationCM = (try? await asset.load(.duration)) ?? .zero
        let rawDuration = CMTimeGetSeconds(durationCM)
        let durationSeconds = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 0

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let videoTrack = videoTracks.first else {
            return (durationSeconds: durationSeconds, width: 0, height: 0, fps: 0, codecName: "MP4")
        }

        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
        let visualSize = naturalSize.applying(preferredTransform)
        let width = max(0, Int(abs(visualSize.width).rounded()))
        let height = max(0, Int(abs(visualSize.height).rounded()))

        let nominalFPS = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
        let fps = nominalFPS.isFinite ? Double(nominalFPS) : 0

        let formatDescriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
        let codecName = formatDescriptions.first.map(codecDisplayName(for:)) ?? "Unknown"

        return (
            durationSeconds: durationSeconds,
            width: width,
            height: height,
            fps: fps,
            codecName: codecName
        )
    }

    private static func codecDisplayName(for formatDescription: CMFormatDescription) -> String {
        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let hev1FourCC: FourCharCode = 0x68657631 // 'hev1'
        switch subType {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha, hev1FourCC:
            return "HEVC"
        case kCMVideoCodecType_H264:
            return "H.264"
        default:
            let bytes: [UInt8] = [
                UInt8((subType >> 24) & 0xFF),
                UInt8((subType >> 16) & 0xFF),
                UInt8((subType >> 8) & 0xFF),
                UInt8(subType & 0xFF)
            ]
            let chars = bytes.map { byte -> Character in
                (32...126).contains(byte) ? Character(UnicodeScalar(byte)) : "?"
            }
            let rendered = String(chars).trimmingCharacters(in: .whitespaces)
            return rendered.isEmpty ? "Unknown" : rendered
        }
    }
}
