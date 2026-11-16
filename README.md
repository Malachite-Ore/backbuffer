# Backbuffer

**Free, watermark-free, subscription-free instant-replay gameplay clipper for macOS 13.0+ (Intel & Apple Silicon).**

Backbuffer continuously buffers your gameplay in RAM using macOS's native GPU hardware encoder (`ScreenCaptureKit` + `VideoToolbox`), saves untouched master clips on a single hotkey (`⌃⇧S`, standalone `F8`/`F9`, or any custom shortcut), and keeps optional Discord-sized share copies neatly paired alongside your masters — with zero watermarks, zero accounts, zero paywalls, and zero background SSD wear while you play.

## Why Backbuffer?

- **Zero watermarks, zero subscriptions:** Full-resolution 1080p/Native 60 FPS clips with clean audio.
- **Privacy-first Allowed Apps filtering:** Starts in Strict Allowlist mode so Backbuffer only records apps you explicitly allow (with live ScreenCaptureKit filtering and instant Allow Running / blocklist switching).
- **Optional Microphone Commentary & NLE Multi-Track Audio:** Mix voice commentary into Track 1 with live VU metering and 0%–200% gain control, or also save isolated **Game Audio** and **Microphone** tracks (`disabled` by default so QuickTime/Discord play the unified mix while DaVinci Resolve / Premiere / Final Cut Pro expose separate stems).
- **Flexible global hotkeys without Accessibility TCC:** Uses Carbon `GetEventDispatcherTarget()` + synchronous RunLoop dispatch so standalone function keys (`F8`, `F9`, F1–F20) and modifier shortcuts work over fullscreen games without Input Monitoring prompts.
- **No background disk thrashing:** Video (`HEVC` / `H.264`), system audio, and optional mic audio stay inside a bounded RAM ring buffer until you hit Save.
- **Non-destructive `Masters/` + `Shared/` storage:**
  - Untouched original hardware-encoded clips live in `~/Movies/Backbuffer/Masters/` for DaVinci Resolve, Premiere Pro, or CapCut.
  - When a clip exceeds your Share Cap (`10 MB`, `20 MB Discord Free`, or `50 MB`), a compressed companion is saved in `~/Movies/Backbuffer/Shared/` without ever altering your master.
- **CFR Keepalive for NLEs:** Repeats static menu/lobby frames cleanly so editors never choke on variable-frame-rate gaps.
- **Built-in Library & Quick Trimmer:** Scrub with an interactive filmstrip, export lossless master trims, or copy a Discord-sized clip straight to your clipboard (`Cmd+V`).

## Installation (macOS 13 Ventura or later)

1. Download **`Backbuffer-Universal.dmg`** from [GitHub Releases](https://github.com/Malachite-Ore/backbuffer/releases).
2. Open the `.dmg` and drag **`Backbuffer.app`** into **`Applications`** (avoid running directly from the mounted `.dmg` volume or `Downloads/`, which can break macOS Screen Recording permissions).
3. **First Launch & Upgrades (Gatekeeper + macOS TCC Note):** Because Backbuffer is free open-source software signed with an ad-hoc certificate (no paid Apple Developer ID), macOS ties Screen Recording permission to each version's binary signature:
   - **Recommended:** Double-click **`Open First Time (Bypass Gatekeeper).command`** inside the `.dmg` — it stops any older background instance, installs `Backbuffer.app` into `/Applications`, clears quarantine, resets any outdated Screen Recording TCC entry when upgrading versions, and launches cleanly.
   - **Upgrading from `v1.0.x` / `v1.1.0` & stuck on "Screen Recording Permission Needed"?**
     - Inside the app banner, click **`Check & Relaunch`** (if you already enabled Backbuffer in **System Settings → Privacy & Security → Screen Recording**) or **`Fix Updated App`** to clear the stale upgrade signature and re-prompt once.
     - Or run **`Fix Stuck Screen Recording Permission.command`** included in `Backbuffer-Universal.dmg` (runs `tccutil reset ScreenCapture io.malachiteore.backbuffer` and relaunches `/Applications/Backbuffer.app`).
   - **Or manually:** Right-click (Control-click) **`Backbuffer.app`** in `Applications` → choose **Open** → click **Open**. On macOS Sequoia (15+) / Tahoe (26+), if macOS blocks opening directly, go to **System Settings → Privacy & Security**, scroll to **Backbuffer**, and click **Open Anyway**.
4. Backbuffer opens straight into the **Clip Library & Live Capture** window, shows in your **Dock** and **Menu Bar**, and keeps buffering in RAM in the background even when you close the window (`⌘W`).
5. Grant **Screen Recording** permission and allow your game/apps under **Settings → Allowed Apps** to begin buffering. Grant **Microphone** permission under **Settings → Shortcuts & Mic** if you want voice commentary recorded.

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
