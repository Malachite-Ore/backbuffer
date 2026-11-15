#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics
import Foundation
import XCTest
@testable import BackbufferCore

final class SettingsStoreTests: XCTestCase {
    func testDefaultBalanced1080p60FitsUnder20MB() {
        let settings = CaptureSettings.default
        let estimate = SettingsStore.estimate(for: settings)

        XCTAssertEqual(estimate.videoBitrateBps, 4_500_000)
        XCTAssertEqual(estimate.audioBitrateBps, 160_000)
        XCTAssertTrue((17.0...18.2).contains(estimate.estimatedMasterMB), "Expected ~17.5 MB, got \(estimate.estimatedMasterMB)")
        XCTAssertFalse(estimate.willAutoCompress)
    }

    func testPostMasterAndNative4KScaling() {
        var settings = CaptureSettings.default
        settings.quality = .postMaster
        settings.resolutionCap = .native
        settings.fps = .fps60
        settings.shareCap = .mb20

        let estimate = SettingsStore.estimate(
            for: settings,
            targetPixelSize: CGSize(width: 3840, height: 2160)
        )

        XCTAssertEqual(estimate.videoBitrateBps, 45_000_000)
        XCTAssertEqual(estimate.audioBitrateBps, 192_000)
        XCTAssertTrue(estimate.willAutoCompress)
    }

    func testComputeTargetDimensionsOddAnd5KClamp() {
        let oddWindow = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: 1365,
            logicalHeight: 767,
            pointPixelScale: 1.0,
            cap: .native
        )
        XCTAssertEqual(oddWindow.width, 1364)
        XCTAssertEqual(oddWindow.height, 766)

        let retina1080 = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: 1512,
            logicalHeight: 982,
            pointPixelScale: 2.0,
            cap: .p1080
        )
        XCTAssertEqual(retina1080.width, 1662)
        XCTAssertEqual(retina1080.height, 1080)

        let display5K = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: 2560,
            logicalHeight: 1440,
            pointPixelScale: 2.0,
            cap: .native
        )
        XCTAssertEqual(display5K.width, 4096)
        XCTAssertEqual(display5K.height, 2304)
    }

    func testSettingsStorePersistenceRoundTrip() {
        let suiteName = "io.malachiteore.backbuffer.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create ephemeral UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: defaults, storageKey: "test.settings")
        let custom = CaptureSettings(
            fps: .fps30,
            resolutionCap: .p720,
            quality: .high,
            codec: .h264,
            bufferDuration: .s60,
            shareCap: .mb10,
            outputRootPath: "/tmp/BackbufferTestRoot",
            saveHotKey: HotKeyShortcut(keyCode: 15, carbonModifiers: HotKeyShortcut.carbonControlKey | HotKeyShortcut.carbonCmdKey)
        )

        store.save(custom)
        let loaded = store.load()
        XCTAssertEqual(loaded, custom)
        XCTAssertEqual(loaded.saveHotKey.displayString, "⌃⌘R")
    }

    func testDefaultSaveClipIsControlShiftSAndPresetsExist() {
        XCTAssertEqual(HotKeyShortcut.defaultSaveClip.keyCode, 1)
        XCTAssertEqual(
            HotKeyShortcut.defaultSaveClip.carbonModifiers,
            HotKeyShortcut.carbonControlKey | HotKeyShortcut.carbonShiftKey
        )
        XCTAssertEqual(HotKeyShortcut.defaultSaveClip.displayString, "⌃⇧S")
        XCTAssertEqual(HotKeyShortcut.f8Preset, HotKeyShortcut(keyCode: 100, carbonModifiers: 0))
        XCTAssertEqual(HotKeyShortcut.f8Preset.displayString, "F8")
        XCTAssertEqual(HotKeyShortcut.f9Preset, HotKeyShortcut(keyCode: 101, carbonModifiers: 0))
        XCTAssertEqual(HotKeyShortcut.f9Preset.displayString, "F9")
        XCTAssertEqual(HotKeyShortcut.keyName(for: 64), "F17")
        XCTAssertEqual(HotKeyShortcut.keyName(for: 90), "F20")
        XCTAssertEqual(HotKeyShortcut.keyName(for: 87), "Num 5")
        XCTAssertEqual(HotKeyShortcut.keyName(for: 123), "←")
        XCTAssertEqual(HotKeyShortcut.keyName(for: 115), "Home")
    }

    func testHotKeyValidationAndStandaloneRules() {
        // Standalone F-keys & Keypad keys are permitted without modifiers
        XCTAssertTrue(HotKeyShortcut.isStandaloneAllowedKeyCode(100)) // F8
        XCTAssertTrue(HotKeyShortcut.isStandaloneAllowedKeyCode(101)) // F9
        XCTAssertTrue(HotKeyShortcut.isStandaloneAllowedKeyCode(90))  // F20
        XCTAssertTrue(HotKeyShortcut.isStandaloneAllowedKeyCode(87))  // Keypad 5
        XCTAssertNil(HotKeyShortcut.validationMessage(keyCode: 100, carbonModifiers: 0))
        XCTAssertNil(HotKeyShortcut.validationMessage(keyCode: 101, carbonModifiers: 0))
        XCTAssertNil(HotKeyShortcut.validationMessage(keyCode: 87, carbonModifiers: 0))

        // Regular letter 'A' rejected standalone or with Shift alone, accepted with primary modifier
        XCTAssertFalse(HotKeyShortcut.isStandaloneAllowedKeyCode(0))
        XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: 0, carbonModifiers: 0))
        XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: 0, carbonModifiers: HotKeyShortcut.carbonShiftKey))
        XCTAssertNil(HotKeyShortcut.validationMessage(keyCode: 0, carbonModifiers: HotKeyShortcut.carbonControlKey))

        // Modifier-only key codes 54...63 rejected
        for modCode: UInt32 in 54...63 {
            XCTAssertTrue(HotKeyShortcut.isModifierKeyCode(modCode))
            XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: modCode, carbonModifiers: HotKeyShortcut.carbonCmdKey))
        }
        XCTAssertFalse(HotKeyShortcut.isModifierKeyCode(100))

        // Escape (53) and Delete (51) rejected even with modifiers
        XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: 53, carbonModifiers: 0))
        XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: 53, carbonModifiers: HotKeyShortcut.carbonCmdKey))
        XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: 51, carbonModifiers: 0))
        XCTAssertNotNil(HotKeyShortcut.validationMessage(keyCode: 51, carbonModifiers: HotKeyShortcut.carbonCmdKey))

        #if canImport(AppKit)
        if let f8Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 100
        ) {
            let captured = HotKeyShortcut(event: f8Event)
            XCTAssertEqual(captured, HotKeyShortcut.f8Preset)
        } else {
            XCTFail("Expected synthetic F8 NSEvent")
        }

        if let plainAEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) {
            XCTAssertNil(HotKeyShortcut(event: plainAEvent))
        }

        if let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) {
            XCTAssertNil(HotKeyShortcut(event: escapeEvent))
        }

        if let deleteEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false,
            keyCode: 51
        ) {
            XCTAssertNil(HotKeyShortcut(event: deleteEvent))
        }

        if let shiftOnlyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 56
        ) {
            XCTAssertNil(HotKeyShortcut(event: shiftOnlyEvent))
        }
        #endif
    }

    func testBackwardsCompatibleV101JSONDecodingAndStoreNormalization() throws {
        let legacyJSON = """
        {
          "fps": 30,
          "resolutionCap": "p720",
          "quality": "high",
          "codec": "h264",
          "bufferDuration": 60,
          "shareCap": 10,
          "outputRootPath": "/tmp/LegacyBackbuffer",
          "saveHotKey": {
            "keyCode": 1,
            "carbonModifiers": 2304,
            "displayString": "⌥⌘S"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CaptureSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded.fps, .fps30)
        XCTAssertEqual(decoded.resolutionCap, .p720)
        XCTAssertEqual(decoded.quality, .high)
        XCTAssertEqual(decoded.codec, .h264)
        XCTAssertEqual(decoded.bufferDuration, .s60)
        XCTAssertEqual(decoded.shareCap, .mb10)
        XCTAssertEqual(decoded.outputRootPath, "/tmp/LegacyBackbuffer")
        XCTAssertEqual(decoded.saveHotKey.keyCode, 1)

        XCTAssertNil(decoded.togglePauseHotKey)
        XCTAssertTrue(decoded.playSoundOnSave)
        XCTAssertFalse(decoded.recordMicrophone)
        XCTAssertNil(decoded.selectedMicrophoneID)
        XCTAssertEqual(decoded.microphoneGain, 1.0, accuracy: 0.0001)
        XCTAssertFalse(decoded.isMicrophoneMuted)
        XCTAssertFalse(decoded.separateAudioTracksInMaster)
        XCTAssertEqual(decoded.privacyMode, .strictAllowlist)
        XCTAssertTrue(decoded.allowedAppBundleIDs.isEmpty)
        XCTAssertTrue(decoded.blockedAppBundleIDs.isEmpty)
        XCTAssertTrue(decoded.rememberedApps.isEmpty)

        // Store normalization clamps microphoneGain and deduplicates rememberedApps
        let suiteName = "io.malachiteore.backbuffer.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create ephemeral UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: defaults, storageKey: "test.v110.norm")
        var dirty = CaptureSettings.default
        dirty.microphoneGain = 4.5
        dirty.allowedAppBundleIDs = [" com.riotgames.valorant ", "", "   "]
        dirty.rememberedApps = [
            RememberedAppInfo(bundleIdentifier: "com.riotgames.valorant", displayName: "Valorant"),
            RememberedAppInfo(bundleIdentifier: "com.mojang.minecraft", displayName: "Minecraft"),
            RememberedAppInfo(bundleIdentifier: "com.riotgames.valorant", displayName: "VALORANT"),
            RememberedAppInfo(bundleIdentifier: "   ", displayName: "Invalid")
        ]
        store.save(dirty)

        let normalized = store.load()
        XCTAssertEqual(normalized.microphoneGain, 2.0, accuracy: 0.0001)
        XCTAssertEqual(normalized.allowedAppBundleIDs, ["com.riotgames.valorant"])
        XCTAssertEqual(normalized.rememberedApps.count, 2)
        XCTAssertEqual(normalized.rememberedApps.map(\.bundleIdentifier), ["com.riotgames.valorant", "com.mojang.minecraft"])

        var negativeGain = CaptureSettings.default
        negativeGain.microphoneGain = -0.8
        XCTAssertEqual(negativeGain.clampedMicrophoneGain(), 0.0, accuracy: 0.0001)

        // Verify AudioTrackInput backward-compatible default & new error descriptions
        let defaultAudioInput = AudioTrackInput(chunks: [])
        XCTAssertTrue(defaultAudioInput.isEnabledByDefault)
        XCTAssertNotNil(BackbufferError.microphonePermissionDenied.errorDescription)
        XCTAssertNotNil(BackbufferError.noAllowedAppsSelected.errorDescription)
    }

    func testAppPrivacyModeApplicationFiltering() {
        var settings = CaptureSettings.default
        settings.privacyMode = .strictAllowlist
        settings.allowedAppBundleIDs = ["com.riotgames.valorant"]
        settings.blockedAppBundleIDs = ["com.apple.Safari"]

        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: nil))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: ""))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "com.riotgames.valorant"))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "com.mojang.minecraft"))

        settings.privacyMode = .allowAllExceptBlocked
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: nil))
        XCTAssertTrue(settings.isApplicationAllowed(bundleIdentifier: "com.mojang.minecraft"))
        XCTAssertFalse(settings.isApplicationAllowed(bundleIdentifier: "com.apple.Safari"))
    }

    func testMicrophoneRAMAndSeparateStemsEstimator() {
        let baselineSettings = CaptureSettings.default
        let baseline = SettingsStore.estimate(for: baselineSettings)

        var micSettings = baselineSettings
        micSettings.recordMicrophone = true
        micSettings.separateAudioTracksInMaster = false
        let withMic = SettingsStore.estimate(for: micSettings)

        // Master size unchanged when separate stems is off; RAM increases by 48kHz * 2ch * 2B over (30s + 2s) = 6.144 MB
        XCTAssertEqual(withMic.estimatedMasterMB, baseline.estimatedMasterMB, accuracy: 0.0001)
        let ramDelta = withMic.estimatedRAMBufferMB - baseline.estimatedRAMBufferMB
        XCTAssertEqual(ramDelta, 6.144, accuracy: 0.05)

        var stemSettings = micSettings
        stemSettings.separateAudioTracksInMaster = true
        let withStems = SettingsStore.estimate(for: stemSettings)

        // Two additional 160 kbps AAC stems over 30s add +1.2 MB to Master estimate
        let masterDelta = withStems.estimatedMasterMB - withMic.estimatedMasterMB
        XCTAssertEqual(masterDelta, 1.2, accuracy: 0.05)
    }
}
