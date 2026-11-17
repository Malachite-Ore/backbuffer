import AVFoundation
import Foundation
import XCTest
@testable import BackbufferCore

final class SaveSoundCueTests: XCTestCase {
    func testBuiltInWAVPayloadsAreValidStereoPCMAndPlayableByAVAudioPlayer() throws {
        var peaks: [BuiltInCueKind: Int] = [:]

        for kind in BuiltInCueKind.allCases {
            let wav = SaveSoundCueLibrary.wavData(for: kind)
            let minimumExpectedBytes = 44 + Int(Double(SaveSoundCueLibrary.sampleRate) * 0.09) * 4
            XCTAssertGreaterThanOrEqual(wav.count, minimumExpectedBytes, "Expected >=90ms WAV payload for \(kind)")

            XCTAssertEqual(String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            XCTAssertEqual(String(data: wav.subdata(in: 12..<16), encoding: .ascii), "fmt ")
            XCTAssertEqual(String(data: wav.subdata(in: 36..<40), encoding: .ascii), "data")

            let riffChunkSize = readUInt32LE(wav, offset: 4)
            let audioFormat = readUInt16LE(wav, offset: 20)
            let numChannels = readUInt16LE(wav, offset: 22)
            let sampleRate = readUInt32LE(wav, offset: 24)
            let bitsPerSample = readUInt16LE(wav, offset: 34)
            let dataChunkSize = readUInt32LE(wav, offset: 40)

            XCTAssertEqual(Int(riffChunkSize), wav.count - 8)
            XCTAssertEqual(audioFormat, 1)
            XCTAssertEqual(numChannels, 2)
            XCTAssertEqual(sampleRate, 48_000)
            XCTAssertEqual(bitsPerSample, 16)
            XCTAssertEqual(Int(dataChunkSize), wav.count - 44)

            var maxAbs = 0
            var offset = 44
            while offset + 2 <= wav.count {
                let s = Int(readInt16LE(wav, offset: offset))
                maxAbs = max(maxAbs, abs(s))
                offset += 2
            }
            XCTAssertGreaterThan(maxAbs, 500, "Expected audible peak for \(kind)")
            peaks[kind] = maxAbs

            let player = try AVAudioPlayer(data: wav)
            XCTAssertEqual(player.numberOfChannels, 2)
            XCTAssertGreaterThan(player.duration, 0.08)
        }

        if let thudPeak = peaks[.blockedThud], let chimePeak = peaks[.medalDoubleChime] {
            XCTAssertLessThan(thudPeak, chimePeak, "Blocked thud should stay gentler than the save chime")
        }
    }

    func testCaptureSettingsSaveSoundBackwardsCompatibilityAndLabels() throws {
        let legacyV112JSON = """
        {
          "fps": 60,
          "resolutionCap": "p1080",
          "quality": "balanced",
          "codec": "hevc",
          "bufferDuration": 30,
          "shareCap": 20,
          "outputRootPath": "/tmp/BackbufferV112",
          "saveHotKey": {
            "keyCode": 100,
            "carbonModifiers": 0,
            "displayString": "F8"
          },
          "playSoundOnSave": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CaptureSettings.self, from: legacyV112JSON)
        XCTAssertTrue(decoded.playSoundOnSave)
        XCTAssertEqual(decoded.saveSoundChoice, .medalDoubleChime)
        XCTAssertNil(decoded.customSaveSoundStoredFilename)
        XCTAssertNil(decoded.customSaveSoundOriginalName)
        XCTAssertEqual(decoded.activeSaveSoundLabel, "Medal Double-Chime")

        XCTAssertEqual(SaveSoundChoice.builtInPresets, [.medalDoubleChime, .cameraShutter])
        XCTAssertEqual(SaveSoundChoice.medalDoubleChime.defaultDisplayName, "Medal Double-Chime (Default)")
        XCTAssertEqual(SaveSoundChoice.cameraShutter.defaultDisplayName, "Camera Shutter")
        XCTAssertEqual(SaveSoundChoice.custom.defaultDisplayName, "Custom Sound")

        var customSettings = decoded
        customSettings.saveSoundChoice = .cameraShutter
        XCTAssertEqual(customSettings.activeSaveSoundLabel, "Camera Shutter")

        customSettings.saveSoundChoice = .custom
        XCTAssertEqual(customSettings.activeSaveSoundLabel, "Medal Double-Chime")

        customSettings.customSaveSoundStoredFilename = "custom-cue-12345678.mp3"
        customSettings.customSaveSoundOriginalName = "victory_fanfare.mp3"
        XCTAssertEqual(customSettings.activeSaveSoundLabel, "Custom: victory_fanfare.mp3")

        let encoded = try JSONEncoder().encode(customSettings)
        let roundTripped = try JSONDecoder().decode(CaptureSettings.self, from: encoded)
        XCTAssertEqual(roundTripped, customSettings)
    }

    func testSaveSoundStoreUncappedImportReplacementAndTraversalSafety() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("backbuffer-sound-test-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("Source", isDirectory: true)
        let soundsDir = tempRoot.appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = SaveSoundStore(soundsDirectoryURL: soundsDir)

        // 1. Uncapped import (6 MB file succeeds with zero size limit)
        let largeSourceURL = sourceDir.appendingPathComponent("epic_clip_horn.wav")
        let sixMB = Data(repeating: 0x2A, count: 6 * 1024 * 1024)
        try sixMB.write(to: largeSourceURL)

        let firstImport = try store.importCustomSound(from: largeSourceURL)
        XCTAssertEqual(firstImport.originalFilename, "epic_clip_horn.wav")
        XCTAssertEqual(firstImport.byteSize, Int64(6 * 1024 * 1024))
        XCTAssertTrue(firstImport.storedFilename.hasSuffix(".wav"))
        XCTAssertEqual(store.resolveCustomSoundURL(storedFilename: firstImport.storedFilename), firstImport.storedURL)

        // 2. Importing a second custom sound deletes only the previous Backbuffer copy cleanly
        let secondSourceURL = sourceDir.appendingPathComponent("click.mp3")
        try Data("mp3-stub-payload".utf8).write(to: secondSourceURL)

        let secondImport = try store.importCustomSound(
            from: secondSourceURL,
            replacingStoredFilename: firstImport.storedFilename
        )
        XCTAssertNotEqual(secondImport.storedFilename, firstImport.storedFilename)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstImport.storedURL.path))
        XCTAssertEqual(store.resolveCustomSoundURL(storedFilename: secondImport.storedFilename), secondImport.storedURL)

        // 3. Rejects empty, missing, and directory inputs cleanly
        let emptyURL = sourceDir.appendingPathComponent("empty.wav")
        try Data().write(to: emptyURL)
        XCTAssertThrowsError(try store.importCustomSound(from: emptyURL))
        XCTAssertThrowsError(try store.importCustomSound(from: sourceDir.appendingPathComponent("missing.mp3")))
        XCTAssertThrowsError(try store.importCustomSound(from: sourceDir))

        // 4. External deletion returns nil gracefully
        try FileManager.default.removeItem(at: secondImport.storedURL)
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: secondImport.storedFilename))

        // 5. Blocks path traversal even if target leaf exists inside or above soundsDir
        let sneakyInsideURL = soundsDir.appendingPathComponent("foo")
        try Data("decoy".utf8).write(to: sneakyInsideURL)
        let parentDecoyURL = tempRoot.appendingPathComponent("parent_decoy.wav")
        try Data("parent".utf8).write(to: parentDecoyURL)

        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: "../foo"))
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: "../parent_decoy.wav"))
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: "sub/foo"))
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: "."))
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: ".."))
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: ""))
        XCTAssertNil(store.resolveCustomSoundURL(storedFilename: nil))

        store.removeCustomSound(storedFilename: "../foo")
        store.removeCustomSound(storedFilename: "../parent_decoy.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sneakyInsideURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parentDecoyURL.path))
    }

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readInt16LE(_ data: Data, offset: Int) -> Int16 {
        Int16(bitPattern: readUInt16LE(data, offset: offset))
    }
}
