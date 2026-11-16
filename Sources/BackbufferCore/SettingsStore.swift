import CoreGraphics
import Foundation

public final class SettingsStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "io.malachiteore.backbuffer.settings"
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    private var lastAuthorizedExecutableHashKey: String {
        "\(storageKey).lastAuthorizedExecHash"
    }

    private var lastAutoResetExecutableHashKey: String {
        "\(storageKey).lastAutoResetExecHash"
    }

    public var hasPersistedSettings: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.data(forKey: storageKey) != nil
    }

    public func lastAuthorizedExecutableHash() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.string(forKey: lastAuthorizedExecutableHashKey)
    }

    public func setLastAuthorizedExecutableHash(_ hash: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let hash, !hash.isEmpty {
            userDefaults.set(hash, forKey: lastAuthorizedExecutableHashKey)
        } else {
            userDefaults.removeObject(forKey: lastAuthorizedExecutableHashKey)
        }
    }

    public func lastAutoResetExecutableHash() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.string(forKey: lastAutoResetExecutableHashKey)
    }

    public func setLastAutoResetExecutableHash(_ hash: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let hash, !hash.isEmpty {
            userDefaults.set(hash, forKey: lastAutoResetExecutableHashKey)
        } else {
            userDefaults.removeObject(forKey: lastAutoResetExecutableHashKey)
        }
    }

    public func load() -> CaptureSettings {
        lock.lock()
        defer { lock.unlock() }
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? decoder.decode(CaptureSettings.self, from: data) else {
            return Self.normalized(.default)
        }
        return Self.normalized(decoded)
    }

    public func save(_ settings: CaptureSettings) {
        let normalizedSettings = Self.normalized(settings)
        lock.lock()
        defer { lock.unlock() }
        if let data = try? encoder.encode(normalizedSettings) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private static func normalized(_ settings: CaptureSettings) -> CaptureSettings {
        var copy = settings
        copy.microphoneGain = copy.clampedMicrophoneGain()
        copy.allowedAppBundleIDs = Set(
            copy.allowedAppBundleIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        copy.blockedAppBundleIDs = Set(
            copy.blockedAppBundleIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )

        var deduped: [RememberedAppInfo] = []
        var indexByBundleID: [String: Int] = [:]
        for item in copy.rememberedApps {
            let cleanID = item.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty else { continue }
            let trimmedName = item.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanItem = RememberedAppInfo(
                bundleIdentifier: cleanID,
                displayName: trimmedName.isEmpty ? cleanID : trimmedName
            )
            if let existingIndex = indexByBundleID[cleanID] {
                deduped[existingIndex] = cleanItem
            } else {
                indexByBundleID[cleanID] = deduped.count
                deduped.append(cleanItem)
            }
        }
        copy.rememberedApps = deduped
        return copy
    }

    @discardableResult
    public func reset() -> CaptureSettings {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: storageKey)
        return .default
    }

    /// Computes target hardware video & AAC audio bitrates from Spec Section 5.3.
    /// Applies FPS scaling (0.72 / 0.82 / 1.0) and 1.5x scaling when Native exceeds 2560x1440 for Balanced/High/Post Master.
    public static func bitratePair(
        for quality: QualityPreset,
        resolutionCap: ResolutionCap,
        fps: CaptureFPS,
        targetPixelSize: CGSize? = nil
    ) -> (videoBps: Int, audioBps: Int) {
        let baseVideoBps: Int
        let audioBps: Int

        switch quality {
        case .compact:
            audioBps = 128_000
            switch resolutionCap {
            case .p720: baseVideoBps = 2_000_000
            case .p1080: baseVideoBps = 3_000_000
            case .native: baseVideoBps = 4_500_000
            }
        case .balanced:
            audioBps = 160_000
            switch resolutionCap {
            case .p720: baseVideoBps = 3_000_000
            case .p1080: baseVideoBps = 4_500_000
            case .native: baseVideoBps = 7_000_000
            }
        case .high:
            audioBps = 160_000
            switch resolutionCap {
            case .p720: baseVideoBps = 6_500_000
            case .p1080: baseVideoBps = 10_000_000
            case .native: baseVideoBps = 15_000_000
            }
        case .postMaster:
            audioBps = 192_000
            switch resolutionCap {
            case .p720: baseVideoBps = 12_000_000
            case .p1080: baseVideoBps = 20_000_000
            case .native: baseVideoBps = 30_000_000
            }
        }

        let isHighResNative: Bool
        if resolutionCap == .native,
           let size = targetPixelSize,
           size.width > 0,
           size.height > 0,
           quality != .compact {
            isHighResNative = (size.width * size.height) > (2560.0 * 1440.0)
        } else {
            isHighResNative = false
        }

        let nativeScale = isHighResNative ? 1.5 : 1.0
        let scaledVideoBps = Int((Double(baseVideoBps) * fps.bitrateScaleFactor * nativeScale).rounded())
        return (videoBps: scaledVideoBps, audioBps: audioBps)
    }

    public static func estimate(
        for settings: CaptureSettings,
        targetPixelSize: CGSize? = nil
    ) -> CaptureSizeEstimate {
        let pair = bitratePair(
            for: settings.quality,
            resolutionCap: settings.resolutionCap,
            fps: settings.fps,
            targetPixelSize: targetPixelSize
        )

        let extraAudioStemBps: Int = (settings.recordMicrophone && settings.separateAudioTracksInMaster)
            ? (pair.audioBps * 2)
            : 0
        let totalBps = Double(pair.videoBps + pair.audioBps)
        let masterBps = Double(pair.videoBps + pair.audioBps + extraAudioStemBps)
        let duration = settings.bufferDuration.seconds
        let estimatedMasterBytes = (masterBps * duration) / 8.0
        let estimatedMasterMB = estimatedMasterBytes / 1_000_000.0

        let videoAudioRAMMB = ((totalBps * (duration + 2.0)) / 8.0) / 1_000_000.0
        // 48 kHz * 2 ch * 16-bit LPCM = 192,000 bytes/s (~11.52 MB/min) for unencoded mic ring buffer
        let micPCMBytesPerSecond = 48_000.0 * 2.0 * 2.0
        let micRAMOverheadMB = settings.recordMicrophone
            ? ((micPCMBytesPerSecond * (duration + 2.0)) / 1_000_000.0)
            : 0.0
        let estimatedRAMBufferMB = videoAudioRAMMB + micRAMOverheadMB

        let willAutoCompress: Bool
        if let capBytes = settings.shareCap.capBytes {
            willAutoCompress = estimatedMasterBytes > (Double(capBytes) * 0.96)
        } else {
            willAutoCompress = false
        }

        return CaptureSizeEstimate(
            videoBitrateBps: pair.videoBps,
            audioBitrateBps: pair.audioBps,
            estimatedMasterMB: estimatedMasterMB,
            estimatedRAMBufferMB: estimatedRAMBufferMB,
            willAutoCompress: willAutoCompress
        )
    }

    public static func estimateClipMB(
        videoBitrateBps: Int,
        audioBitrateBps: Int,
        durationSeconds: Double
    ) -> Double {
        guard durationSeconds > 0 else { return 0 }
        let totalBps = Double(max(0, videoBitrateBps) + max(0, audioBitrateBps))
        return ((totalBps * durationSeconds) / 8.0) / 1_000_000.0
    }
}
