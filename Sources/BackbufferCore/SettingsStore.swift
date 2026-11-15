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

    public func load() -> CaptureSettings {
        lock.lock()
        defer { lock.unlock() }
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? decoder.decode(CaptureSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    public func save(_ settings: CaptureSettings) {
        lock.lock()
        defer { lock.unlock() }
        if let data = try? encoder.encode(settings) {
            userDefaults.set(data, forKey: storageKey)
        }
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

        let totalBps = Double(pair.videoBps + pair.audioBps)
        let duration = settings.bufferDuration.seconds
        let estimatedMasterBytes = (totalBps * duration) / 8.0
        let estimatedMasterMB = estimatedMasterBytes / 1_000_000.0
        let estimatedRAMBufferMB = ((totalBps * (duration + 2.0)) / 8.0) / 1_000_000.0

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
