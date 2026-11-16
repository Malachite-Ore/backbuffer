import Foundation

public enum AppIdentityResolver {
    private static let sharedRuntimePrefixes: [String] = [
        "com.oracle.java.",
        "net.java.openjdk.",
        "com.azul.zulu.",
        "org.lwjgl.",
        "org.winehq.",
        "com.codeweavers.",
        "com.isaacmarovitz.whisky.",
        "org.python."
    ]

    private static let genericRuntimeTokens: Set<String> = [
        "java",
        "javaw",
        "python",
        "python3",
        "wine",
        "wine64"
    ]

    private static let launcherKeywords: [String] = [
        "tlauncher",
        "prism",
        "multimc",
        "lunar",
        "feather",
        "modrinth",
        "atlauncher",
        "gdlauncher"
    ]

    private static let minecraftPathKeywords: [String] = [
        "minecraft",
        "tlauncher",
        "prismlauncher",
        "multimc",
        "mojang",
        "lunar",
        "modrinth"
    ]

    public static func isSharedRuntimeBundleID(_ bundleIdentifier: String?) -> Bool {
        guard let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return false
        }
        return sharedRuntimePrefixes.contains { trimmed.hasPrefix($0) }
    }

    public static func normalizedProcessToken(
        applicationName: String?,
        executableName: String? = nil,
        executablePath: String? = nil
    ) -> String? {
        let appToken = sanitizeToken(applicationName)
        let exeNameCandidate = sanitizeToken(executableName)
        let exePathLast = (executablePath?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
        let exePathToken = sanitizeToken(exePathLast)
        let exeToken = exeNameCandidate ?? exePathToken

        if let appToken, !genericRuntimeTokens.contains(appToken) {
            return appToken
        }
        if let exeToken, !genericRuntimeTokens.contains(exeToken) {
            return exeToken
        }
        return appToken ?? exeToken
    }

    public static func canonicalIdentifier(
        bundleIdentifier: String?,
        applicationName: String? = nil,
        executableName: String? = nil,
        executablePath: String? = nil
    ) -> String? {
        let trimmedBundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedBundle.hasPrefix("proc:") || trimmedBundle.contains("#") {
            return trimmedBundle
        }

        let token = normalizedProcessToken(
            applicationName: applicationName,
            executableName: executableName,
            executablePath: executablePath
        )

        if !trimmedBundle.isEmpty {
            guard isSharedRuntimeBundleID(trimmedBundle) else {
                return trimmedBundle
            }
            if let token, !token.isEmpty {
                return "\(trimmedBundle)#\(token)"
            }
            return trimmedBundle
        }

        if let token, !token.isEmpty {
            return "proc:\(token)"
        }
        return nil
    }

    public static func matchingIdentifiers(
        bundleIdentifier: String?,
        applicationName: String? = nil,
        executableName: String? = nil,
        executablePath: String? = nil
    ) -> Set<String> {
        var result: Set<String> = []
        let trimmedBundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let canonical = canonicalIdentifier(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            executableName: executableName,
            executablePath: executablePath
        ), !canonical.isEmpty {
            result.insert(canonical)
        }

        if trimmedBundle.hasPrefix("proc:") {
            let suffix = sanitizeToken(String(trimmedBundle.dropFirst("proc:".count)))
            if let suffix, !suffix.isEmpty {
                result.insert("proc:\(suffix)")
            }
            return result
        }

        if let hashIndex = trimmedBundle.firstIndex(of: "#") {
            let suffix = sanitizeToken(String(trimmedBundle[trimmedBundle.index(after: hashIndex)...]))
            if let suffix, !suffix.isEmpty {
                result.insert("proc:\(suffix)")
            }
            return result
        }

        let token = normalizedProcessToken(
            applicationName: applicationName,
            executableName: executableName,
            executablePath: executablePath
        )

        if trimmedBundle.isEmpty || isSharedRuntimeBundleID(trimmedBundle) {
            if let token, !token.isEmpty {
                result.insert("proc:\(token)")
            }
        } else {
            result.insert(trimmedBundle)
        }

        return result
    }

    public static func resolvedPresentation(
        bundleIdentifier: String?,
        applicationName: String?,
        executableName: String? = nil,
        executablePath: String? = nil,
        windowTitles: [String] = []
    ) -> (displayName: String, subtitle: String, searchKeywords: [String]) {
        let canonical = canonicalIdentifier(
            bundleIdentifier: bundleIdentifier,
            applicationName: applicationName,
            executableName: executableName,
            executablePath: executablePath
        ) ?? ""
        let token = normalizedProcessToken(
            applicationName: applicationName,
            executableName: executableName,
            executablePath: executablePath
        ) ?? ""

        let cleanAppName = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanExeName = executableName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanTitles = windowTitles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let loweredApp = cleanAppName.lowercased()
        let isLauncher = launcherKeywords.contains {
            (!loweredApp.isEmpty && loweredApp.contains($0)) || (!token.isEmpty && token.contains($0))
        }

        if isLauncher {
            let displayName = !cleanAppName.isEmpty
                ? cleanAppName
                : (!cleanExeName.isEmpty ? cleanExeName : canonical)
            let keywords = deduplicatedKeywords([displayName, token, canonical] + cleanTitles)
            return (displayName: displayName, subtitle: canonical, searchKeywords: keywords)
        }

        let isJavaRuntime = token == "java"
            || token == "javaw"
            || canonical.hasSuffix("#java")
            || canonical.hasSuffix("#javaw")
            || canonical == "proc:java"
            || canonical == "proc:javaw"

        if isJavaRuntime {
            let minecraftTitle = cleanTitles.first { $0.localizedCaseInsensitiveContains("minecraft") }
            let loweredPath = executablePath?.lowercased() ?? ""
            let pathSuggestsMinecraft = minecraftPathKeywords.contains { loweredPath.contains($0) }

            if minecraftTitle != nil || pathSuggestsMinecraft {
                let subtitle: String
                if let minecraftTitle, !canonical.isEmpty {
                    subtitle = "\(canonical) · \(minecraftTitle)"
                } else {
                    subtitle = canonical.isEmpty ? (minecraftTitle ?? "proc:java") : canonical
                }
                let keywords = deduplicatedKeywords(["minecraft", "java", "Minecraft (java)", canonical] + cleanTitles)
                return (displayName: "Minecraft (java)", subtitle: subtitle, searchKeywords: keywords)
            }

            let fallbackName = !cleanAppName.isEmpty
                ? cleanAppName
                : (!cleanExeName.isEmpty ? cleanExeName : (!token.isEmpty ? token : "java"))
            let keywords = deduplicatedKeywords(["java", "minecraft", "jvm", fallbackName, canonical] + cleanTitles)
            return (displayName: fallbackName, subtitle: canonical, searchKeywords: keywords)
        }

        let trimmedBundle = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName: String
        if !cleanAppName.isEmpty {
            displayName = cleanAppName
        } else if !cleanExeName.isEmpty {
            displayName = cleanExeName
        } else if !trimmedBundle.isEmpty {
            displayName = trimmedBundle
        } else {
            displayName = canonical
        }

        let keywords = deduplicatedKeywords([canonical, displayName] + cleanTitles)
        return (displayName: displayName, subtitle: canonical, searchKeywords: keywords)
    }

    private static func sanitizeToken(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let filteredScalars = trimmed.lowercased().unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && scalar != "#"
                && scalar != ":"
        }
        let result = String(String.UnicodeScalarView(filteredScalars))
        return result.isEmpty ? nil : result
    }

    private static func deduplicatedKeywords(_ inputs: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in inputs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}
