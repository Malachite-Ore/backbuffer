import AVFoundation
import CoreMedia
import Foundation

// MARK: - Capture Configuration Enums

public enum CaptureFPS: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    public var id: Int { rawValue }

    public var displayName: String {
        "\(rawValue) FPS"
    }

    public var frameIntervalSeconds: Double {
        1.0 / Double(rawValue)
    }

    public var bitrateScaleFactor: Double {
        switch self {
        case .fps24: return 0.72
        case .fps30: return 0.82
        case .fps60: return 1.0
        }
    }
}

public enum ResolutionCap: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case p720
    case p1080
    case native

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .native: return "Native"
        }
    }

    public var maxHeight: Int? {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        case .native: return nil
        }
    }
}

public enum QualityPreset: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case compact
    case balanced
    case high
    case postMaster

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .high: return "High"
        case .postMaster: return "Post Master"
        }
    }
}

public enum VideoCodecChoice: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case hevc
    case h264

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        }
    }

    public var pickerLabel: String {
        switch self {
        case .hevc: return "HEVC (Smaller)"
        case .h264: return "H.264 (Compatible)"
        }
    }

    public var cmVideoCodecType: CMVideoCodecType {
        switch self {
        case .hevc: return kCMVideoCodecType_HEVC
        case .h264: return kCMVideoCodecType_H264
        }
    }

    public var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .hevc: return .hevc
        case .h264: return .h264
        }
    }
}

public enum BufferDurationOption: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case s15 = 15
    case s30 = 30
    case s60 = 60
    case s120 = 120

    public var id: Int { rawValue }

    public var seconds: Double {
        Double(rawValue)
    }

    public var displayName: String {
        "\(rawValue)s"
    }
}

public enum ShareCapOption: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case off = 0
    case mb10 = 10
    case mb20 = 20
    case mb50 = 50

    public var id: Int { rawValue }

    public var capBytes: Int64? {
        guard self != .off else { return nil }
        return Int64(rawValue) * 1_000_000
    }

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .mb10: return "10 MB"
        case .mb20: return "20 MB (Discord Free)"
        case .mb50: return "50 MB"
        }
    }

    public var shortLabel: String {
        switch self {
        case .off: return "Off"
        case .mb10: return "10 MB"
        case .mb20: return "20 MB"
        case .mb50: return "50 MB"
        }
    }
}

// MARK: - Settings & Estimates

public struct CaptureSettings: Codable, Equatable, Hashable, Sendable {
    public var fps: CaptureFPS
    public var resolutionCap: ResolutionCap
    public var quality: QualityPreset
    public var codec: VideoCodecChoice
    public var bufferDuration: BufferDurationOption
    public var shareCap: ShareCapOption
    public var outputRootPath: String
    public var saveHotKey: HotKeyShortcut

    public static var defaultOutputRootPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent("Backbuffer", isDirectory: true)
            .path
    }

    public static var `default`: CaptureSettings {
        CaptureSettings()
    }

    public init(
        fps: CaptureFPS = .fps60,
        resolutionCap: ResolutionCap = .p1080,
        quality: QualityPreset = .balanced,
        codec: VideoCodecChoice = .hevc,
        bufferDuration: BufferDurationOption = .s30,
        shareCap: ShareCapOption = .mb20,
        outputRootPath: String = CaptureSettings.defaultOutputRootPath,
        saveHotKey: HotKeyShortcut = .defaultSaveClip
    ) {
        self.fps = fps
        self.resolutionCap = resolutionCap
        self.quality = quality
        self.codec = codec
        self.bufferDuration = bufferDuration
        self.shareCap = shareCap
        self.outputRootPath = outputRootPath
        self.saveHotKey = saveHotKey
    }

    public var outputRootURL: URL {
        let expanded = (outputRootPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    public var mastersDirectoryURL: URL {
        outputRootURL.appendingPathComponent("Masters", isDirectory: true)
    }

    public var sharedDirectoryURL: URL {
        outputRootURL.appendingPathComponent("Shared", isDirectory: true)
    }
}

public struct CaptureSizeEstimate: Equatable, Hashable, Sendable {
    public let videoBitrateBps: Int
    public let audioBitrateBps: Int
    public let estimatedMasterMB: Double
    public let estimatedRAMBufferMB: Double
    public let willAutoCompress: Bool

    public init(
        videoBitrateBps: Int,
        audioBitrateBps: Int,
        estimatedMasterMB: Double,
        estimatedRAMBufferMB: Double,
        willAutoCompress: Bool
    ) {
        self.videoBitrateBps = videoBitrateBps
        self.audioBitrateBps = audioBitrateBps
        self.estimatedMasterMB = estimatedMasterMB
        self.estimatedRAMBufferMB = estimatedRAMBufferMB
        self.willAutoCompress = willAutoCompress
    }
}

// MARK: - Media Packets & Multi-Track Seam

public struct BufferedVideoPacket: @unchecked Sendable {
    public let pts: CMTime
    public let duration: CMTime
    public let isKeyframe: Bool
    public let sampleBuffer: CMSampleBuffer
    public let byteCount: Int

    public init(
        pts: CMTime,
        isKeyframe: Bool,
        sampleBuffer: CMSampleBuffer,
        duration: CMTime = .invalid
    ) {
        self.pts = pts
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.sampleBuffer = sampleBuffer
        self.byteCount = CMSampleBufferGetTotalSampleSize(sampleBuffer)
    }
}

public struct BufferedAudioChunk: @unchecked Sendable {
    public let pts: CMTime
    public let duration: CMTime
    public let pcmData: Data
    public let asbd: AudioStreamBasicDescription
    public let frameCount: UInt32

    public init(
        pts: CMTime,
        duration: CMTime,
        pcmData: Data,
        asbd: AudioStreamBasicDescription,
        frameCount: UInt32
    ) {
        self.pts = pts
        self.duration = duration
        self.pcmData = pcmData
        self.asbd = asbd
        self.frameCount = frameCount
    }

    public var endPTS: CMTime {
        CMTimeAdd(pts, duration)
    }
}

public struct AudioTrackInput: Sendable {
    public let trackID: String
    public let chunks: [BufferedAudioChunk]
    public let aacBitrateBps: Int

    public init(
        trackID: String = "system",
        chunks: [BufferedAudioChunk],
        aacBitrateBps: Int = 160_000
    ) {
        self.trackID = trackID
        self.chunks = chunks
        self.aacBitrateBps = aacBitrateBps
    }
}

// MARK: - Library, Sharing & Trimming

public enum ShareStatus: Equatable, Hashable, Sendable {
    case fitsDirectly
    case compressing
    case compressed(bytes: Int64)
    case overNewCap(bytes: Int64)
    case disabled
}

public struct ClipPairRecord: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let masterURL: URL
    public let shareURL: URL?
    public let createdAt: Date
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
    public let fps: Double
    public let codecName: String
    public let masterBytes: Int64
    public let shareStatus: ShareStatus
    public let displayTitle: String

    public init(
        id: String? = nil,
        masterURL: URL,
        shareURL: URL? = nil,
        createdAt: Date,
        durationSeconds: Double,
        width: Int,
        height: Int,
        fps: Double,
        codecName: String,
        masterBytes: Int64,
        shareStatus: ShareStatus,
        displayTitle: String? = nil
    ) {
        self.id = id ?? masterURL.path
        self.masterURL = masterURL
        self.shareURL = shareURL
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.fps = fps
        self.codecName = codecName
        self.masterBytes = masterBytes
        self.shareStatus = shareStatus
        self.displayTitle = displayTitle ?? masterURL.deletingPathExtension().lastPathComponent
    }

    public var stem: String {
        masterURL.deletingPathExtension().lastPathComponent
    }

    public var resolutionLabel: String {
        "\(width)×\(height)"
    }

    public var shareBytes: Int64? {
        switch shareStatus {
        case .compressed(let bytes), .overNewCap(let bytes):
            return bytes
        case .fitsDirectly:
            return masterBytes
        case .compressing, .disabled:
            return nil
        }
    }
}

public struct TrimRange: Equatable, Hashable, Sendable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public var durationSeconds: Double {
        max(0, endSeconds - startSeconds)
    }

    public var cmTimeRange: CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            end: CMTime(seconds: endSeconds, preferredTimescale: 600)
        )
    }

    public func isValid(sourceDuration: Double) -> Bool {
        startSeconds >= 0 && endSeconds > startSeconds && endSeconds <= sourceDuration
    }

    public var fileTag: String {
        "\(Self.formatSecondToken(startSeconds))s-\(Self.formatSecondToken(endSeconds))s"
    }

    private static func formatSecondToken(_ value: Double) -> String {
        let clamped = max(0, value)
        let rounded = clamped.rounded()
        if abs(clamped - rounded) < 0.05 {
            return String(format: "%02d", Int(rounded))
        }
        return String(format: "%.1f", clamped)
    }
}

// MARK: - Errors

public enum BackbufferError: LocalizedError, Equatable, Sendable {
    case emptyBuffer
    case encoderSetupFailed(String)
    case encodeFailed(String)
    case pixelTransferFailed(String)
    case muxerFailed(String)
    case trimRangeInvalid
    case compressionFailed(String)
    case trimFailed(String)
    case missingAssetTrack(String)
    case libraryIOFailed(String)
    case screenRecordingPermissionDenied
    case noCaptureTargetAvailable
    case captureStartFailed(String)
    case hotKeyRegistrationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .emptyBuffer:
            return "The replay ring buffer is empty; wait a moment for frames to buffer before saving."
        case .encoderSetupFailed(let detail):
            return "Failed to initialize hardware video encoder: \(detail)"
        case .encodeFailed(let detail):
            return "Video frame encoding failed: \(detail)"
        case .pixelTransferFailed(let detail):
            return "GPU pixel transfer failed: \(detail)"
        case .muxerFailed(let detail):
            return "Failed to write MP4 clip container: \(detail)"
        case .trimRangeInvalid:
            return "Trim range must satisfy 0 <= start < end <= clip duration."
        case .compressionFailed(let detail):
            return "Target-size compression failed: \(detail)"
        case .trimFailed(let detail):
            return "Clip trimming failed: \(detail)"
        case .missingAssetTrack(let detail):
            return "Required media track was missing from source clip: \(detail)"
        case .libraryIOFailed(let detail):
            return "Clip library file operation failed: \(detail)"
        case .screenRecordingPermissionDenied:
            return "Screen Recording permission is required to capture displays or game windows."
        case .noCaptureTargetAvailable:
            return "No active display or window is available to capture."
        case .captureStartFailed(let detail):
            return "Failed to start screen capture stream: \(detail)"
        case .hotKeyRegistrationFailed(let status):
            return "Could not register global save hotkey (OSStatus \(status))."
        }
    }
}
