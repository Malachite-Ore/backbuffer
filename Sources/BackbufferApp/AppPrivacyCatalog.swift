import AppKit
import BackbufferCore
import CoreGraphics
import Darwin
import Foundation

struct RunningAppCandidate: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String
    let isRunning: Bool
    let windowCount: Int
    let subtitle: String
    let representativePID: Int32?
    let searchKeywords: [String]

    var id: String { bundleIdentifier }

    init(
        bundleIdentifier: String,
        displayName: String,
        isRunning: Bool,
        windowCount: Int,
        subtitle: String? = nil,
        representativePID: Int32? = nil,
        searchKeywords: [String] = []
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.isRunning = isRunning
        self.windowCount = windowCount
        self.subtitle = subtitle ?? bundleIdentifier
        self.representativePID = representativePID
        self.searchKeywords = searchKeywords
    }
}

@MainActor
enum AppPrivacyCatalog {
    private static let excludedSystemTokens: Set<String> = [
        "dock",
        "windowmanager",
        "windowserver",
        "controlcenter",
        "systemuiserver",
        "spotlight",
        "notificationcenter",
        "wallpaperagent",
        "loginwindow",
        "textinputmenuagent",
        "cursoruiviewservice",
        "universalaccessd"
    ]

    private struct WindowMetadata {
        var count: Int = 0
        var titles: [String] = []
        var ownerName: String?
    }

    static func discoverApps(
        settings: CaptureSettings,
        includeHelpers: Bool = false
    ) -> [RunningAppCandidate] {
        let selfBundleID = Bundle.main.bundleIdentifier?.lowercased()
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let explicitRuleIDs = settings.allowedAppBundleIDs.union(settings.blockedAppBundleIDs)
        let windowStatsByPID = windowMetadataByPID()

        struct AggregateEntry {
            let canonicalID: String
            var rawBundleID: String?
            var rawAppName: String?
            var executableName: String?
            var executablePath: String?
            var windowCount: Int
            var windowTitles: [String]
            var representativePID: Int32?
            var hasRegularPolicy: Bool
            var hasAppIcon: Bool
        }

        var runningByCanonicalID: [String: AggregateEntry] = [:]
        var coveredMatchingIDs: Set<String> = []
        var seenPIDs: Set<pid_t> = []

        func mergeProcess(
            pid: pid_t,
            rawBundleID: String?,
            localizedName: String?,
            executableURL: URL?,
            isRegular: Bool,
            hasIcon: Bool
        ) {
            seenPIDs.insert(pid)
            if pid == selfPID { return }

            let trimmedBundle = rawBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let selfBundleID, trimmedBundle?.lowercased() == selfBundleID {
                return
            }

            let resolvedExeURL = executableURL ?? executablePath(for: pid).map(URL.init(fileURLWithPath:))
            let exePath = resolvedExeURL?.path
            let exeName = resolvedExeURL?.lastPathComponent
            let winStats = windowStatsByPID[pid]
            let pidWindows = winStats?.count ?? 0

            let trimmedLocalized = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedAppName = (trimmedLocalized?.isEmpty == false ? trimmedLocalized : nil)
                ?? winStats?.ownerName
                ?? exeName
                ?? trimmedBundle

            if isSystemUIProcess(
                bundleIdentifier: trimmedBundle,
                applicationName: resolvedAppName,
                executableName: exeName
            ) {
                return
            }

            guard let canonicalID = AppIdentityResolver.canonicalIdentifier(
                bundleIdentifier: trimmedBundle,
                applicationName: resolvedAppName,
                executableName: exeName,
                executablePath: exePath
            ) else {
                return
            }

            let matches = AppIdentityResolver.matchingIdentifiers(
                bundleIdentifier: trimmedBundle,
                applicationName: resolvedAppName,
                executableName: exeName,
                executablePath: exePath
            )
            let isExplicitlyConfigured = !explicitRuleIDs.isDisjoint(with: matches)

            if !includeHelpers && !isRegular && !isExplicitlyConfigured && pidWindows == 0 {
                return
            }

            coveredMatchingIDs.formUnion(matches)
            let incomingTitles = winStats?.titles ?? []

            if var existing = runningByCanonicalID[canonicalID] {
                existing.windowCount += pidWindows
                for title in incomingTitles where !existing.windowTitles.contains(title) {
                    existing.windowTitles.append(title)
                }
                let preferNewPID =
                    (hasIcon && !existing.hasAppIcon)
                    || (pidWindows > 0 && existing.windowCount == pidWindows)
                    || (isRegular && !existing.hasRegularPolicy)

                if preferNewPID {
                    existing.representativePID = pid
                    existing.rawBundleID = trimmedBundle ?? existing.rawBundleID
                    existing.rawAppName = resolvedAppName ?? existing.rawAppName
                    existing.executableName = exeName ?? existing.executableName
                    existing.executablePath = exePath ?? existing.executablePath
                    existing.hasRegularPolicy = existing.hasRegularPolicy || isRegular
                    existing.hasAppIcon = existing.hasAppIcon || hasIcon
                }
                runningByCanonicalID[canonicalID] = existing
            } else {
                runningByCanonicalID[canonicalID] = AggregateEntry(
                    canonicalID: canonicalID,
                    rawBundleID: trimmedBundle,
                    rawAppName: resolvedAppName,
                    executableName: exeName,
                    executablePath: exePath,
                    windowCount: pidWindows,
                    windowTitles: incomingTitles,
                    representativePID: pid,
                    hasRegularPolicy: isRegular,
                    hasAppIcon: hasIcon
                )
            }
        }

        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated else { continue }
            mergeProcess(
                pid: app.processIdentifier,
                rawBundleID: app.bundleIdentifier,
                localizedName: app.localizedName,
                executableURL: app.executableURL,
                isRegular: app.activationPolicy == .regular,
                hasIcon: app.icon != nil
            )
        }

        // Catch bare executables / JVM windows with layer-0 windows absent from NSWorkspace.
        for (pid, stats) in windowStatsByPID where stats.count > 0 && !seenPIDs.contains(pid) {
            let runningApp = NSRunningApplication(processIdentifier: pid)
            mergeProcess(
                pid: pid,
                rawBundleID: runningApp?.bundleIdentifier,
                localizedName: runningApp?.localizedName ?? stats.ownerName,
                executableURL: runningApp?.executableURL,
                isRegular: runningApp?.activationPolicy == .regular,
                hasIcon: runningApp?.icon != nil
            )
        }

        var results: [RunningAppCandidate] = runningByCanonicalID.values.map { entry in
            let presentation = AppIdentityResolver.resolvedPresentation(
                bundleIdentifier: entry.rawBundleID ?? entry.canonicalID,
                applicationName: entry.rawAppName,
                executableName: entry.executableName,
                executablePath: entry.executablePath,
                windowTitles: entry.windowTitles
            )
            return RunningAppCandidate(
                bundleIdentifier: entry.canonicalID,
                displayName: presentation.displayName,
                isRunning: true,
                windowCount: entry.windowCount,
                subtitle: presentation.subtitle,
                representativePID: entry.representativePID,
                searchKeywords: presentation.searchKeywords
            )
        }

        var seenCanonicalIDs = Set(runningByCanonicalID.keys)

        for remembered in settings.rememberedApps {
            let bundleID = remembered.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty else { continue }
            if let selfBundleID, bundleID.lowercased() == selfBundleID { continue }
            if seenCanonicalIDs.contains(bundleID) || coveredMatchingIDs.contains(bundleID) {
                continue
            }
            seenCanonicalIDs.insert(bundleID)

            let name = remembered.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let presentation = AppIdentityResolver.resolvedPresentation(
                bundleIdentifier: bundleID,
                applicationName: name.isEmpty ? nil : name,
                executableName: nil,
                executablePath: nil,
                windowTitles: []
            )
            results.append(
                RunningAppCandidate(
                    bundleIdentifier: bundleID,
                    displayName: presentation.displayName,
                    isRunning: false,
                    windowCount: 0,
                    subtitle: presentation.subtitle,
                    representativePID: nil,
                    searchKeywords: presentation.searchKeywords
                )
            )
        }

        for ruleID in explicitRuleIDs {
            let trimmed = ruleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let selfBundleID, trimmed.lowercased() == selfBundleID { continue }
            if seenCanonicalIDs.contains(trimmed) || coveredMatchingIDs.contains(trimmed) {
                continue
            }
            seenCanonicalIDs.insert(trimmed)

            let offlineName = resolveOfflineDisplayName(for: trimmed)
            let presentation = AppIdentityResolver.resolvedPresentation(
                bundleIdentifier: trimmed,
                applicationName: offlineName,
                executableName: nil,
                executablePath: nil,
                windowTitles: []
            )
            results.append(
                RunningAppCandidate(
                    bundleIdentifier: trimmed,
                    displayName: presentation.displayName,
                    isRunning: false,
                    windowCount: 0,
                    subtitle: presentation.subtitle,
                    representativePID: nil,
                    searchKeywords: presentation.searchKeywords
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
            if onlyAllowed && !settings.isApplicationAllowed(
                bundleIdentifier: candidate.bundleIdentifier,
                applicationName: candidate.displayName
            ) {
                return false
            }
            if !trimmedQuery.isEmpty {
                let matchesName = candidate.displayName.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesBundle = candidate.bundleIdentifier.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesSubtitle = candidate.subtitle.localizedCaseInsensitiveContains(trimmedQuery)
                let matchesKeywords = candidate.searchKeywords.contains {
                    $0.localizedCaseInsensitiveContains(trimmedQuery)
                }
                if !matchesName && !matchesBundle && !matchesSubtitle && !matchesKeywords {
                    return false
                }
            }
            return true
        }
    }

    static func appIcon(for candidate: RunningAppCandidate) -> NSImage? {
        if let pid = candidate.representativePID,
           let runningApp = NSRunningApplication(processIdentifier: pid),
           let icon = runningApp.icon {
            return icon
        }
        return appIcon(for: candidate.bundleIdentifier)
    }

    static func appIcon(for bundleIdentifier: String) -> NSImage? {
        let lookupID: String
        if bundleIdentifier.hasPrefix("proc:") {
            let token = String(bundleIdentifier.dropFirst("proc:".count)).lowercased()
            if let running = NSWorkspace.shared.runningApplications.first(where: { app in
                guard app.icon != nil else { return false }
                let exeToken = app.executableURL?.lastPathComponent.lowercased()
                let nameToken = app.localizedName?.lowercased()
                return exeToken == token || nameToken == token
            }) {
                return running.icon
            }
            return nil
        } else if let hashIndex = bundleIdentifier.firstIndex(of: "#") {
            let base = String(bundleIdentifier[..<hashIndex])
            let suffixToken = String(bundleIdentifier[bundleIdentifier.index(after: hashIndex)...]).lowercased()
            if let running = NSWorkspace.shared.runningApplications.first(where: { app in
                guard app.icon != nil else { return false }
                let matchesBase = app.bundleIdentifier == base
                let exeToken = app.executableURL?.lastPathComponent.lowercased()
                let nameToken = app.localizedName?.lowercased()
                return matchesBase && (exeToken == suffixToken || nameToken == suffixToken)
            }) {
                return running.icon
            }
            lookupID = base
        } else {
            lookupID = bundleIdentifier
        }

        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == lookupID && $0.icon != nil
        }) {
            return running.icon
        }
        if !lookupID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: lookupID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        return nil
    }

    private static func windowMetadataByPID() -> [pid_t: WindowMetadata] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        let pidKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let boundsKey = kCGWindowBounds as String
        let nameKey = kCGWindowName as String
        let ownerKey = kCGWindowOwnerName as String

        var statsByPID: [pid_t: WindowMetadata] = [:]
        for info in windowList {
            guard let pidNumber = info[pidKey] as? NSNumber else { continue }
            let layer = (info[layerKey] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }

            if let rawBounds = info[boundsKey] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
               bounds.width < 20 || bounds.height < 20 {
                continue
            }

            let pid = pid_t(pidNumber.int32Value)
            var metadata = statsByPID[pid] ?? WindowMetadata()
            metadata.count += 1

            if metadata.ownerName == nil,
               let rawOwner = info[ownerKey] as? String {
                let trimmedOwner = rawOwner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedOwner.isEmpty {
                    metadata.ownerName = trimmedOwner
                }
            }

            if let rawTitle = info[nameKey] as? String {
                let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTitle.isEmpty && !metadata.titles.contains(trimmedTitle) {
                    metadata.titles.append(trimmedTitle)
                }
            }

            statsByPID[pid] = metadata
        }
        return statsByPID
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return buffer.withUnsafeMutableBufferPointer { ptr -> String? in
            guard let baseAddress = ptr.baseAddress else { return nil }
            let bytes = proc_pidpath(pid, baseAddress, UInt32(ptr.count))
            guard bytes > 0 else { return nil }
            return String(cString: baseAddress)
        }
    }

    private static func isSystemUIProcess(
        bundleIdentifier: String?,
        applicationName: String?,
        executableName: String?
    ) -> Bool {
        if let bundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !bundle.isEmpty {
            if excludedSystemTokens.contains(bundle) {
                return true
            }
            for token in excludedSystemTokens where bundle.hasSuffix(".\(token)") {
                return true
            }
        }

        if let exe = executableName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           excludedSystemTokens.contains(exe) {
            return true
        }

        if let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           excludedSystemTokens.contains(name) {
            return true
        }

        return false
    }

    private static func resolveOfflineDisplayName(for identifier: String) -> String {
        if identifier.hasPrefix("proc:") {
            let token = String(identifier.dropFirst("proc:".count))
            return token.isEmpty ? identifier : token
        }
        if let hashIdx = identifier.firstIndex(of: "#") {
            let suffix = String(identifier[identifier.index(after: hashIdx)...])
            return suffix.isEmpty ? identifier : suffix
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
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
        return identifier
    }
}
