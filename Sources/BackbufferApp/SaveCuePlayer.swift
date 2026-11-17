import AVFoundation
import BackbufferCore
import Foundation

enum SaveCuePlayOutcome: Equatable, Sendable {
    case skippedDisabled
    case playedBuiltIn(BuiltInCueKind)
    case playedCustom(String)
    case fellBackToDefault(reason: String)
}

@MainActor
final class SaveCuePlayer {
    private var activePlayer: AVAudioPlayer?
    private let cachedBuiltInWAV: [BuiltInCueKind: Data]

    init() {
        var cache: [BuiltInCueKind: Data] = [:]
        for kind in BuiltInCueKind.allCases {
            cache[kind] = SaveSoundCueLibrary.wavData(for: kind)
        }
        self.cachedBuiltInWAV = cache
    }

    @discardableResult
    func playSaveConfirmation(
        settings: CaptureSettings,
        soundStore: SaveSoundStore
    ) -> SaveCuePlayOutcome {
        guard settings.playSoundOnSave else {
            stop()
            return .skippedDisabled
        }
        return playConfiguredSaveSound(settings: settings, soundStore: soundStore)
    }

    @discardableResult
    func previewSelectedSound(
        settings: CaptureSettings,
        soundStore: SaveSoundStore
    ) -> SaveCuePlayOutcome {
        guard settings.playSoundOnSave else {
            stop()
            return .skippedDisabled
        }
        return playConfiguredSaveSound(settings: settings, soundStore: soundStore)
    }

    @discardableResult
    func playBlockedOrEmptyCue(settings: CaptureSettings) -> SaveCuePlayOutcome {
        guard settings.playSoundOnSave else {
            stop()
            return .skippedDisabled
        }
        playBuiltInWAV(.blockedThud, volume: 0.72)
        return .playedBuiltIn(.blockedThud)
    }

    func stop() {
        activePlayer?.stop()
        activePlayer = nil
    }

    private func playConfiguredSaveSound(
        settings: CaptureSettings,
        soundStore: SaveSoundStore
    ) -> SaveCuePlayOutcome {
        switch settings.saveSoundChoice {
        case .medalDoubleChime:
            playBuiltInWAV(.medalDoubleChime, volume: 0.85)
            return .playedBuiltIn(.medalDoubleChime)

        case .cameraShutter:
            playBuiltInWAV(.cameraShutter, volume: 0.85)
            return .playedBuiltIn(.cameraShutter)

        case .custom:
            guard let customURL = soundStore.resolveCustomSoundURL(
                storedFilename: settings.customSaveSoundStoredFilename
            ) else {
                playBuiltInWAV(.medalDoubleChime, volume: 0.85)
                return .fellBackToDefault(reason: "Custom save sound file was not found.")
            }

            do {
                activePlayer?.stop()
                activePlayer = nil

                let player = try AVAudioPlayer(contentsOf: customURL)
                player.volume = 0.9
                player.prepareToPlay()
                _ = player.play()
                activePlayer = player

                let trimmedName = settings.customSaveSoundOriginalName?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = (trimmedName?.isEmpty == false ? trimmedName : nil) ?? customURL.lastPathComponent
                return .playedCustom(label)
            } catch {
                playBuiltInWAV(.medalDoubleChime, volume: 0.85)
                return .fellBackToDefault(reason: "Custom save sound could not be played: \(error.localizedDescription)")
            }
        }
    }

    private func playBuiltInWAV(_ kind: BuiltInCueKind, volume: Float) {
        let data = cachedBuiltInWAV[kind] ?? SaveSoundCueLibrary.wavData(for: kind)
        activePlayer?.stop()
        activePlayer = nil

        if let player = try? AVAudioPlayer(data: data) {
            player.volume = volume
            player.prepareToPlay()
            _ = player.play()
            activePlayer = player
        }
    }
}
