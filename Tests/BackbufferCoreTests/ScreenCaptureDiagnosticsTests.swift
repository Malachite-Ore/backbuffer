import CryptoKit
import Foundation
import XCTest
@testable import BackbufferCore

final class ScreenCaptureDiagnosticsTests: XCTestCase {
    func testClassifyInstallLocationVariants() {
        let dmgIssue = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/Volumes/Backbuffer/Backbuffer.app",
            applicationsBundleExists: false
        )
        XCTAssertEqual(dmgIssue, .runningFromDiskImage(bundlePath: "/Volumes/Backbuffer/Backbuffer.app"))
        XCTAssertTrue(dmgIssue.requiresMoveToApplications)
        XCTAssertFalse(dmgIssue.userTitle.isEmpty)
        XCTAssertFalse(dmgIssue.userExplanation.isEmpty)

        let translocatedIssue = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/private/var/folders/ab/cd/T/AppTranslocation/1234-5678/d/Backbuffer.app",
            applicationsBundleExists: true
        )
        XCTAssertEqual(
            translocatedIssue,
            .appTranslocated(bundlePath: "/private/var/folders/ab/cd/T/AppTranslocation/1234-5678/d/Backbuffer.app")
        )
        XCTAssertTrue(translocatedIssue.requiresMoveToApplications)
        XCTAssertFalse(translocatedIssue.userTitle.isEmpty)

        let shadowedIssue = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/Users/vinn/Downloads/Backbuffer.app",
            applicationsBundleExists: true,
            homeDirectoryPath: "/Users/vinn"
        )
        XCTAssertEqual(
            shadowedIssue,
            .shadowedByApplicationsCopy(
                runningPath: "/Users/vinn/Downloads/Backbuffer.app",
                applicationsPath: "/Applications/Backbuffer.app"
            )
        )
        XCTAssertTrue(shadowedIssue.requiresMoveToApplications)
        XCTAssertFalse(shadowedIssue.userTitle.isEmpty)

        let unshadowedDownloads = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/Users/vinn/Downloads/Backbuffer.app",
            applicationsBundleExists: false,
            homeDirectoryPath: "/Users/vinn"
        )
        XCTAssertEqual(unshadowedDownloads, .none)
        XCTAssertFalse(unshadowedDownloads.requiresMoveToApplications)

        let systemApps = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/Applications/Backbuffer.app",
            applicationsBundleExists: true,
            homeDirectoryPath: "/Users/vinn"
        )
        XCTAssertEqual(systemApps, .none)

        let userApps = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/Users/vinn/Applications/Backbuffer.app",
            applicationsBundleExists: true,
            homeDirectoryPath: "/Users/vinn"
        )
        XCTAssertEqual(userApps, .none)

        let cliBinary = ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: "/Users/runner/work/backbuffer/.build/release/BackbufferApp",
            applicationsBundleExists: true,
            homeDirectoryPath: "/Users/runner"
        )
        XCTAssertEqual(cliBinary, .none)
    }

    func testEvaluateStaleTCCAutoResetAllDecisions() {
        // 1. Install location issue always wins over auto-reset
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .runningFromDiskImage(bundlePath: "/Volumes/Backbuffer/Backbuffer.app"),
                currentExecutableHash: "hash_v111",
                lastAuthorizedExecutableHash: "hash_v101",
                lastAutoResetExecutableHash: nil,
                hasPriorUsageEvidence: true
            ),
            .skipInstallIssuePresent
        )

        // 2. Missing or empty executable signature skips
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: nil,
                lastAuthorizedExecutableHash: "hash_v101",
                lastAutoResetExecutableHash: nil,
                hasPriorUsageEvidence: true
            ),
            .skipMissingExecutableSignature
        )
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: "",
                lastAuthorizedExecutableHash: nil,
                lastAutoResetExecutableHash: nil,
                hasPriorUsageEvidence: true
            ),
            .skipMissingExecutableSignature
        )

        // 3. Upgrade from v1.0.1/v1.1.0 (prior usage evidence, no stored hash) triggers one-time auto-reset
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: "hash_v111",
                lastAuthorizedExecutableHash: nil,
                lastAutoResetExecutableHash: nil,
                hasPriorUsageEvidence: true
            ),
            .autoResetOnce
        )

        // 4. Subsequent launch of same v1.1.1 binary is blocked by anti-loop guard
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: "hash_v111",
                lastAuthorizedExecutableHash: nil,
                lastAutoResetExecutableHash: "hash_v111",
                hasPriorUsageEvidence: true
            ),
            .skipAlreadyAutoResetForCurrentBinary
        )

        // 5. Same binary previously succeeded -> do not override manual user revocation
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: "hash_v111",
                lastAuthorizedExecutableHash: "hash_v111",
                lastAutoResetExecutableHash: nil,
                hasPriorUsageEvidence: true
            ),
            .skipAlreadyAuthorizedCurrentBinary
        )

        // 6. Future upgrade v1.1.1 -> v1.2.0 triggers a fresh single auto-reset for the new hash
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: "hash_v120",
                lastAuthorizedExecutableHash: "hash_v111",
                lastAutoResetExecutableHash: "hash_v111",
                hasPriorUsageEvidence: true
            ),
            .autoResetOnce
        )

        // 7. Brand-new fresh install skips auto-reset cleanly
        XCTAssertEqual(
            ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
                installIssue: .none,
                currentExecutableHash: "hash_v111",
                lastAuthorizedExecutableHash: nil,
                lastAutoResetExecutableHash: nil,
                hasPriorUsageEvidence: false
            ),
            .skipFreshInstallNoPriorHistory
        )
    }

    func testComputeExecutableSHA256DeterministicAndMissingSafe() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbuffer-diag-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let binaryURL = tempDir.appendingPathComponent("Backbuffer")
        let payload = Data("backbuffer-v1.1.1-executable-stub".utf8)
        try payload.write(to: binaryURL)

        let expectedHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ScreenCaptureDiagnostics.computeExecutableSHA256(at: binaryURL), expectedHash)
        XCTAssertEqual(ScreenCaptureDiagnostics.computeExecutableSHA256(at: binaryURL), expectedHash)

        let missingURL = tempDir.appendingPathComponent("DoesNotExist")
        XCTAssertNil(ScreenCaptureDiagnostics.computeExecutableSHA256(at: missingURL))
        XCTAssertNil(ScreenCaptureDiagnostics.computeExecutableSHA256(at: tempDir))
    }

    func testSettingsStoreTCCHashHistoryAndResetPreservation() {
        let suiteName = "io.malachiteore.backbuffer.diag.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create ephemeral UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: defaults, storageKey: "test.diag.settings")
        XCTAssertFalse(store.hasPersistedSettings)
        XCTAssertNil(store.lastAuthorizedExecutableHash())
        XCTAssertNil(store.lastAutoResetExecutableHash())

        store.save(.default)
        XCTAssertTrue(store.hasPersistedSettings)

        store.setLastAuthorizedExecutableHash("auth_hash_v111")
        store.setLastAutoResetExecutableHash("reset_hash_v111")
        XCTAssertEqual(store.lastAuthorizedExecutableHash(), "auth_hash_v111")
        XCTAssertEqual(store.lastAutoResetExecutableHash(), "reset_hash_v111")

        // reset() clears only capture settings while keeping TCC upgrade signature history
        store.reset()
        XCTAssertFalse(store.hasPersistedSettings)
        XCTAssertEqual(store.lastAuthorizedExecutableHash(), "auth_hash_v111")
        XCTAssertEqual(store.lastAutoResetExecutableHash(), "reset_hash_v111")

        store.setLastAuthorizedExecutableHash(nil)
        store.setLastAutoResetExecutableHash("")
        XCTAssertNil(store.lastAuthorizedExecutableHash())
        XCTAssertNil(store.lastAutoResetExecutableHash())
    }

    func testIsScreenCapturePermissionErrorFiltering() {
        XCTAssertTrue(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                code: -3801,
                localizedDescription: ""
            )
        )
        XCTAssertTrue(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "NSCocoaErrorDomain",
                code: 1,
                localizedDescription: "The user declined TCC screen recording access"
            )
        )
        XCTAssertTrue(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "NSCocoaErrorDomain",
                code: 2,
                localizedDescription: "Application is not authorized to capture display"
            )
        )
        XCTAssertTrue(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "BackbufferError",
                code: 0,
                localizedDescription: BackbufferError.screenRecordingPermissionDenied.localizedDescription
            )
        )

        XCTAssertFalse(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "BackbufferError",
                code: 0,
                localizedDescription: BackbufferError.noAllowedAppsSelected.localizedDescription
            )
        )
        XCTAssertFalse(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "BackbufferError",
                code: 0,
                localizedDescription: BackbufferError.microphonePermissionDenied.localizedDescription
            )
        )
        XCTAssertFalse(
            ScreenCaptureDiagnostics.isScreenCapturePermissionError(
                domain: "NSCocoaErrorDomain",
                code: 4,
                localizedDescription: "The file does not exist."
            )
        )
    }
}
