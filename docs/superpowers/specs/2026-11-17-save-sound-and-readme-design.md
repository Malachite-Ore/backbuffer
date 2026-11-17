# Backbuffer v1.2.0 — Save Sound Effects & README Design Spec

**Date:** 2026-11-17
**Repository:** `Malachite-Ore/backbuffer`
**Local Workspace Path:** `D:\Google Antigravity\Projects\Coding\Backbuffer`
**Target Platform:** macOS 13.0+ (`arm64` + `x86_64` Universal Binary)

---

## 1. Intent & Why

Currently, hitting a global save hotkey (`F8`, `⌃⇧S`, etc.) plays macOS's tiny built-in `NSSound("Tink")` / `NSSound("Basso")` system alert (`AppViewModel.swift:1177-1179`), which routes through the macOS Alert volume channel and is nearly inaudible over game audio on headphones. Without clear audio confirmation, a player either wonders whether the clip saved or presses the hotkey repeatedly and creates duplicate clips.

This `v1.2.0` update replaces the quiet system alert with crisp, unmistakable headphone playback: a default Medal-style save chime, an alternate Camera Shutter preset, a muted failure/empty thud, an optional Finder sound importer with no file-size or duration cap, and a Settings toggle that clearly enables or grays out all sound controls. Alongside it, `README.md` will be rewritten through `/humanizer` so the GitHub landing page reads like a straightforward open-source developer tool rather than AI marketing copy.

---

## 2. Goals, Non-Goals & Anti-Goals

### Goals
1. **Unmistakable Save & Failure Audio Feedback:** Ship built-in **#1 Medal Double-Chime** (default) and **#2 Camera Shutter** for saves, plus a muted low thud when a hotkey press is blocked (Privacy Lock, permission denied, or empty replay buffer).
2. **Master Toggle State Clarity:** Provide a `Sound Effect on Save` toggle in Settings (default `ON`). Turning it `OFF` grays out and disables the preset/custom dropdown, `▶` test button, and `Choose Sound Effect...` button, and silences all save and blocked/empty cues.
3. **Custom Sound Import (Uncapped):** Let the user click `Choose Sound Effect...` to pick a macOS audio file (`.mp3`, `.wav`, `.m4a`, `.aac`, `.caf`, `.aiff`, `.flac`) via Finder (`NSOpenPanel`) and copy it safely into `~/Library/Application Support/Backbuffer/Sounds/`.
4. **Humanized `README.md`:** Rewrite `README.md` without AI prose tells while preserving every factual path, hotkey note, build command, release link, and macOS 13+/TCC troubleshooting step.

### Non-Goals
- Audio trimming, waveform editing, fade curves, or volume-equalizer UI inside Backbuffer.
- Per-game or per-hotkey sound effect profiles.

### Anti-Goals
1. **Never restrict imported file size or duration** (`"I don't wanna restrict him"`).
2. **Never route save/error cues through macOS's quiet Alert sound channel (`NSSound("Tink")`).**
3. **Never leak Backbuffer's save sound into recorded clips:** keep `SCStreamConfiguration.excludesCurrentProcessAudio = true` (`CaptureCoordinator.swift:426`) enforced at all times.
4. **Never leave AI writing patterns in `README.md`:** strip `**Bold label:**` bullet walls, em dashes, forced triads, and promotional hype.

---

## 3. Custom Sound Storage: Approaches Considered & Chosen

| Option | Summary | Trade-Offs | Decision |
|---|---|---|---|
| **A: Store Original File Path Only** | Save the raw filesystem URL in settings without copying the file. | Zero disk duplication, **but** breaks silently if the user clears `~/Downloads`, renames folders, or ejects a drive. | Rejected |
| **B: Uncapped Copy into Application Support** | Copy the chosen audio file into `~/Library/Application Support/Backbuffer/Sounds/` with zero byte or duration cap. | Keeps custom audio reliable after `~/Downloads` cleanup without restricting what the user picks. | **Chosen (Max)** |
| **C: Capped Copy (5 MB / 5s Limit)** | Copy into Application Support but reject files above an arbitrary size/length limit. | Prevents huge imports, **but** needlessly blocks legitimate custom sound clips or songs the user intentionally picks. | Rejected |

---

## 4. Locked Decisions (Confirmed by Max)

1. **Both Built-In Presets Ship Together:** Include **#1 Medal Double-Chime** (active default) and **#2 Camera Shutter** in the sound selector so the user can switch presets immediately without importing anything.
2. **Master Toggle Behavior (`Sound Effect on Save`):** Defaults `ON`. When switched `OFF`, the preset/custom sound selector, `▶` test button, and `Choose Sound Effect...` button all gray out and reject interaction, and neither save nor blocked/empty sounds play.
3. **Custom Sound Picker (`Choose Sound Effect...`):** Opens a standard Finder `NSOpenPanel` filtered to macOS-playable audio formats (`.mp3`, `.wav`, `.m4a`, `.aac`, `.caf`, `.aiff`, `.flac`) and copies the selected file uncapped into `~/Library/Application Support/Backbuffer/Sounds/`.
4. **Blocked / Empty Hotkey Thud:** Pressing the save hotkey while `awaitingAllowedApps` (Privacy Lock), `permissionDenied`, or when the ring buffer is empty plays a short muted low thud (only when `Sound Effect on Save` is `ON`).
5. **`README.md` Humanization:** Rewrite `README.md` using `/humanizer` as plain, direct tool documentation while keeping every real repository path, build command (`swift test`, `./scripts/package_app.sh`), release URL, and macOS TCC instruction accurate.

---

## 5. Implementation Proposals (Pending Max's Sign-Off)

The items below were not specified word-for-word during brainstorming and are proposed for sign-off before coding begins:

### Proposal 1 — Main-Output `AVAudioPlayer` + Core-Synthesized `48 kHz` WAV Cues
- **Proposal:** Play all save, preview, and error cues through `AVAudioPlayer` on the user's normal system output device (at full main/headphone volume rather than macOS's Alert channel), keeping `excludesCurrentProcessAudio = true` so ScreenCaptureKit never captures it. Generate the three built-in cues deterministically in `BackbufferCore` as `48 kHz` PCM WAV `Data` (testable headlessly on CI without audio hardware):
  - `#1 Medal Double-Chime`: `180 ms` bright two-note chime (`C6` → `G6`).
  - `#2 Camera Shutter`: `120 ms` dual crisp filtered shutter transient.
  - `Blocked / Empty Thud`: `110 ms` muted low thud (`~95 Hz` damped pulse).
- **Alternatives:** Bundling static `.wav` files in `Package.swift` resources (adds bundle resource lookup failure modes across SwiftPM vs `.app`), or continuing with `NSSound(named:)` (subject to muted Alert channel volume).

### Proposal 2 — Single Custom Slot Replacement & Graceful Fallback
- **Proposal:** Keep a single active custom sound slot inside `~/Library/Application Support/Backbuffer/Sounds/` (`custom.<ext>` or `<sanitized-original-name>`), deleting only the *previous* Backbuffer-managed copy whenever a new file is imported, and showing `Custom: <original-filename>` in the Settings dropdown alongside the two built-in presets. If the copied file is later deleted externally or fails to decode in `AVAudioPlayer`, log/surface a non-blocking warning toast and fall back automatically to **#1 Medal Double-Chime** so saves never go silent.
- **Alternatives:** Keeping every previously imported file forever (accumulates orphaned files in Application Support on experimentation), or silently doing nothing if a custom file becomes unreadable.

### Proposal 3 — Compact `▶` Test Button & Card Layout Placement
- **Proposal:** Upgrade the existing **Hotkeys** sound row in **Settings → Shortcuts & Mic** into a clean grouped control: `Sound Effect on Save` toggle on the top row, followed directly underneath by the sound selector (`#1 Medal Double-Chime`, `#2 Camera Shutter`, and `Custom: <filename>` if set), a compact `▶` Test button (plays the currently selected preset or imported sound without saving a dummy clip), and `Choose Sound Effect...`. All three secondary controls use `.disabled(!soundEnabled)` + muted opacity when `Sound Effect on Save` is `OFF`.
- **Alternatives:** Placing sound controls in a separate card or requiring a live clip save to hear changes.
