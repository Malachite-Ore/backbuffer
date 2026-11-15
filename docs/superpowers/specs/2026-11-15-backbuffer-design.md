# Backbuffer — Design Specification

**Date:** 2026-11-15
**Repository:** `Malachite-Ore/backbuffer` (public GitHub repository, Universal macOS `.dmg` releases)
**Local Workspace Path:** `D:\Google Antigravity\Projects\Coding\Backbuffer`
**Target Platform:** macOS 13.0 (Ventura) or later — Universal Binary (`x86_64` Intel + `arm64` Apple Silicon)

---

## 1. Intent & Why

Backbuffer is a lightweight, zero-cost, watermark-free instant-replay gameplay clipper for macOS. Existing macOS clipping apps (such as ClipMac) lock basic exports behind subscriptions, stamp watermarks onto clips, or require macOS 15+ and drop older Intel Macs. Meanwhile, naive screen recorders emit unconstrained Retina H.264 files (~170–200 MB for 30 seconds), which choke Discord uploads and waste disk space.

Backbuffer lets a player continuously buffer the last N seconds of gameplay in RAM using macOS's native GPU hardware encoder, hit a hotkey to save immediately, inspect and trim clips in a clean native library, and share small Discord-ready copies **without ever degrading or overwriting the untouched original master clip needed for post-production editing**.

---

## 2. Goals, Non-Goals & Anti-Goals

### Goals (v1)
1. **Low-overhead continuous replay buffering** on macOS 13.0+ (Intel `x86_64` and Apple Silicon `arm64`) using `ScreenCaptureKit` (`SCStream`) for display/window video + native system/game audio and `VideoToolbox` (`VTCompressionSession`) for real-time hardware encoding.
2. **Configurable Capture Settings** with live file-size and RAM estimates: FPS (`24 / 30 / 60`), resolution cap (`720p / 1080p / Native`), quality/bitrate preset (`Compact / Balanced / High / Post Master`), codec (`HEVC` / `H.264`), rolling buffer duration (`15s / 30s / 60s / 120s`), capture target (Full Display or specific Game Window), and global save hotkey (`⌥⌘S` default).
3. **Non-Destructive Dual-File Storage & Auto-Compression**:
   - Every save writes the original hardware-encoded capture untouched to `~/Movies/Backbuffer/Masters/`.
   - When an optional Share Cap (`Off / 10 MB / 20 MB (Discord Free) / 50 MB`) is enabled and the master clip (or trimmed range) exceeds that cap, a background hardware re-encode writes a separate companion file to `~/Movies/Backbuffer/Shared/` while leaving `Masters/` completely intact for post-production (Premiere, DaVinci Resolve, CapCut).
4. **Clip Library & Quick Trimmer**: Browse saved clips, scrub/play with `AVPlayer`, adjust start/end trim handles, copy the share-ready file to macOS clipboard (`Cmd+V` into Discord), reveal the original master in Finder, export a lossless passthrough trim to `Masters/`, or copy a compressed trim to `Shared/`.
5. **Zero-Cost Distribution via GitHub Releases**: Automated CI (`macos-15` runner) running `swift test` and building a signed (ad-hoc) Universal `.dmg` containing `Backbuffer.app`, `/Applications` symlink, and a first-launch Gatekeeper helper script.

### Non-Goals (Deferred for Future v1.x / `3C` Expansion)
- Multi-track microphone + game-audio mixing and per-app audio isolation (v1 captures system/game audio only, with an explicit multi-track seam in `ClipMuxer`).
- Cloud hosting, shareable web links, user accounts, or analytics.
- Support for macOS 12 Monterey and earlier (which lack native `ScreenCaptureKit` audio capture and would require third-party virtual audio drivers like BlackHole).
- Paid Apple Developer ID notarization (\$99/year) — replaced in v1 with ad-hoc signing + explicit first-run Gatekeeper bypass helper.

### Anti-Goals (Hard Invariants)
1. **Never overwrite, replace, or delete an original master clip** during auto-compression or trimming.
2. **Never retain `ScreenCaptureKit` `CMSampleBuffer` / `CVPixelBuffer` references past the delegate callback boundary**, preventing `IOSurface` pool starvation and frame drops.
3. **Never write continuously to the SSD while buffering in the background.**
4. **Never require macOS Accessibility or Input Monitoring (keylogger) permissions** for global hotkeys — use Carbon `RegisterEventHotKey`.
5. **Never inject watermarks, paywalls, subscriptions, telemetry, or network calls.**

---

## 3. Approaches Considered & Chosen

| Option | Summary | Trade-Offs | Decision |
|---|---|---|---|
| **A: Hybrid Tauri (Web UI + Rust) + Swift Capture Sidecar + Bundled `FFmpeg`** | Web-based Settings/Trimmer UI inside `WKWebView`, Rust shell, Swift CLI for `ScreenCaptureKit`, bundled `ffmpeg` binary for compression. | Previewable UI on Windows, **but** ships an ~85 MB app bundle, consumes significantly more idle RAM on older Macs, and splits state/build across TypeScript, Rust, and Swift. | Rejected |
| **B: Pure Swift + Segmented Disk Ring Buffer (2s `AVAssetWriter` chunks)** | Native SwiftUI app continuously writing 2-second `.mp4` segments to disk and deleting expired ones, concatenating on save. | Keeps RAM tiny (~5 MB) even for huge 5-minute buffers, **but** causes continuous background SSD writes while gaming and adds segment-stitching edge cases. | Rejected |
| **C: Pure Swift + SwiftUI + Hardware-Compressed RAM Packet Ring Buffer (`VTCompressionSession` + `AVAssetWriter` passthrough)** | Native ~3 MB Swift/SwiftUI app that hardware-encodes video (`HEVC`/`H.264`) and audio (`AAC` / LPCM chunks) in real time and retains only compressed packets in a RAM ring buffer until hotkey save. | **Chosen (`Q4 = C`).** Zero SSD wear while gaming, instant container-wrap saves on hotkey, tiny ~3 MB binary footprint, minimal CPU overhead on older Macs (`macOS 13+`), bounded RAM (~15–45 MB for typical 30–60s buffers), and clean extensibility to microphone tracks later. | **Chosen** |

---

## 4. Architecture & Module Breakdown

Because development happens on Windows and builds/tests execute on GitHub Actions `macos-15` runners, the project uses a pure Swift Package Manager (`Package.swift`, `swift-tools-version: 5.9`, platform `.macOS(.v13)`) layout so core media logic is cleanly separated from macOS TCC Screen Recording prompts and tested headlessly.

### 4.1 Package Targets

1. **`BackbufferCore`** (UI-independent library target):
   - `SettingsStore`: `Codable` user configuration (`UserDefaults`-backed or injected store for tests) plus bitrate/RAM/clip-size estimation formulas.
   - `ReplayRingBuffer`: Thread-safe actor/lock-guarded circular buffer of compressed `BufferedVideoPacket` and `BufferedAudioChunk` items, bounded by time horizon (`bufferDuration + 2.0s` headroom) and pruned strictly on video IDR keyframe boundaries.
   - `VideoEncoder`: Real-time `VTCompressionSession` wrapper converting incoming `CVPixelBuffer`s into detached compressed `CMSampleBuffer`s (`HEVC` or `H.264`) with explicit IDR keyframe intervals (`1.0s`).
   - `ClipMuxer`: `AVAssetWriter` passthrough writer (`outputSettings: nil` + `sourceFormatHint` for video, `160 kbps` AAC for audio) that normalizes all timestamps (`PTS - firstKeyframePTS`) to start cleanly at `CMTime.zero` and accepts `[AudioTrackSource]` as the extensibility seam for future `3C` multi-track mic capture.
   - `ClipCompressor`: Target-size hardware transcoder (`AVAssetReader` -> `VTCompressionSession` -> `AVAssetWriter`) calculating exact target bitrate from `capBytes` and clip duration, with smart 720p downscale fallback for long clips where bitrate would otherwise drop below `1.2 Mbps`.
   - `ClipTrimmer`: Performs two distinct operations:
     - **Lossless Master Trim**: `AVAssetExportSession` with `AVAssetExportPresetPassthrough` writing a clean trimmed file into `Masters/`.
     - **Compressed Share Trim**: Time-ranged hardware transcode (`ClipCompressor`) writing into `Shared/` capped to the Share Cap (or direct copy if already under cap).
   - `ClipLibraryStore`: Scans and indexes `~/Movies/Backbuffer/Masters/` and `~/Movies/Backbuffer/Shared/`, pairing each master clip with its companion share copy (if any), metadata (duration, resolution, FPS, codec, master size, share size), and compression job status.

2. **`BackbufferApp`** (macOS executable target):
   - `BackbufferApp`: SwiftUI `@main` app (`LSUIElement = true` optional/toggleable or menu-bar-first with dock presence only when Library/Settings window is open).
   - `MenuBarView`: `MenuBarExtra` / `NSStatusItem` popover showing live buffer state (`● Buffering Last 30s (~17.5 MB RAM)`), `Save Clip Now (⌥⌘S)`, quick capture source picker (`Full Display` / specific `SCWindow`), `Open Clip Library...`, `Settings...`, and `Quit`.
   - `CaptureCoordinator`: Manages `ScreenCaptureKit` (`SCShareableContent`, `SCStream`, `SCStreamConfiguration`, `SCStreamOutput`), enforces non-blocking callback discipline, handles display/window availability changes, and tracks Screen Recording TCC authorization cleanly with clear UI guidance when denied.
   - `HotKeyManager`: Registers/unregisters the global hotkey via Carbon `RegisterEventHotKey` (requiring zero Accessibility/Input Monitoring permissions).
   - `SettingsView`: Interactive SwiftUI settings pane with FPS, Resolution Cap, Quality Preset, Codec, Buffer Duration, Share Cap, Save Folder, Hotkey recorder, and live computed readout (`Master Clip Size`, `Share Copy`, `RAM Ring Buffer`).
   - `LibraryTrimmerView`: Two-pane or grid+inspector SwiftUI view using `AVPlayer` (`AVPlayerView` wrapper) with draggable start/end trim handles, master/share status badges, `Copy Share Clip` (`NSPasteboard` file URL write), `Reveal Original Master` (`NSWorkspace.shared.activateFileViewerSelecting`), `Save Master Trim (Lossless)`, and `Copy Compressed Trim`.

3. **`BackbufferCoreTests`** (`XCTest` target):
   - Runs completely headlessly via `swift test` in CI without Screen Recording permissions.
   - Generates synthetic `CVPixelBuffer` frames (solid/animated color patterns) and synthetic 48 kHz stereo PCM audio buffers:
     - Verifies `VideoEncoder` produces valid compressed packets with regular IDR keyframes.
     - Verifies `ReplayRingBuffer` retains `bufferDuration` seconds, prunes strictly at keyframe boundaries, and guarantees every snapshot begins on a keyframe.
     - Verifies `ClipMuxer` normalizes PTS to `CMTime.zero`, outputs a playable `.mp4` validated with `AVAsset` duration, video dimensions, frame rate, and non-empty video + audio tracks.
     - Verifies `ClipCompressor` takes an oversized master `.mp4` (> 20 MB synthetic clip) and produces a `Shared/` `.mp4` strictly `<= capBytes` (e.g. `<= 20 * 1024 * 1024`), while verifying the original file in `Masters/` is byte-for-byte untouched.
     - Verifies `ClipTrimmer` lossless trim preserves original bitrate/codec and creates a new file in `Masters/` without mutating the source, and compressed trim fits under the target Share Cap.
     - Verifies `SettingsStore` size/RAM estimation math matches encoded outputs within expected CBR/VBR bounds.

---

## 5. Detailed Pipeline Mechanics

### 5.1 ScreenCaptureKit Configuration (`SCStreamConfiguration`)
- `capturesAudio = true`
- `excludesCurrentProcessAudio = true` (prevents capture feedback loops from preview playback or chime)
- `sampleRate = 48000`, `channelCount = 2`
- `minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.fps))` (`24`, `30`, or `60`)
- `queueDepth = 6`
- **Output Dimensions (`width`, `height`)**: Computed from the selected `SCDisplay` or `SCWindow` logical point bounds multiplied by its `pointPixelScale` (using **physical backing pixels**, never logical points, so Retina displays and scaled 4K monitors retain full sharpness).
  - `720p` cap: scales proportionally so `height <= 720`.
  - `1080p` cap *(default)*: scales proportionally so `height <= 1080`.
  - `Native`: uses full physical backing pixels, **clamped to `width <= 4096`** (aspect-preserving) so older Intel QuickSync hardware encoders on 5K displays (`5120×2880`) never exceed `4096 px` and fall back to slow CPU encoding.
  - All output widths and heights are rounded down to even integers (`(dim / 2) * 2`) as required by `VTCompressionSession`.
- `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (hardware-friendly NV12).

### 5.2 Callback Memory Safety & Constant Frame Rate (CFR) Keepalive
`ScreenCaptureKit` only delivers `.complete` frames when pixels visually change; during pause menus, loading screens, or static lobbies, `SCStream` emits `.idle` (or stops firing) while system audio keeps streaming. Because DaVinci Resolve and Premiere Pro drift or fail on Variable Frame Rate (VFR) gaps, Backbuffer enforces **Constant Frame Rate (CFR)** without starving `SCStream`'s `IOSurface` pool:
- `SCStreamOutput` delegates run on dedicated serial queues (`com.backbuffer.capture.video` and `com.backbuffer.capture.audio`).
- Inside the video callback:
  1. Check `SCFrameStatus.complete` from sample attachments; ignore `.idle`, `.blank`, or `.suspended`.
  2. Immediately blit the incoming `CVPixelBuffer` via a GPU-backed `VTPixelTransferSession` into a tiny 2-slot app-owned `CVPixelBufferPool` (~6 MB total @ 1080p), submit that detached copy to `VTCompressionSessionEncodeFrame(...)` with `presentationTimeStamp`, cache a reference to that app-owned slot as `latestFrameBuffer`, and return immediately. `SCStream`'s `IOSurface` is released on callback exit with zero CPU copy overhead.
- **CFR Keepalive Timer:** A lightweight timer synced to `1 / fps` fires if no `.complete` frame arrived within `1.5 * frameDuration`. It re-submits the app-owned `latestFrameBuffer` to `VTCompressionSessionEncodeFrame` with an advancing monotonic host timestamp until visual updates resume. Because `VTCompressionSession` treats identical frames as P-skip macroblocks, repeated static frames add negligible bitrate/RAM while keeping `<= 1.0s` IDR keyframes and rock-solid A/V sync for Premiere and DaVinci Resolve.
- Inside the audio callback:
  1. Extract raw LPCM audio bytes and `AudioStreamBasicDescription` + `PTS` into a lightweight `BufferedAudioChunk` value struct, then return immediately.

### 5.3 Hardware Video Encoding & Preset Table
Default codec: `kCMVideoCodecType_HEVC` (`H.265`, ~35–40% better quality-per-bit than H.264 on macOS 13+ hardware encoders; falls back cleanly or toggles in Settings to `kCMVideoCodecType_H264` for maximum cross-device compatibility).

`VTCompressionSession` properties:
- `kVTCompressionPropertyKey_RealTime`: `true`
- `kVTCompressionPropertyKey_AllowFrameReordering`: `false` (no B-frames -> zero reorder latency, instant scrubbing, clean PTS-monotonic keyframe slicing)
- `kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration`: `1.0` seconds (every 1s starts with an IDR keyframe, bounding trim-start/buffer-slice precision to `<= 1s`)
- `kVTCompressionPropertyKey_AverageBitRate` & `kVTCompressionPropertyKey_DataRateLimits`: set from the preset table below.

| Quality Preset | Video Bitrate @ 1080p | Video Bitrate @ 720p | Video Bitrate @ Native (1440p+) | Audio (AAC) | ~Est. 30s Clip Size (1080p) | Intended Use |
|---|---|---|---|---|---|---|
| `Compact` | `3.0 Mbps` | `2.0 Mbps` | `4.5 Mbps` | `128 kbps` | ~11.8 MB | Tiny clips, fits 10–20 MB easily |
| `Balanced` *(default)* | `4.5 Mbps` | `3.0 Mbps` | `7.0 Mbps` | `160 kbps` | **~17.5 MB** | Crisp 1080p60 natively under Discord's 20 MB cap |
| `High` | `10.0 Mbps` | `6.5 Mbps` | `15.0 Mbps` | `160 kbps` | ~38.1 MB | Sharp capture + auto-share copy when needed |
| `Post Master` | `20.0 Mbps` | `12.0 Mbps` | `30.0 Mbps` | `192 kbps` | ~75.6 MB | Clean high-bitrate master for post-editing |

*(Note: For `Native` resolutions exceeding `2560×1440` — e.g. 4K `3840×2160` — `SettingsStore` scales the `Native` bitrate tier by `1.5×` for `Balanced`/`High`/`Post Master` to avoid blocking on 4K pixel counts, reflected live in the Settings size estimator.)*

### 5.4 Ring Buffer Slicing & Instant Save
- `ReplayRingBuffer` keeps compressed video packets (`pts`, `isKeyframe`, `sampleBuffer`) and audio chunks (`pts`, `duration`, `pcmData`, `asbd`).
- **Decoupled A/V Eviction:** Whenever a new video keyframe arrives, video packets older than `latestVideoPTS - (bufferDuration + 2.0s)` up to the next keyframe are evicted; audio chunks are evicted independently by PTS whenever `chunk.pts < oldestRetainedVideoPTS` (or `latestAudioPTS - (bufferDuration + 4.0s)` if video callbacks ever pause) so audio never grows unboundedly.
- When `Save Clip` fires (via global hotkey or menu button):
  1. Snapshot `[BufferedVideoPacket]` starting at the latest keyframe at or before `latestVideoPTS - bufferDuration` (or earliest available keyframe if capture started recently).
  2. Snapshot `[BufferedAudioChunk]` clamped strictly to `firstVideoPTS <= chunk.pts <= lastVideoPTS` so audio and video endpoints always match cleanly in NLEs.
  3. Capture continues uninterrupted into the live ring buffer while an async export task writes the snapshot to `~/Movies/Backbuffer/Masters/Backbuffer_YYYY-MM-DD_HH-mm-ss.mp4`.
  4. `ClipMuxer` encodes audio chunks into `160 kbps` AAC (via `AVAssetWriterInput(mediaType: .audio, outputSettings: ...)`) and appends compressed video packets via passthrough (`outputSettings: nil`, `sourceFormatHint`), rewriting every `CMSampleBuffer` timing info so `newPTS = originalPTS - firstVideoPTS`.

### 5.5 Non-Destructive Auto-Compression (`Masters/` vs. `Shared/`)
- **Storage Layout & 1:N Pairing (`ClipLibraryStore`):**
  - `~/Movies/Backbuffer/Masters/` — Untouched original saves (`Backbuffer_YYYY-MM-DD_HH-mm-ss.mp4`) and lossless passthrough trims (`<MasterStem>_trim_<start>-<end>.mp4`). **Never overwritten or auto-deleted.**
  - `~/Movies/Backbuffer/Shared/` — Companion auto-compressed `.mp4` files: `<MasterStem>_share.mp4` for full clips, and `<MasterStem>_trim_<start>-<end>_share.mp4` for compressed trim exports (never overwriting the full clip's share file).
- **Auto-Compress Rule (`Q5 = B`):**
  - Setting `shareCap`: `Off` | `10 MB` | `20 MB (Discord Free)` *(default)* | `50 MB`. (Per Discord's *File Attachments FAQ*, Free tier uploads were raised from `10 MB` to `20 MB` in August 2026, Nitro Basic is `50 MB`, and full Nitro is `1 GB`; keeping both `10 MB` and `20 MB` covers current free accounts and stricter `10 MB` targets.)
  - After saving any Master `.mp4` (capture save or `Save Master Trim (Lossless)`):
    1. Check `fileSize <= capBytes * 0.96` (4% container safety margin).
    2. If it already fits (e.g. a 30s `Balanced` clip at ~17.5 MB with a 20 MB cap), **no duplicate re-encode is performed**. `Copy Share Clip` copies the Master file URL directly.
    3. If `shareCap` is enabled and the Master exceeds the cap, `ClipCompressor` spawns a background hardware re-encode targeting `capBytes * 0.94` into `Shared/<MasterStem>_share.mp4`:
       - Compute `audioBps`: `128_000` (or `96_000` if duration > 90s and cap <= 10 MB).
       - Compute `targetVideoBps = max(350_000, Int((Double(capBytes) * 0.94 * 8.0) / durationSeconds) - audioBps)`.
       - **Smart Downscale Rule:** If source height > 720 and `targetVideoBps < 1_200_000`, scale the `Shared` copy down to `720p` (preserving aspect ratio, even dimensions) so long clips stay clean rather than breaking into severe macroblocks. The Master remains full resolution (`1080p` / `Native`).
       - If the single hardware pass still marginally exceeds `capBytes` (rare VBR overshoot), run one conservative retry at `0.85 * targetVideoBps`.
  - **Trim Export When `Share Cap == Off`:** If `Share Cap` is set to `Off`, `Copy Compressed Trim` in `LibraryTrimmerView` remains available as `Copy Trim (20 MB Discord)` (using a `20 MB` default share target so a friend can always paste a quick Discord clip without re-enabling global auto-compression) alongside `Save Master Trim (Lossless)`.
  - **Retroactive `Share Cap` Changes (`Q7 = A` — Lazy Re-Evaluation):** Changing `shareCap` in Settings does **not** trigger background re-encoding of older clips. Instead, when `Copy Share Clip` is clicked on an existing clip whose `Shared/` file (or `Master` when no `Shared/` file exists yet) exceeds the currently active `shareCap * 0.96`, `ClipLibraryStore` lazily runs `ClipCompressor` against the untouched `Master` to produce or replace `Shared/<MasterStem>_share.mp4` under the new cap before placing its file URL on `NSPasteboard`.

### 5.6 Future `3C` Extensibility Seam (Microphone Multi-Track)
- `ClipMuxer` accepts `[AudioTrackInput]` rather than a single hardcoded audio stream, allowing a future `AVCaptureSession` microphone input to be appended as Track 2 in `Masters/` (discrete post-editing tracks in Premiere/DaVinci) and optionally mixed down for `Shared/` without redesigning the video pipeline or ring buffer.

---

## 6. UI Surface Specification

1. **Menu Bar Popover (`MenuBarView`)**:
   - Status row: live indicator (`● Buffering Last 30s` / `Paused` / `Permission Needed`) + RAM buffer readout (`~17.5 MB RAM`).
   - Primary CTA: `Save Clip Now` (`⌥⌘S`).
   - Source Selector: Quick toggle between `Full Display` (list of displays) and `Game Window` (active windows list from `SCShareableContent`).
   - Pause/Resume Buffering toggle (useful when stepping away or closing a game).
   - Footer links: `Open Clip Library...` and `Settings...`.

2. **Settings Window (`SettingsView`)**:
   - **Capture Controls:** FPS (`24 / 30 / 60`), Resolution Cap (`720p / 1080p / Native`), Quality Preset (`Compact / Balanced / High / Post Master`), Codec (`HEVC (Smaller) / H.264 (Compatible)`), Buffer Length (`15s / 30s / 60s / 120s`).
   - **Share & Hotkey Controls:** Discord Auto-Compress (`Off / 10 MB / 20 MB (Discord Free) / 50 MB`), Global Save Hotkey recorder (`⌥⌘S`), Output Folder selector (`~/Movies/Backbuffer`).
   - **Live Estimator Card:** Real-time readout updating as controls change:
     - `Original Master (Post)`: e.g. `~17.5 MB` (kept untouched in `Masters/`)
     - `Share Copy (Discord)`: e.g. `Already fits (<= 20 MB)` or `Auto-compressed -> <= 20 MB in Shared/`
     - `RAM Buffer Footprint`: e.g. `~18.7 MB RAM (0 SSD writes while gaming)`

3. **Clip Library & Quick Trimmer (`LibraryTrimmerView`)**:
   - Left sidebar/list: Saved clips sorted newest-first with thumbnail, timestamp, duration, and two crisp size badges (`Master: 38.1 MB` | `Share: 18.4 MB` or `Fits <20 MB`).
   - Right inspector: `AVPlayer` preview + interactive start/end trim scrubber with duration & estimated trimmed size readout.
    - Action bar:
      - `Copy Share Clip` (Primary — writes `Shared` or qualifying `Master` file URL to `NSPasteboard` for instant `Cmd+V` into Discord).
      - `Reveal Original Master` (Reveals `Masters/` file in Finder for post-editing).
      - Trim Actions (when trim range is modified): `Save Master Trim (Lossless)` (creates `<MasterStem>_trim_<start>-<end>.mp4` in `Masters/` and pairs with `Shared/` if over cap) and `Copy Compressed Trim` (writes `<MasterStem>_trim_<start>-<end>_share.mp4` in `Shared/` — targeting `20 MB` if `Share Cap` is `Off` — and copies to clipboard).

---

## 7. Packaging, Distribution & CI Pipeline

- **`scripts/package_app.sh`**:
  1. `swift build -c release --arch arm64 --arch x86_64`
  2. Verify Universal Binary via `lipo -archs` (`x86_64` and `arm64` both present).
  3. Construct `Backbuffer.app/Contents/{MacOS,Resources}` with `Info.plist`:
     - `CFBundleIdentifier`: `io.github.malachite-ore.backbuffer`
     - `LSMinimumSystemVersion`: `13.0`
     - `NSScreenCaptureUsageDescription` & `NSMicrophoneUsageDescription`
     - Custom crisp app icon (`AppIcon.icns`) generated programmatically in repo scripts (never blank default icon).
  4. Ad-hoc sign: `codesign --force --deep --sign - Backbuffer.app`.
  5. Stage DMG directory containing `Backbuffer.app`, symlink `/Applications`, and `Open First Time (Bypass Gatekeeper).command` (`#!/bin/bash` running `xattr -cr /Applications/Backbuffer.app && open /Applications/Backbuffer.app` so a non-technical user doesn't fight Gatekeeper quarantine dialogs).
  6. Package compressed `Backbuffer-Universal.dmg` with `hdiutil create -ov -format UDZO`.
- **`.github/workflows/ci.yml`**:
  - Runs on `macos-15` (unlimited free minutes on public repo).
  - Triggered on `push` / `pull_request` (`swift test` + Universal build + DMG smoke verify) and on `v*` tags (creates GitHub Release with `Backbuffer-Universal.dmg` attached).

---

## 8. Builder Calls (Settled from Spec Review)

1. **Constant Frame Rate (CFR) Keepalive for Post-Production (`DaVinci Resolve` / `Premiere Pro`)**: Rather than dropping to Variable Frame Rate (VFR) when `ScreenCaptureKit` pauses frame delivery on static menus/lobbies, incoming `.complete` frames are transferred on GPU via `VTPixelTransferSession` into a 2-slot `CVPixelBufferPool` (`SCStream` `IOSurface` released immediately), and a lightweight `1/fps` keepalive re-submits the last frame whenever updates pause (`> 1.5x` frame interval). Audio eviction is decoupled by PTS (`oldestRetainedVideoPTS`) and clamped at save time (`firstVideoPTS <= pts <= lastVideoPTS`).
2. **Physical Backing Pixels (`pointPixelScale`) & `4096 px` Intel QuickSync Guard**: Resolution caps (`720p`, `1080p`, `Native`) scale from physical Retina pixels (`bounds * pointPixelScale`) rather than logical points so Retina displays stay crisp. `Native` is clamped to `width <= 4096` (aspect-preserving) so 5K displays (`5120×2880`) never exceed older Intel QuickSync hardware encoder bounds and fall back to slow CPU encoding.
3. **Non-Destructive Trim Files (`1:N` `Shared/` Naming)**: `Copy Compressed Trim` writes `<MasterStem>_trim_<start>-<end>_share.mp4` into `Shared/` rather than overwriting `<MasterStem>_share.mp4`, preserving the full clip's share copy. When `Share Cap` is `Off`, `Copy Compressed Trim` still offers a `20 MB Discord` fallback target. `Save Master Trim (Lossless)` writes a new master file into `Masters/` and pairs it with `Shared/` if it exceeds the active `Share Cap`.

---

## 9. Left to the Builder (Deferred to Implementation Plan)

- Exact SwiftUI styling tokens, thumbnail extraction (`AVAssetImageGenerator`) caching, and custom app icon (`AppIcon.icns`) vector/raster asset generation script.
- Carbon `RegisterEventHotKey` modifier flag translation helper (`NSEvent.ModifierFlags` <-> Carbon `cmdKey` / `optionKey` / `shiftKey` / `controlKey`).
- `SCContentFilter` fallback behavior if a targeted game window closes mid-session (gracefully pause buffering or notify the user rather than silently recording black frames).
