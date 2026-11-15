# Backbuffer

**Free, watermark-free, subscription-free instant-replay gameplay clipper for macOS 13.0+ (Intel & Apple Silicon).**

Backbuffer continuously buffers your gameplay in RAM using macOS's native GPU hardware encoder (`ScreenCaptureKit` + `VideoToolbox`), saves untouched master clips on a single hotkey (`⌥⌘S`), and keeps optional Discord-sized share copies neatly paired alongside your masters — with zero watermarks, zero accounts, zero paywalls, and zero background SSD wear while you play.

## Why Backbuffer?

- **Zero watermarks, zero subscriptions:** Full-resolution 1080p/Native 60 FPS clips with clean audio.
- **No background disk thrashing:** Video (`HEVC` / `H.264`) and system audio stay inside a bounded RAM ring buffer until you hit Save.
- **Non-destructive `Masters/` + `Shared/` storage:**
  - Untouched original hardware-encoded clips live in `~/Movies/Backbuffer/Masters/` for DaVinci Resolve, Premiere Pro, or CapCut.
  - When a clip exceeds your Share Cap (`10 MB`, `20 MB Discord Free`, or `50 MB`), a compressed companion is saved in `~/Movies/Backbuffer/Shared/` without ever altering your master.
- **CFR Keepalive for NLEs:** Repeats static menu/lobby frames cleanly so editors never choke on variable-frame-rate gaps.
- **Built-in Library & Quick Trimmer:** Scrub with an interactive filmstrip, export lossless master trims, or copy a Discord-sized clip straight to your clipboard (`Cmd+V`).
- **Privacy-friendly global hotkeys:** Uses macOS Carbon `RegisterEventHotKey` — no Accessibility or keylogger permissions required.

## Installation (macOS 13 Ventura or later)

1. Download **`Backbuffer-Universal.dmg`** from [GitHub Releases](https://github.com/Malachite-Ore/backbuffer/releases).
2. Open the `.dmg` and drag **`Backbuffer.app`** into **`Applications`** (or let the first-launch helper below copy it automatically).
3. **First Launch (Gatekeeper Note):** Because Backbuffer is free open-source software signed with an ad-hoc certificate (no paid Apple Developer ID), macOS Gatekeeper will ask to confirm on first launch:
   - **Easiest:** Double-click **`Open First Time (Bypass Gatekeeper).command`** inside the `.dmg` — it stops any older background instance, installs `Backbuffer.app` into `/Applications`, clears the quarantine flag, and launches the app window.
   - **Or manually:** Right-click (Control-click) **`Backbuffer.app`** in `Applications` → choose **Open** → click **Open**. On macOS Sequoia (15+) / Tahoe (26+), if macOS blocks opening directly, go to **System Settings → Privacy & Security**, scroll to **Backbuffer**, and click **Open Anyway**.
4. Backbuffer opens straight into the **Clip Library & Live Capture** window, shows in your **Dock** and **Menu Bar**, and keeps buffering in RAM in the background even when you close the window (`⌘W`).
5. Grant **Screen Recording** permission when prompted so Backbuffer can capture your display or game window.

## Building from Source

Requires macOS 13+ with Xcode 15+ (Swift 5.9+).

```bash
# Run headless unit & media pipeline tests (no Screen Recording TCC prompt needed)
swift test

# Build Universal Binary (arm64 + x86_64), Backbuffer.app, and Backbuffer-Universal.dmg
chmod +x scripts/package_app.sh
./scripts/package_app.sh
```

The packaged app bundle and disk image are emitted to `dist/Backbuffer.app` and `dist/Backbuffer-Universal.dmg`.
