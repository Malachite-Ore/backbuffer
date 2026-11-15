import AppKit
import BackbufferCore
import CoreGraphics
import Foundation

struct RunningAppCandidate: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let isRunning: Bool
    let windowCount: Int

    var id: String { bundleIdentifier }
}

@MainActor
enum AppPrivacyCatalog {
    static func discoverApps(
        settings: CaptureSettings,
        includeHelpers: Bool = false
    ) -> [RunningAppCandidate] {
        let selfBundleID = Bundle.main.bundleIdentifier?.lowercased()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let explicitRuleIDs = settings.allowedAppBundleIDs.union(settings.blockedAppBundleIDs)
        let windowCounts = windowCountsByPID()

        struct AggregateEntry {
            let bundleIdentifier: String
            var displayName: String
            var windowCount: Int
            var hasRegularPolicy: Bool
        }

        var runningByBundleID: [String: AggregateEntry] = [:]

        for app in NSWorkspace.shared.runningApplications {
            if app.processIdentifier == selfPID { continue }
            guard !app.isTerminated,
                  let rawBundleID = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawBundleID.isEmpty else {
                continue
            }
            if let selfBundleID, rawBundleID.lowercased() == selfBundleID {
                continue
            }

            let isRegular = (app.activationPolicy == .regular)
            let isExplicitlyConfigured = explicitRuleIDs.contains(rawBundleID)
            if !includeHelpers && !isRegular && !isExplicitlyConfigured {
                continue
            }

            let pidWindows = windowCounts[app.processIdentifier] ?? 0
            let fallbackName = app.bundleURL?
                .deletingPathExtension()
                .lastPathComponent ?? rawBundleID
            let localized = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = (localized?.isEmpty == false) ? localized! : fallbackName

            if var existing = runningByBundleID[rawBundleID] {
                existing.windowCount += pidWindows
                if isRegular && !existing.hasRegularPolicy {
                    existing.displayName = resolvedName
                    existing.hasRegularPolicy = true
                }
                runningByBundleID[rawBundleID] = existing
            } else {
                runningByBundleID[rawBundleID] = AggregateEntry(
                    bundleIdentifier: rawBundleID,
                    displayName: resolvedName,
                    windowCount: pidWindows,
                    hasRegularPolicy: isRegular
                )
            }
        }

        var results: [RunningAppCandidate] = runningByBundleID.values.map { entry in
            RunningAppCandidate(
                bundleIdentifier: entry.bundleIdentifier,
                displayName: entry.displayName,
                isRunning: true,
                windowCount: entry.windowCount
            )
        }
        var seenBundleIDs = Set(runningByBundleID.keys)

        for remembered in settings.rememberedApps {
            let bundleID = remembered.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { continue }
            if let selfBundleID, bundleID.lowercased() == selfBundleID { continue }
            guard seenBundleIDs.insert(bundleID).inserted else { continue }

            let name = remembered.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(
                RunningAppCandidate(
                    bundleIdentifier: bundleID,
                    displayName: name.isEmpty ? bundleID : name,
                    isRunning: false,
                    windowCount: 0
                )
            )
        }

        for bundleID in explicitRuleIDs {
            let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let selfBundleID, trimmed.lowercased() == selfBundleID { continue }
            guard seenBundleIDs.insert(trimmed).inserted else { continue }

            results.append(
                RunningAppCandidate(
                    bundleIdentifier: trimmed,
                    displayName: resolveOfflineDisplayName(for: trimmed),
                    isRunning: false,
                    windowCount: 0
                )
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning {
                return lhs.isRunning
            }
            let lhsHasWindows = lhs.windowCount > 0
            let rhsHasWindows = rhs.windowCount > 0
            if lhsHasWindows != rhsHasWindows {
                return lhsHasWindows
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func filterApps(
        _ candidates: [RunningAppCandidate],
        searchQuery: String,
        onlyAllowed: Bool,
        onlyRunning: Bool,
        settings: CaptureSettings
    ) -> [RunningAppCandidate] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        return candidates.filter { candidate in
            if onlyRunning && !candidate.isRunning {
                return false
            }
            if onlyAllowed && !settings.isApplicationAllowed(bundleIdentifier: candidate.bundleIdentifier) {
                return false
            }
            if !trimmedQuery.isEmpty {
                let matchesName = candidate.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesBundle = candidate.bundleIdentifier.localizedCaseInsensitiveContains(trimmedQuery)
                if !matchesName && !matchesBundle {
                    return false
                }
            }
            return true
        }
    }

    static func appIcon(for bundleIdentifier: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && $0.icon != nil
        }) {
            return running.icon
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return nil
    }

    private static func windowCountsByPID() -> [pid_t: Int] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        let pidKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let boundsKey = kCGWindowBounds as String

        var counts: [pid_t: Int] = [:]
        for info in windowList {
            guard let pidNumber = info[pidKey] as? NSNumber else { continue }
            let layer = (info[layerKey] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }

            if let rawBounds = info[boundsKey] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
               bounds.width < 20 || bounds.height < 20 {
                continue
            }

            counts[pid_t(pidNumber.int32Value), default: 0] += 1
        }
        return counts
    }

    private static func resolveOfflineDisplayName(for bundleIdentifier: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            if let bundle = Bundle(url: appURL),
               let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String),
               !display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return display
            }
            let fileName = appURL.deletingPathExtension().lastPathComponent
            if !fileName.isEmpty {
                return fileName
            }
        }
        return bundleIdentifier
    }
}
