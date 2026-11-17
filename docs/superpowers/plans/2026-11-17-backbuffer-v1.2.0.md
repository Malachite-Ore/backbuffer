# Backbuffer v1.2.0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace macOS's quiet `NSSound("Tink"/"Basso")` alert cues with clear headphone save/failure audio (built-in `#1 Medal Double-Chime`, `#2 Camera Shutter`, muted blocked/empty thud, uncapped custom sound import), add grouped sound settings UI with `▶` preview, and rewrite `README.md` cleanly via `/humanizer`.

**Architecture:** `BackbufferCore` synthesizes deterministic `48 kHz` stereo PCM WAV payloads and manages uncapped custom imports in `~/Library/Application Support/Backbuffer/Sounds/`. `BackbufferApp` plays audio via `AVAudioPlayer` on the main output route while `SCStreamConfiguration.excludesCurrentProcessAudio = true` prevents feedback loops into saved clips.

**Tech Stack:** Swift 5.9+, `Foundation`, `AVFoundation`, `UniformTypeIdentifiers`, `AppKit`, `SwiftUI`, `XCTest`

**Spec:** [2026-11-17-save-sound-and-readme-design.md](../specs/2026-11-17-save-sound-and-readme-design.md)

## Global Constraints

- Minimum platform: `.macOS(.v13)` Universal Binary (`arm64` + `x86_64`), Swift `5.9+`, zero compiler warnings on Xcode `16.4` / Swift `6.1.2`.
- Never restrict imported custom sound file size or duration (`Option B`).
- Never use `NSSound("Tink")` / `NSSound("Basso")` Alert-channel playback for save/failure cues.
- Keep `SCStreamConfiguration.excludesCurrentProcessAudio = true` in `CaptureCoordinator.swift`.
- `README.md` prose must contain zero AI tells (no prose em/en dashes `—`/`–`, no promotional bullet-wall boilerplate) while preserving every technical command, path, URL, and TCC instruction.
- File ownership: Task 1 (`@foundation`), Task 2 (`@capture-input`), Task 3 (`@app-ui`), Task 4 (`@media-engine`).

## Review Focus

- Legacy `v1.0.x` / `v1.1.x` `CaptureSettings` JSON payloads missing `saveSoundChoice` must decode without error and default to `.medalDoubleChime` with `playSoundOnSave == true` (pinned in Task 1).
- Deleting or corrupting a previously imported custom sound file on disk must never crash or silence clip saves; `SaveCuePlayer` must fall back to `.medalDoubleChime` and surface a warning toast (pinned in Task 1 & Task 2).
- Large multi-megabyte custom audio imports must succeed without cap while replacing only the previous Backbuffer-managed file and rejecting path traversal (`../`) or empty files (pinned in Task 1).
- Missing audio hardware on headless CI must never break tests or audio playback; WAV tests validate headers and `AVAudioPlayer(data:)` metadata without asserting `.play()` on CI (pinned in Task 1).
- Turning `Sound Effect on Save` `OFF` must gray out and disable the sound selector, `▶` Test button, and `Choose Sound Effect...` button, stop active playback, and silence both save and blocked/empty cues (pinned in Task 2 & Task 3).

---

### Task 1: Core Sound Models, WAV Synthesis & Uncapped Sound Store (`@foundation`)

**Files:**
- Modify: `Sources/BackbufferCore/Models.swift`
- Create: `Sources/BackbufferCore/SaveSoundCueLibrary.swift`
- Test: `Tests/BackbufferCoreTests/SaveSoundCueTests.swift`

**Interfaces:**
- Consumes: `CaptureSettings`, `BackbufferError` in `Sources/BackbufferCore/Models.swift`.
- Produces:
  - `SaveSoundChoice` (`case medalDoubleChime, cameraShutter, custom`, `builtInPresets`, `defaultDisplayName`)
  - `CaptureSettings.saveSoundChoice`, `.customSaveSoundStoredFilename`, `.customSaveSoundOriginalName`, `.activeSaveSoundLabel`
  - `BuiltInCueKind` (`case medalDoubleChime, cameraShutter, blockedThud`)
  - `SaveSoundCueLibrary.sampleRate: Int`, `.wavData(for kind: BuiltInCueKind) -> Data`
  - `ImportedSaveSound` (`storedFilename`, `originalFilename`, `storedURL`, `byteSize`)
  - `SaveSoundStore` (`supportedExtensions`, `soundsDirectoryURL`, `init(soundsDirectoryURL: URL? = nil)`, `importCustomSound(from:replacingStoredFilename:) throws -> ImportedSaveSound`, `resolveCustomSoundURL(storedFilename:) -> URL?`, `removeCustomSound(storedFilename:)`)

- [ ] **Step 1: Write unit tests in `Tests/BackbufferCoreTests/SaveSoundCueTests.swift`**

Verify all 3 `BuiltInCueKind` WAV outputs (`RIFF`/`WAVE` 44-byte header, non-zero peak, `AVAudioPlayer(data:)` `numberOfChannels == 2` and `duration > 0.08`), backwards-compatible `CaptureSettings` decode + `activeSaveSoundLabel`, uncapped `6 MB` custom import + old-file replacement, empty/missing rejection, deleted-file `nil`, and `../foo` path traversal rejection.

- [ ] **Step 2: Run targeted tests on macOS CI / local SwiftPM to confirm pre-implementation failure**

Run: `swift test --filter SaveSoundCueTests`
Expected: FAIL before `SaveSoundChoice` / `SaveSoundCueLibrary` exist.

- [ ] **Step 3: Add `SaveSoundChoice` and new settings fields to `Sources/BackbufferCore/Models.swift`**

Keep all 19 existing properties, `CodingKeys`, memberwise parameter defaults, and `decodeIfPresent` backward compatibility while adding `saveSoundChoice`, `customSaveSoundStoredFilename`, `customSaveSoundOriginalName`, and `activeSaveSoundLabel`.

- [ ] **Step 4: Create `Sources/BackbufferCore/SaveSoundCueLibrary.swift`**

Synthesize deterministic `48 kHz` stereo 16-bit PCM RIFF WAVE buffers for `.medalDoubleChime`, `.cameraShutter`, and `.blockedThud`, and implement `SaveSoundStore` (`Option B`: copy new file into `soundsDirectoryURL` first, then remove sanitized previous file, zero byte/duration cap).

- [ ] **Step 5: Run `swift test --filter SaveSoundCueTests`**

Expected: PASS (all cases green, 0 compiler warnings).

---

### Task 2: Main-Output AVAudioPlayer Wrapper (`@capture-input`)

**Files:**
- Create: `Sources/BackbufferApp/SaveCuePlayer.swift`

**Interfaces:**
- Consumes: `SaveSoundChoice`, `CaptureSettings`, `BuiltInCueKind`, `SaveSoundCueLibrary`, `SaveSoundStore`.
- Produces:
  - `SaveCuePlayOutcome` (`case skippedDisabled, playedBuiltIn(BuiltInCueKind), playedCustom(String), fellBackToDefault(reason: String)`)
  - `@MainActor final class SaveCuePlayer` (`playSaveConfirmation`, `previewSelectedSound`, `playBlockedOrEmptyCue`, `stop`)

- [ ] **Step 1: Implement `SaveCuePlayer.swift` in `Sources/BackbufferApp/SaveCuePlayer.swift`**

Pre-cache the 3 built-in WAV buffers, retain `activePlayer: AVAudioPlayer?` strongly, respect `!settings.playSoundOnSave` (stopping active playback and returning `.skippedDisabled`), play custom files from `SaveSoundStore.resolveCustomSoundURL`, and fall back to `.medalDoubleChime` (`fellBackToDefault`) whenever a custom file is missing or fails to decode.

- [ ] **Step 2: Build `BackbufferApp` on macOS**

Run: `swift build`
Expected: Compiles cleanly with `0` warnings on Xcode `16.4` / Swift `6.1.2`.

---

### Task 3: Settings Grouped Sound UI, Finder Importer & Blocked/Save Wiring (`@app-ui`)

**Files:**
- Modify: `Sources/BackbufferApp/AppViewModel.swift`
- Modify: `Sources/BackbufferApp/SettingsWindowView.swift`
- Modify: `Sources/BackbufferApp/PreviewRenderer.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: `SaveSoundChoice`, `SaveSoundStore`, `SaveCuePlayer`, `SaveCuePlayOutcome`.
- Produces: `AppViewModel.selectSaveSoundChoice(_:)`, `.previewSaveSound()`, `.chooseCustomSaveSoundFile()`, updated `hotkeysConsoleCard`, `v1.2.0` (`CFBundleVersion` `7`) metadata, and expanded `shortcuts_mic_preview.png`.

- [ ] **Step 1: Replace `NSSound("Tink"/"Basso")` in `Sources/BackbufferApp/AppViewModel.swift`**

Own `SaveSoundStore()` and `SaveCuePlayer()`, trigger `playBlockedOrEmptyCue` on Privacy Lock / permission-denied / save error, trigger `playSaveConfirmation` with `.fellBackToDefault` toast on save success, wire `selectSaveSoundChoice`, `previewSaveSound`, and `chooseCustomSaveSoundFile` (`NSOpenPanel` + `UTType`), and clean up custom sound files on `resetSettingsToDefault()`.

- [ ] **Step 2: Update `hotkeysConsoleCard` in `Sources/BackbufferApp/SettingsWindowView.swift`**

Render Row 1 (`Sound Effect on Save` switch) and Row 2 (`Clip Sound` Menu selector + compact `▶ Test` button + `Choose Sound Effect...`), dimmed and disabled via `.disabled(!viewModel.settings.playSoundOnSave)` and `.opacity(viewModel.settings.playSoundOnSave ? 1.0 : 0.42)` when toggled off.

- [ ] **Step 3: Bump version & preview geometry in `PreviewRenderer.swift` and `Resources/Info.plist`**

Update `CFBundleShortVersionString` -> `1.2.0`, `CFBundleVersion` -> `7`, chrome badge -> `"v1.2.0"`, and `shortcuts_mic_preview.png` frame height (`648` inside `780 x 686`) so zero controls clip.

- [ ] **Step 4: Run tests, universal build & headless preview render**

Run: `swift test && swift build -c release --arch arm64 --arch x86_64 && .build/apple/Products/Release/BackbufferApp --render-previews ci-output/previews`
Expected: All XCTests pass (`0` warnings) and all 7 `2x` preview PNGs render cleanly.

---

### Task 4: Humanized `README.md` Rewrite (`@media-engine`)

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: `docs/superpowers/specs/2026-11-17-save-sound-and-readme-design.md`, `README.md`, `humanizer` skill rules.

- [ ] **Step 1: Rewrite `README.md` cleanly using `/humanizer` rules**

Document `v1.2.0` capabilities (RAM replay ring buffer, strict allowlist + `Minecraft (java)` vs `TLauncher`, fullscreen Spaces, mic commentary/stems, Carbon hotkeys, Save Sound Effect options, GitHub Releases DMG, Gatekeeper & TCC commands, source build commands) while stripping all em/en dashes in prose, promotional bullet prefixes, forced triads, and AI copy tells.

- [ ] **Step 2: Audit `README.md` prose & verify full `v1.2.0` release**

Confirm zero prose `—`/`–` characters remain, then verify full `macos-15` CI, all 7 Retina PNGs, and `Backbuffer-Universal.dmg` on GitHub Release `v1.2.0`.
