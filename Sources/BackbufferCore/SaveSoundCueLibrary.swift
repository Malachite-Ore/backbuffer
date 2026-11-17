import Foundation

public enum BuiltInCueKind: String, CaseIterable, Sendable {
    case medalDoubleChime
    case cameraShutter
    case blockedThud
}

public enum SaveSoundCueLibrary {
    public static let sampleRate: Int = 48_000

    public static func wavData(for kind: BuiltInCueKind) -> Data {
        let samples = synthesizeSamples(for: kind)
        return encodeStereoWAV(monoSamples: samples, sampleRate: sampleRate)
    }

    private static func synthesizeSamples(for kind: BuiltInCueKind) -> [Int16] {
        let sr = Double(sampleRate)
        switch kind {
        case .medalDoubleChime:
            let totalFrames = Int((0.210 * sr).rounded())
            var buffer = [Int16](repeating: 0, count: totalFrames)
            for i in 0..<totalFrames {
                let t = Double(i) / sr
                var sample = 0.0

                // C6 bright chime at t = 0.0s
                if t >= 0.0 && t <= 0.115 {
                    let attack = min(1.0, t / 0.004)
                    let decay = exp(-t / 0.036)
                    let env = attack * decay
                    let fund = triangleWave(phase: 1046.50 * t)
                    let harmonic = sin(2.0 * .pi * 2093.00 * t)
                    sample += (0.42 * fund + 0.22 * harmonic) * env
                }

                // G6 crisp lift at t = 0.065s
                let t2 = t - 0.065
                if t2 >= 0.0 {
                    let attack = min(1.0, t2 / 0.004)
                    let decay = exp(-t2 / 0.044)
                    let tailFade = t > 0.204 ? max(0.0, (0.210 - t) / 0.006) : 1.0
                    let env = attack * decay * tailFade
                    let fund = triangleWave(phase: 1567.98 * t2)
                    let harmonic = sin(2.0 * .pi * 3135.96 * t2)
                    sample += (0.48 * fund + 0.25 * harmonic) * env
                }

                let clamped = max(-0.92, min(0.92, sample))
                buffer[i] = Int16((clamped * 32767.0).rounded())
            }
            return buffer

        case .cameraShutter:
            let totalFrames = Int((0.125 * sr).rounded())
            var buffer = [Int16](repeating: 0, count: totalFrames)
            var rng: UInt64 = 0x5348_5554_5445_5201
            var prevWhite = 0.0
            var hpState = 0.0
            var bpState = 0.0
            var phase1 = 0.0
            var phase2 = 0.0
            var pingPhase = 0.0

            for i in 0..<totalFrames {
                let t = Double(i) / sr
                rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Double((rng >> 11) & 0x1FFFFF) / Double(0x1FFFFF)
                let white = unit * 2.0 - 1.0
                hpState = 0.86 * (hpState + white - prevWhite)
                prevWhite = white
                bpState += 0.34 * (hpState - bpState)

                var sample = 0.0

                // Shutter blade release at t = 0.0s
                if t < 0.038 {
                    let progress = min(1.0, t / 0.038)
                    let freq = 220.0 - 145.0 * progress
                    phase1 += freq / sr
                    let attack = min(1.0, t / 0.0015)
                    let bodyEnv = attack * exp(-t / 0.011)
                    let noiseEnv = attack * exp(-t / 0.008)
                    sample += 0.48 * sin(2.0 * .pi * phase1) * bodyEnv
                    sample += 0.42 * bpState * noiseEnv
                }

                // Shutter return snap at t = 0.042s
                let t2 = t - 0.042
                if t2 >= 0.0 {
                    let progress = min(1.0, t2 / 0.070)
                    let freq = 340.0 - 230.0 * progress
                    phase2 += freq / sr
                    pingPhase += 2400.0 / sr
                    let attack = min(1.0, t2 / 0.0015)
                    let bodyEnv = attack * exp(-t2 / 0.014)
                    let noiseEnv = attack * exp(-t2 / 0.010)
                    let pingEnv = attack * exp(-t2 / 0.006)
                    let tailFade = t > 0.120 ? max(0.0, (0.125 - t) / 0.005) : 1.0
                    sample += (0.45 * sin(2.0 * .pi * phase2) * bodyEnv
                        + 0.46 * bpState * noiseEnv
                        + 0.22 * sin(2.0 * .pi * pingPhase) * pingEnv) * tailFade
                }

                let clamped = max(-0.92, min(0.92, sample))
                buffer[i] = Int16((clamped * 32767.0).rounded())
            }
            return buffer

        case .blockedThud:
            let totalFrames = Int((0.125 * sr).rounded())
            var buffer = [Int16](repeating: 0, count: totalFrames)
            var phase1 = 0.0
            var phase2 = 0.0

            for i in 0..<totalFrames {
                let t = Double(i) / sr
                var sample = 0.0

                // Soft muted pulse 1: 135 Hz -> 68 Hz
                if t < 0.046 {
                    let freq = 135.0 - 67.0 * min(1.0, t / 0.046)
                    phase1 += freq / sr
                    let attack = min(1.0, t / 0.004)
                    let env = attack * exp(-t / 0.016)
                    sample += 0.34 * sin(2.0 * .pi * phase1) * env
                }

                // Soft muted pulse 2: 98 Hz -> 55 Hz
                let t2 = t - 0.048
                if t2 >= 0.0 {
                    let freq = 98.0 - 43.0 * min(1.0, t2 / 0.072)
                    phase2 += freq / sr
                    let attack = min(1.0, t2 / 0.004)
                    let env = attack * exp(-t2 / 0.022)
                    let tailFade = t > 0.120 ? max(0.0, (0.125 - t) / 0.005) : 1.0
                    sample += 0.38 * sin(2.0 * .pi * phase2) * env * tailFade
                }

                let clamped = max(-0.85, min(0.85, sample))
                buffer[i] = Int16((clamped * 32767.0).rounded())
            }
            return buffer
        }
    }

    private static func triangleWave(phase: Double) -> Double {
        let wrapped = phase - floor(phase)
        return 1.0 - 4.0 * abs(wrapped - 0.5)
    }

    private static func encodeStereoWAV(monoSamples: [Int16], sampleRate: Int) -> Data {
        let channels: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataByteCount = UInt32(monoSamples.count * Int(blockAlign))
        let riffChunkSize = UInt32(36) + dataByteCount

        var data = Data()
        data.reserveCapacity(44 + Int(dataByteCount))

        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLittleEndian(riffChunkSize, to: &data)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLittleEndian(UInt32(16), to: &data)          // PCM subchunk size
        appendLittleEndian(UInt16(1), to: &data)           // AudioFormat = 1 (PCM)
        appendLittleEndian(channels, to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLittleEndian(dataByteCount, to: &data)

        for sample in monoSamples {
            appendLittleEndian(sample, to: &data)
            appendLittleEndian(sample, to: &data)
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

public struct ImportedSaveSound: Equatable, Sendable {
    public let storedFilename: String
    public let originalFilename: String
    public let storedURL: URL
    public let byteSize: Int64

    public init(
        storedFilename: String,
        originalFilename: String,
        storedURL: URL,
        byteSize: Int64
    ) {
        self.storedFilename = storedFilename
        self.originalFilename = originalFilename
        self.storedURL = storedURL
        self.byteSize = byteSize
    }
}

public final class SaveSoundStore: @unchecked Sendable {
    public static let supportedExtensions: [String] = [
        "mp3", "wav", "m4a", "aac", "caf", "aiff", "aif", "flac"
    ]

    public let soundsDirectoryURL: URL
    private let lock = NSLock()

    public init(soundsDirectoryURL: URL? = nil) {
        if let soundsDirectoryURL {
            self.soundsDirectoryURL = soundsDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            self.soundsDirectoryURL = appSupport
                .appendingPathComponent("Backbuffer", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
        }
    }

    public func importCustomSound(
        from sourceURL: URL,
        replacingStoredFilename previousFilename: String? = nil
    ) throws -> ImportedSaveSound {
        guard sourceURL.isFileURL else {
            throw BackbufferError.libraryIOFailed("Selected custom sound is not a local file URL.")
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw BackbufferError.libraryIOFailed("Selected sound file could not be found at \(sourceURL.path).")
        }

        let sourceAttributes: [FileAttributeKey: Any]
        do {
            sourceAttributes = try fm.attributesOfItem(atPath: sourceURL.path)
        } catch {
            throw BackbufferError.libraryIOFailed("Could not inspect sound file attributes: \(error.localizedDescription)")
        }

        let sourceByteSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? 0
        guard sourceByteSize > 0 else {
            throw BackbufferError.libraryIOFailed("Selected sound file is empty (0 bytes).")
        }

        let sanitizedExtScalars = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .filter { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }
        let ext = sanitizedExtScalars.isEmpty ? "dat" : String(String.UnicodeScalarView(sanitizedExtScalars))
        let storedFilename = "custom-cue-\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
        let destinationURL = soundsDirectoryURL.appendingPathComponent(storedFilename, isDirectory: false)

        lock.lock()
        defer { lock.unlock() }

        do {
            try fm.createDirectory(at: soundsDirectoryURL, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BackbufferError.libraryIOFailed("Failed to import custom sound effect: \(error.localizedDescription)")
        }

        if let prevName = Self.sanitizedSingleFilename(previousFilename), prevName != storedFilename {
            let previousURL = soundsDirectoryURL.appendingPathComponent(prevName, isDirectory: false)
            if fm.fileExists(atPath: previousURL.path) {
                try? fm.removeItem(at: previousURL)
            }
        }

        let copiedBytes = ((try? fm.attributesOfItem(atPath: destinationURL.path))?[.size] as? NSNumber)?.int64Value
            ?? sourceByteSize

        return ImportedSaveSound(
            storedFilename: storedFilename,
            originalFilename: sourceURL.lastPathComponent,
            storedURL: destinationURL,
            byteSize: copiedBytes
        )
    }

    public func resolveCustomSoundURL(storedFilename: String?) -> URL? {
        guard let name = Self.sanitizedSingleFilename(storedFilename) else {
            return nil
        }

        let candidateURL = soundsDirectoryURL.appendingPathComponent(name, isDirectory: false)
        let resolvedParent = candidateURL.standardizedFileURL.deletingLastPathComponent()
        let baseDir = soundsDirectoryURL.standardizedFileURL
        guard resolvedParent.path == baseDir.path else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        return candidateURL
    }

    public func removeCustomSound(storedFilename: String?) {
        guard let name = Self.sanitizedSingleFilename(storedFilename) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }

        let targetURL = soundsDirectoryURL.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try? FileManager.default.removeItem(at: targetURL)
        }
    }

    private static func sanitizedSingleFilename(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("..") else {
            return nil
        }
        let leaf = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !leaf.isEmpty, leaf == trimmed, leaf != ".", leaf != ".." else {
            return nil
        }
        return leaf
    }
}
