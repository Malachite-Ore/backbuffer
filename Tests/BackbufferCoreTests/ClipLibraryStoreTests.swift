import AVFoundation
import CoreGraphics
import Foundation
import XCTest
@testable import BackbufferCore

final class ClipLibraryStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: ClipLibraryStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackbufferLibraryTests-\(UUID().uuidString)", isDirectory: true)
        store = try ClipLibraryStore(rootDirectory: tempRoot)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try super.tearDownWithError()
    }

    func testInitCreatesMastersAndSharedDirectories() {
        var isMastersDir: ObjCBool = false
        var isSharedDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mastersDirectory.path, isDirectory: &isMastersDir))
        XCTAssertTrue(isMastersDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sharedDirectory.path, isDirectory: &isSharedDir))
        XCTAssertTrue(isSharedDir.boolValue)
    }

    func testUniqueMasterURLCollisionDisambiguation() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 15
        components.hour = 16
        components.minute = 0
        components.second = 0
        let fixedDate = try XCTUnwrap(Calendar.current.date(from: components))

        let existingURL = store.mastersDirectory.appendingPathComponent("Backbuffer_2026-11-15_16-00-00.mp4")
        try Data("stub".utf8).write(to: existingURL)

        let secondURL = store.nextMasterURL(for: fixedDate)
        let thirdURL = store.nextMasterURL(for: fixedDate)

        XCTAssertEqual(secondURL.lastPathComponent, "Backbuffer_2026-11-15_16-00-00-2.mp4")
        XCTAssertEqual(thirdURL.lastPathComponent, "Backbuffer_2026-11-15_16-00-00-3.mp4")
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("stub".utf8))
    }

    func testTrimShareURLDoesNotOverwriteFullShareFile() {
        let masterURL = store.mastersDirectory.appendingPathComponent("Backbuffer_2026-11-15_16-00-00.mp4")
        let fullShare = store.shareURL(for: masterURL)
        let trimShare = store.shareURL(for: masterURL, trimRange: TrimRange(startSeconds: 4, endSeconds: 18))

        XCTAssertEqual(fullShare.lastPathComponent, "Backbuffer_2026-11-15_16-00-00_share.mp4")
        XCTAssertEqual(trimShare.lastPathComponent, "Backbuffer_2026-11-15_16-00-00_trim_04s-18s_share.mp4")
        XCTAssertNotEqual(fullShare.standardizedFileURL, trimShare.standardizedFileURL)
        XCTAssertEqual(fullShare.deletingLastPathComponent().standardizedFileURL, store.sharedDirectory.standardizedFileURL)
        XCTAssertEqual(trimShare.deletingLastPathComponent().standardizedFileURL, store.sharedDirectory.standardizedFileURL)

        let trimMaster = store.nextTrimMasterURL(from: masterURL, range: TrimRange(startSeconds: 4, endSeconds: 18))
        XCTAssertEqual(trimMaster.lastPathComponent, "Backbuffer_2026-11-15_16-00-00_trim_04s-18s.mp4")
        XCTAssertEqual(trimMaster.deletingLastPathComponent().standardizedFileURL, store.mastersDirectory.standardizedFileURL)
    }

    func testLoadClipsSortsNewestFirstAndReadsMetadata() async throws {
        let olderURL = store.mastersDirectory.appendingPathComponent("Backbuffer_2026-11-15_15-00-00.mp4")
        let newerURL = store.mastersDirectory.appendingPathComponent("Backbuffer_2026-11-15_15-05-00.mp4")

        try await TestMediaFactory.makeSyntheticMP4(
            to: olderURL,
            durationSeconds: 2.0,
            fps: 30,
            width: 640,
            height: 360,
            videoBitrateBps: 1_000_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: false
        )
        try await TestMediaFactory.makeSyntheticMP4(
            to: newerURL,
            durationSeconds: 3.0,
            fps: 30,
            width: 640,
            height: 360,
            videoBitrateBps: 1_000_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: false
        )

        let olderDate = Date(timeIntervalSince1970: 1_794_750_000)
        let newerDate = Date(timeIntervalSince1970: 1_794_750_300)
        try FileManager.default.setAttributes([.creationDate: olderDate, .modificationDate: olderDate], ofItemAtPath: olderURL.path)
        try FileManager.default.setAttributes([.creationDate: newerDate, .modificationDate: newerDate], ofItemAtPath: newerURL.path)

        let clips = try await store.loadClips(activeCap: .mb20)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].masterURL.lastPathComponent, newerURL.lastPathComponent)
        XCTAssertEqual(clips[1].masterURL.lastPathComponent, olderURL.lastPathComponent)
        XCTAssertEqual(clips[0].width, 640)
        XCTAssertEqual(clips[0].height, 360)
        XCTAssertEqual(clips[0].fps, 30.0, accuracy: 2.0)
        XCTAssertEqual(clips[0].codecName, "H.264")
        XCTAssertEqual(clips[0].durationSeconds, 3.0, accuracy: 0.35)
        XCTAssertEqual(clips[0].shareStatus, .fitsDirectly)

        let disabledClips = try await store.loadClips(activeCap: .off)
        XCTAssertEqual(disabledClips.first?.shareStatus, .disabled)
    }

    func testResolveShareClipLazilyRecompressesWhenCapLowered() async throws {
        let masterURL = store.mastersDirectory.appendingPathComponent("Backbuffer_2026-11-15_16-10-00.mp4")
        let shareURL = store.shareURL(for: masterURL)

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 4.0,
            fps: 30,
            width: 640,
            height: 360,
            videoBitrateBps: 8_000_000,
            codec: .h264,
            includeAudio: true,
            highEntropy: true
        )

        let masterBytes = try fileSize(of: masterURL)
        XCTAssertGreaterThan(masterBytes, 900_000)
        let initialCap = Int64(Double(masterBytes) * 0.70)
        let producedShare = try await ClipCompressor.compressIfNeeded(
            masterURL: masterURL,
            outputURL: shareURL,
            capBytes: initialCap,
            codec: .h264
        )
        XCTAssertEqual(producedShare.standardizedFileURL, shareURL.standardizedFileURL)

        let initialShareBytes = try fileSize(of: shareURL)
        let masterSHA = try TestMediaFactory.sha256Hex(of: masterURL)
        let initialShareSHA = try TestMediaFactory.sha256Hex(of: shareURL)

        // Verify current cap marks .compressed(bytes:) without altering files
        let loadedUnderInitialCap = try await store.loadClips(maxCapBytes: initialCap)
        XCTAssertEqual(loadedUnderInitialCap.count, 1)
        XCTAssertEqual(loadedUnderInitialCap[0].shareStatus, .compressed(bytes: initialShareBytes))

        // Lower cap below existing share file: Q7 = A requires NO eager background re-encode on loadClips
        let tightenedCap = max(Int64(250_000), Int64(Double(initialShareBytes) * 0.55))
        XCTAssertLessThan(tightenedCap, initialShareBytes)

        let loadedUnderTightCap = try await store.loadClips(maxCapBytes: tightenedCap)
        XCTAssertEqual(loadedUnderTightCap.count, 1)
        XCTAssertEqual(loadedUnderTightCap[0].shareStatus, .overNewCap(bytes: initialShareBytes))
        XCTAssertEqual(try TestMediaFactory.sha256Hex(of: shareURL), initialShareSHA, "loadClips must not modify Shared/ eagerly")
        XCTAssertEqual(try TestMediaFactory.sha256Hex(of: masterURL), masterSHA)

        // Clicking Copy Share Clip triggers lazy recompression against untouched Master
        let resolvedURL = try await store.resolveShareClip(
            for: loadedUnderTightCap[0],
            maxCapBytes: tightenedCap,
            codec: .h264
        )
        XCTAssertEqual(resolvedURL.standardizedFileURL, shareURL.standardizedFileURL)

        let updatedShareBytes = try fileSize(of: shareURL)
        XCTAssertGreaterThan(updatedShareBytes, 0)
        XCTAssertLessThanOrEqual(updatedShareBytes, tightenedCap)
        XCTAssertEqual(try TestMediaFactory.sha256Hex(of: masterURL), masterSHA, "Master clip must remain untouched")

        let reloaded = try await store.loadClips(maxCapBytes: tightenedCap)
        XCTAssertEqual(reloaded.first?.shareStatus, .compressed(bytes: updatedShareBytes))
    }

    func testThumbnailsAndDeletePairOrShareOnly() async throws {
        let masterURL = store.mastersDirectory.appendingPathComponent("Backbuffer_2026-11-15_16-20-00.mp4")
        let shareURL = store.shareURL(for: masterURL)

        try await TestMediaFactory.makeSyntheticMP4(
            to: masterURL,
            durationSeconds: 2.0,
            fps: 30,
            width: 320,
            height: 180,
            videoBitrateBps: 1_000_000,
            codec: .h264,
            includeAudio: false,
            highEntropy: false
        )
        try FileManager.default.copyItem(at: masterURL, to: shareURL)

        let thumb1 = try await store.thumbnail(for: masterURL, atSeconds: 0.5, maximumSize: CGSize(width: 160, height: 90))
        let thumb2 = try await store.thumbnail(for: masterURL, atSeconds: 0.5, maximumSize: CGSize(width: 160, height: 90))
        XCTAssertGreaterThan(thumb1.width, 0)
        XCTAssertGreaterThan(thumb1.height, 0)
        XCTAssertEqual(thumb1.width, thumb2.width)

        let strip = try await store.filmstripThumbnails(for: masterURL, count: 4, maximumSize: CGSize(width: 160, height: 90))
        XCTAssertEqual(strip.count, 4)
        XCTAssertTrue(strip.allSatisfy { $0.width > 0 && $0.height > 0 })

        let loaded = try await store.loadClips(activeCap: .mb20)
        XCTAssertEqual(loaded.count, 1)

        try store.deleteShareCopy(for: loaded[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: masterURL.path))

        try store.deleteClipPair(loaded[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: masterURL.path))
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
