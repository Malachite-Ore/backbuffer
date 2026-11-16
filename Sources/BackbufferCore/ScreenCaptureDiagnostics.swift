import CryptoKit
import Foundation

public enum AppInstallLocationIssue: Equatable, Sendable {
    case none
    case runningFromDiskImage(bundlePath: String)
    case appTranslocated(bundlePath: String)
    case shadowedByApplicationsCopy(runningPath: String, applicationsPath: String)

    public var requiresMoveToApplications: Bool {
        switch self {
        case .none:
            return false
        case .runningFromDiskImage, .appTranslocated, .shadowedByApplicationsCopy:
            return true
        }
    }

    public var userTitle: String {
        switch self {
        case .none:
            return ""
        case .runningFromDiskImage:
            return "Running From Disk Image (DMG)"
        case .appTranslocated:
            return "App Translocation Active"
        case .shadowedByApplicationsCopy:
            return "Duplicate App Copy Outside /Applications"
        }
    }

    public var userExplanation: String {
        switch self {
        case .none:
            return ""
        case .runningFromDiskImage(let bundlePath):
            return "macOS cannot persist Screen Recording permission while running from \(bundlePath). Install Backbuffer into /Applications and relaunch."
        case .appTranslocated:
            return "macOS launched this copy inside a randomized AppTranslocation path, which prevents Screen Recording grants from persisting. Move Backbuffer into /Applications and relaunch."
        case .shadowedByApplicationsCopy(_, let applicationsPath):
            return "Another copy exists at \(applicationsPath), so macOS may apply Screen Recording permission to the /Applications copy instead of this one. Install and launch from /Applications."
        }
    }
}

public enum StalePermissionDecision: Equatable, Sendable {
    case autoResetOnce
    case skipInstallIssuePresent
    case skipMissingExecutableSignature
    case skipAlreadyAutoResetForCurrentBinary
    case skipAlreadyAuthorizedCurrentBinary
    case skipFreshInstallNoPriorHistory
}

public enum ScreenCaptureDiagnostics {
    public static let bundleIdentifier = "io.malachiteore.backbuffer"
    public static let applicationsBundlePath = "/Applications/Backbuffer.app"

    public static func classifyInstallLocation(
        bundlePath: String,
        applicationsBundleExists: Bool,
        homeDirectoryPath: String? = nil
    ) -> AppInstallLocationIssue {
        let normalizedPath = (bundlePath as NSString).standardizingPath
        guard !normalizedPath.isEmpty,
              normalizedPath.lowercased().hasSuffix(".app") else {
            return .none
        }

        if normalizedPath.hasPrefix("/Volumes/") {
            return .runningFromDiskImage(bundlePath: normalizedPath)
        }

        if normalizedPath.contains("/AppTranslocation/") {
            return .appTranslocated(bundlePath: normalizedPath)
        }

        let inSystemApplications = normalizedPath.hasPrefix("/Applications/")
        let inUserApplications: Bool
        if let homeDirectoryPath, !homeDirectoryPath.isEmpty {
            let normalizedHome = (homeDirectoryPath as NSString).standardizingPath
            let userAppsPrefix = normalizedHome == "/" ? "/Applications/" : "\(normalizedHome)/Applications/"
            inUserApplications = normalizedPath.hasPrefix(userAppsPrefix)
        } else {
            inUserApplications = false
        }

        if !inSystemApplications && !inUserApplications && applicationsBundleExists {
            return .shadowedByApplicationsCopy(
                runningPath: normalizedPath,
                applicationsPath: applicationsBundlePath
            )
        }

        return .none
    }

    public static func evaluateStaleTCCAutoReset(
        installIssue: AppInstallLocationIssue,
        currentExecutableHash: String?,
        lastAuthorizedExecutableHash: String?,
        lastAutoResetExecutableHash: String?,
        hasPriorUsageEvidence: Bool
    ) -> StalePermissionDecision {
        if installIssue != .none {
            return .skipInstallIssuePresent
        }

        guard let current = currentExecutableHash, !current.isEmpty else {
            return .skipMissingExecutableSignature
        }

        if lastAutoResetExecutableHash == current {
            return .skipAlreadyAutoResetForCurrentBinary
        }

        if lastAuthorizedExecutableHash == current {
            return .skipAlreadyAuthorizedCurrentBinary
        }

        let hasPreviousAuthorizedBinary = (lastAuthorizedExecutableHash?.isEmpty == false)
        if hasPreviousAuthorizedBinary || hasPriorUsageEvidence {
            return .autoResetOnce
        }

        return .skipFreshInstallNoPriorHistory
    }

    public static func isScreenCapturePermissionError(
        domain: String,
        code: Int,
        localizedDescription: String
    ) -> Bool {
        if domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3801 {
            return true
        }

        let lowered = localizedDescription.lowercased()
        if lowered.contains("no allowed apps")
            || lowered.contains("allowed app")
            || lowered.contains("microphone") {
            return false
        }

        return lowered.contains("declined")
            || lowered.contains("screen recording")
            || lowered.contains("tcc")
            || lowered.contains("not authorized")
            || lowered.contains("permission")
    }

    public static func computeExecutableSHA256(at url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 1_048_576), !next.isEmpty else {
                    break
                }
                chunk = next
            } catch {
                return nil
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
