# Backbuffer

An instant replay gameplay clipper for macOS 13.0 Ventura or later (Intel and Apple Silicon `arm64`).

Backbuffer runs in the background and holds recent gameplay video and audio in a bounded RAM ring buffer using `ScreenCaptureKit` and `VideoToolbox` hardware encoding (`HEVC` or `H.264`). Your SSD stays idle until you hit a hotkey to save. It is free and open source, adds no watermarks, and requires no account.

## How it works

While buffering, video and audio stay in memory. When you save a clip, Backbuffer writes the original hardware-encoded recording to `~/Movies/Backbuffer/Masters/`. If that master file is bigger than your Share Cap (`10 MB`, `20 MB Discord Free`, or `50 MB`), a compressed copy is saved to `~/Movies/Backbuffer/Shared/` while your master stays untouched.

Static menus and loading screens are padded at a constant frame rate so editors like DaVinci Resolve, Premiere Pro, Final Cut Pro, and CapCut do not hit variable-frame-rate drift. Inside the app, the Clip Library and Quick Trimmer let you scrub with a filmstrip, export lossless trims from a master, or copy a Discord-sized clip to your clipboard with `Cmd+V`.

## Privacy, audio, and hotkeys

New installs start in Strict Allowlist mode under **Settings > Allowed Apps**, so Backbuffer records nothing until you pick what to capture. You can also click Allow Running or switch to blocklist mode if you want to record everything except specific apps. Shared Java runtimes are split apart so `Minecraft (java)` (or raw `java`) appears separately from launchers like `TLauncher`, and games running fullscreen in their own macOS Spaces remain capturable.

Optional microphone capture handles native macOS inputs (mono, 44.1 kHz, 24-bit USB interfaces, and Bluetooth headsets) with a live VU meter and 0% to 200% gain control in **Settings > Shortcuts & Mic**. Your voice mixes into Track 1 so clips work straight away in QuickTime, Discord, and Safari. Turn on separate stems if you also want isolated `Game Audio` and `Microphone` tracks inside your master file; those stems are marked disabled by default so regular players do not hear double audio while editors can unmute them in Resolve, Premiere, or Final Cut Pro.

Global hotkeys use Carbon `GetEventDispatcherTarget()` so `⌃⇧S`, standalone function keys like `F8` and `F9` (`F1` through `F20`), and custom combinations work over fullscreen games without Accessibility or Input Monitoring prompts. When **Sound Effect on Save** is enabled, Backbuffer plays audio feedback over your main output device without letting it leak into recorded clips:

- `#1 Medal Double-Chime` (default) or `#2 Camera Shutter` plays when a clip saves
- A muted low thud plays when a save press is blocked by Privacy Lock, missing Screen Recording permission, or an empty buffer
- `Choose Sound Effect...` lets you pick any macOS audio file (`.mp3`, `.wav`, `.m4a`, `.aac`, `.caf`, `.aiff`, or `.flac`) with no size or duration limit and copies it into `~/Library/Application Support/Backbuffer/Sounds/`

Turning **Sound Effect on Save** off grays out the sound controls in Settings and mutes all save and error cues.

## Installation

1. Download `Backbuffer-Universal.dmg` from [GitHub Releases](https://github.com/Malachite-Ore/backbuffer/releases).
2. Open the `.dmg` and drag `Backbuffer.app` into `/Applications`. Do not run the app directly from the mounted disk image or `Downloads/`, as macOS can reject or lose Screen Recording permissions from those locations.
3. On first launch or after updating, double-click `Open First Time (Bypass Gatekeeper).command` inside the `.dmg`. Because Backbuffer uses an ad-hoc signature without a paid Apple Developer ID, macOS ties permissions to each build's signature. That script stops any running older copy, installs `Backbuffer.app` into `/Applications`, removes quarantine flags, clears outdated Screen Recording and Microphone TCC entries when the app version changes, and launches the app.
   If you prefer to open the app manually, Control-click `Backbuffer.app` in `/Applications`, choose **Open**, and confirm. On macOS Sequoia (15+) and Tahoe (26+), open **System Settings > Privacy & Security**, scroll down to Backbuffer, and click **Open Anyway**.
4. Backbuffer opens to the Clip Library and Live Capture window and appears in your Dock and Menu Bar. Closing the window (`⌘W`) keeps RAM buffering running in the background.
5. Grant **Screen Recording** permission and allow your games or apps under **Settings > Allowed Apps** to begin buffering. Grant **Microphone** permission under **Settings > Shortcuts & Mic** if you want voice commentary captured.

## Permissions and upgrades

- If an update leaves you stuck on "Screen Recording Permission Needed", click `Check & Relaunch` inside the banner once Backbuffer is switched on under **System Settings > Privacy & Security > Screen Recording**, or click `Fix Updated App` to reset the old signature and re-prompt. You can also run `Fix Stuck Screen Recording Permission.command` from `Backbuffer-Universal.dmg`, which resets both `ScreenCapture` and `Microphone` TCC entries for `io.malachiteore.backbuffer` and relaunches `/Applications/Backbuffer.app`.
- Remember to allow `Minecraft (java)` under **Settings > Allowed Apps**, even if you already allowed `TLauncher`.
- If macOS grants Microphone access after an update but the live VU meter sits flat at zero, open **Settings > Shortcuts & Mic** and click `Fix Mic Permission` to reset the stale mic entry and relaunch.

## Building from source

Requires macOS 13+ with Xcode 15+ (Swift 5.9+).

```bash
# Run headless unit & media pipeline tests (no Screen Recording TCC prompt needed)
swift test

# Build Universal Binary (arm64 + x86_64), Backbuffer.app, and Backbuffer-Universal.dmg
chmod +x scripts/package_app.sh
./scripts/package_app.sh
```

The packaged app bundle and disk image are emitted to `dist/Backbuffer.app` and `dist/Backbuffer-Universal.dmg`.
