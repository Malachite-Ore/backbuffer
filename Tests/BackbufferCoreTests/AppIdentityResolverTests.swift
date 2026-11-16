import Foundation
import XCTest
@testable import BackbufferCore

final class AppIdentityResolverTests: XCTestCase {
    func testSharedRuntimeDetectionAndTLauncherVsJavaSeparation() {
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("com.oracle.java.java"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("net.java.openjdk.java"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("com.azul.zulu.java"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("org.lwjgl.lwjgl"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("org.winehq.wine"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("com.codeweavers.CrossOver"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("com.isaacmarovitz.whisky.wine"))
        XCTAssertTrue(AppIdentityResolver.isSharedRuntimeBundleID("org.python.python"))
        XCTAssertFalse(AppIdentityResolver.isSharedRuntimeBundleID("com.riotgames.valorant"))
        XCTAssertFalse(AppIdentityResolver.isSharedRuntimeBundleID(nil))
        XCTAssertFalse(AppIdentityResolver.isSharedRuntimeBundleID(""))

        let tlauncherID = AppIdentityResolver.canonicalIdentifier(
            bundleIdentifier: "com.oracle.java.java",
            applicationName: "TLauncher",
            executableName: "java",
            executablePath: "/Applications/TLauncher.app/Contents/MacOS/java"
        )
        let minecraftJavaID = AppIdentityResolver.canonicalIdentifier(
            bundleIdentifier: "com.oracle.java.java",
            applicationName: "java",
            executableName: "java",
            executablePath: "/Users/vinn/Library/Application Support/minecraft/runtime/bin/java"
        )
        let unbundledJavaID = AppIdentityResolver.canonicalIdentifier(
            bundleIdentifier: nil,
            applicationName: nil,
            executableName: "java",
            executablePath: "/Users/vinn/Library/Application Support/minecraft/runtime/bin/java"
        )

        XCTAssertEqual(tlauncherID, "com.oracle.java.java#tlauncher")
        XCTAssertEqual(minecraftJavaID, "com.oracle.java.java#java")
        XCTAssertEqual(unbundledJavaID, "proc:java")
        XCTAssertNotEqual(tlauncherID, minecraftJavaID)

        // Preserves pre-canonicalized tokens and ordinary bundle IDs
        XCTAssertEqual(
            AppIdentityResolver.canonicalIdentifier(bundleIdentifier: "proc:java", applicationName: "Minecraft (java)"),
            "proc:java"
        )
        XCTAssertEqual(
            AppIdentityResolver.canonicalIdentifier(bundleIdentifier: "com.oracle.java.java#tlauncher", applicationName: "TLauncher"),
            "com.oracle.java.java#tlauncher"
        )
        XCTAssertEqual(
            AppIdentityResolver.canonicalIdentifier(bundleIdentifier: "com.apple.Safari", applicationName: "Safari"),
            "com.apple.Safari"
        )
    }

    func testMatchingIdentifiersCrossMatchJavaWithoutLeakingToTLauncher() {
        let bundledJavaMatches = AppIdentityResolver.matchingIdentifiers(
            bundleIdentifier: "com.oracle.java.java",
            applicationName: "java",
            executableName: "java"
        )
        XCTAssertEqual(bundledJavaMatches, ["com.oracle.java.java#java", "proc:java"])

        let unbundledJavaMatches = AppIdentityResolver.matchingIdentifiers(
            bundleIdentifier: "",
            applicationName: "java",
            executableName: "java"
        )
        XCTAssertEqual(unbundledJavaMatches, ["proc:java"])

        let tlauncherMatches = AppIdentityResolver.matchingIdentifiers(
            bundleIdentifier: "com.oracle.java.java",
            applicationName: "TLauncher",
            executableName: "java"
        )
        XCTAssertEqual(tlauncherMatches, ["com.oracle.java.java#tlauncher", "proc:tlauncher"])
        XCTAssertTrue(bundledJavaMatches.isDisjoint(with: tlauncherMatches))

        // Already-canonicalized candidate IDs preserve their proc/hash identity even with rich display names
        XCTAssertEqual(
            AppIdentityResolver.matchingIdentifiers(bundleIdentifier: "proc:java", applicationName: "Minecraft (java)"),
            ["proc:java"]
        )
        XCTAssertEqual(
            AppIdentityResolver.matchingIdentifiers(bundleIdentifier: "com.oracle.java.java#tlauncher", applicationName: "TLauncher"),
            ["com.oracle.java.java#tlauncher", "proc:tlauncher"]
        )
    }

    func testResolvedPresentationMinecraftTLauncherAndOrdinaryApps() {
        let tlauncher = AppIdentityResolver.resolvedPresentation(
            bundleIdentifier: "com.oracle.java.java",
            applicationName: "TLauncher",
            executableName: "java"
        )
        XCTAssertEqual(tlauncher.displayName, "TLauncher")
        XCTAssertEqual(tlauncher.subtitle, "com.oracle.java.java#tlauncher")

        let minecraftTitled = AppIdentityResolver.resolvedPresentation(
            bundleIdentifier: nil,
            applicationName: "java",
            executableName: "java",
            executablePath: "/Users/vinn/Library/Application Support/minecraft/jre/bin/java",
            windowTitles: ["Minecraft 1.21.11"]
        )
        XCTAssertEqual(minecraftTitled.displayName, "Minecraft (java)")
        XCTAssertEqual(minecraftTitled.subtitle, "proc:java · Minecraft 1.21.11")
        XCTAssertTrue(minecraftTitled.searchKeywords.contains(where: { $0.lowercased() == "minecraft" }))
        XCTAssertTrue(minecraftTitled.searchKeywords.contains(where: { $0.lowercased() == "java" }))

        let earlyJavaWindow = AppIdentityResolver.resolvedPresentation(
            bundleIdentifier: "",
            applicationName: nil,
            executableName: "java",
            executablePath: "/usr/bin/java",
            windowTitles: []
        )
        XCTAssertEqual(earlyJavaWindow.displayName, "java")
        XCTAssertEqual(earlyJavaWindow.subtitle, "proc:java")
        XCTAssertTrue(earlyJavaWindow.searchKeywords.contains(where: { $0.lowercased() == "minecraft" }))
        XCTAssertTrue(earlyJavaWindow.searchKeywords.contains(where: { $0.lowercased() == "jvm" }))

        let ordinary = AppIdentityResolver.resolvedPresentation(
            bundleIdentifier: "com.riotgames.valorant",
            applicationName: "VALORANT",
            windowTitles: ["VALORANT"]
        )
        XCTAssertEqual(ordinary.displayName, "VALORANT")
        XCTAssertEqual(ordinary.subtitle, "com.riotgames.valorant")
    }

    func testCaptureSettingsIsApplicationAllowedWithSharedRuntimeAndUnbundledJava() {
        var settings = CaptureSettings.default
        settings.privacyMode = .strictAllowlist

        // Allow only TLauncher -> TLauncher allowed, unbundled/bundled java blocked
        settings.allowedAppBundleIDs = ["com.oracle.java.java#tlauncher"]
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "TLauncher", executableName: "java"))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "java", executableName: "java"))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "", applicationName: "java", executableName: "java"))

        // Allow unbundled proc:java -> matches both empty-bundle java and com.oracle.java.java#java, NOT TLauncher
        settings.allowedAppBundleIDs = ["proc:java"]
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: nil, applicationName: "java", executableName: "java"))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "java", executableName: "java"))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "proc:java", applicationName: "Minecraft (java)"))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "TLauncher", executableName: "java"))

        // Allow bundled com.oracle.java.java#java -> also matches unbundled proc:java and vice versa
        settings.allowedAppBundleIDs = ["com.oracle.java.java#java"]
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "", applicationName: "java", executableName: "java"))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "proc:java", applicationName: "Minecraft (java)"))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "TLauncher", executableName: "java"))

        // AllowAllExceptBlocked blocking only TLauncher keeps Minecraft java allowed
        settings.privacyMode = .allowAllExceptBlocked
        settings.blockedAppBundleIDs = ["com.oracle.java.java#tlauncher"]
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "TLauncher", executableName: "java"))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "com.oracle.java.java", applicationName: "java", executableName: "java"))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: nil, applicationName: "java", executableName: "java"))
    }
}
