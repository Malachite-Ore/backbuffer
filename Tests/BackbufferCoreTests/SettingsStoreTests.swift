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
}
