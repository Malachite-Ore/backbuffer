# Backbuffer v1 Implementation Plan

> **For agentic workers:** Executed via `/swarm` on a public GitHub repository (`Malachite-Ore/backbuffer`) with `macos-15` GitHub Actions verification. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Backbuffer — a native Universal macOS 13+ instant-replay gameplay clipper with live FPS/Quality/MB Settings, non-destructive `Masters/` + Discord-sized `Shared/` dual storage, a native Library & Quick Trimmer, and an automated `.dmg` GitHub Release pipeline.

**Architecture:** A SwiftPM package splits pure media/storage/estimation logic (`BackbufferCore`) from macOS UI and `ScreenCaptureKit` TCC permissions (`BackbufferApp`) so all encoding, ring-buffering, muxing, trimming, and target-size compression logic runs headlessly under `swift test` on GitHub Actions `macos-15` runners. Live frames are blitted via `VTPixelTransferSession` into a 2-slot GPU `CVPixelBufferPool` with a CFR keepalive timer, hardware-encoded in real time (`VTCompressionSession`) into a RAM `ReplayRingBuffer`, saved untouched to `Masters/` via `AVAssetWriter` passthrough, and optionally size-capped to `Shared/`.

**Tech Stack:** Swift 5.9+, Swift Package Manager, `ScreenCaptureKit`, `VideoToolbox`, `AVFoundation`, `AVKit`, `CoreMedia`, `SwiftUI` / `AppKit`, Carbon `HIToolbox` (`RegisterEventHotKey`), `XCTest`, GitHub Actions (`macos-15`).

**Spec:** [2026-11-15-backbuffer-design.md](file:///D:/Google%20Antigravity/Projects/Coding/Backbuffer/docs/superpowers/specs/2026-11-15-backbuffer-design.md)

---

## Global Constraints

- Minimum OS floor: `macOS 13.0` (`Ventura`), compiled as a Universal Binary (`--arch arm64 --arch x86_64`).
- Zero watermarks, subscriptions, paywalls, accounts, telemetry, or outbound network calls.
- Never overwrite, modify, or delete files inside `~/Movies/Backbuffer/Masters/` during auto-compression, lazy `Share Cap` re-evaluation, or trimming.
- Never retain `SCStream` `CMSampleBuffer` / `CVPixelBuffer` references past the delegate callback boundary (`VTPixelTransferSession` GPU blit into a 2-slot app `CVPixelBufferPool` + CFR keepalive timer).
- Zero continuous SSD writes during background buffering (compressed packets stay in `ReplayRingBuffer` RAM until save).
- Global hotkeys use Carbon `RegisterEventHotKey` (requiring zero Accessibility or Input Monitoring permissions).
- SwiftPM testability: `XCTest` links exclusively against `BackbufferCore` (never `@testable import` an `@main` `.executableTarget`).
- Git identity in `Malachite-Ore/backbuffer`: `Malachite-Ore <180101749+Malachite-Ore@users.noreply.github.com>` with **zero** `Co-Authored-By` trailers in any commit.

## Review Focus

1. **Early save / silent audio (`Task 2` & `Task 3`):** Saving within 1–2s of launch (short buffer, zero audio chunks, or empty ring buffer) must produce a valid video-only `.mp4` or fail explicitly with `BackbufferError.emptyBuffer`, never a corrupt unplayable `.mp4`.
2. **Odd window dimensions & 5K Intel QuickSync limit (`Task 1` & `Task 3`):** Resizing a game window to odd pixel bounds (`1365×767`) or running `Native` on a 5K Intel iMac (`5120×2880` > `4096 px`) must clamp to `width <= 4096` and even pixel dimensions (`(dim / 2) * 2`) before reaching `VTCompressionSession`.
3. **Rapid double-tap hotkey collision (`Task 5`):** Pressing `⌥⌘S` twice within the same wall-clock second must disambiguate `Backbuffer_YYYY-MM-DD_HH-mm-ss-2.mp4` rather than overwriting or failing on an existing file.
4. **Chaotic VBR bitrate overshoot (`Task 4`):** If single-pass hardware re-encode of high-entropy video exceeds `capBytes`, `ClipCompressor` must automatically retry at `0.85 * targetVideoBps` so `Shared/` strictly fits `<= capBytes` while `Masters/` stays byte-for-byte identical.
5. **Lowering `Share Cap` on existing library (`Task 5`, `Q7 = A`):** When `shareCap` is lowered (e.g., `20 MB -> 10 MB`), calling `resolveShareClip` on an existing clip with an `18.4 MB` `_share.mp4` must lazily re-encode from `Masters/` into `Shared/` under the new `10 MB` cap while `loadClips` performs zero background re-encoding.

---

## File Map & Swarm Partitioning

`Task 1` runs first to establish `Package.swift`, shared `Models.swift` contracts, and `TestMediaFactory.swift`. Once `Task 1` commits, **`Tasks 2, 3, 4, and 5` own completely disjoint files and run in parallel** inside `/swarm`. `Task 6` and `Task 7` integrate `BackbufferApp` against locked `BackbufferCore` interfaces (`Task 7` implements Max's `Q9` visual direction), and `Task 8` adds packaging + GitHub Actions CI + UI screenshot rendering verification.

| Task | Owned Files | Worker Dependencies |
|---|---|---|
| **Task 1** | `Package.swift`, `.gitignore`, `Sources/BackbufferCore/{Models,SettingsStore,CaptureDimensionCalculator,HotKeyShortcut}.swift`, `Tests/BackbufferCoreTests/{TestMediaFactory,SettingsStoreTests}.swift` | Serial prerequisite |
| **Task 2** | `Sources/BackbufferCore/ReplayRingBuffer.swift`, `Tests/BackbufferCoreTests/ReplayRingBufferTests.swift` | After Task 1 |
| **Task 3** | `Sources/BackbufferCore/{VideoEncoder,ClipMuxer}.swift`, `Tests/BackbufferCoreTests/VideoEncoderAndMuxerTests.swift` | After Task 1 |
| **Task 4** | `Sources/BackbufferCore/{ClipCompressor,ClipTrimmer}.swift`, `Tests/BackbufferCoreTests/ClipCompressorAndTrimmerTests.swift` | After Task 1 (and uses `ClipMuxer`/`TestMediaFactory` in tests) |
| **Task 5** | `Sources/BackbufferCore/ClipLibraryStore.swift`, `Tests/BackbufferCoreTests/ClipLibraryStoreTests.swift` | After Task 1 + Task 4 (`ClipCompressor.compressIfNeeded` interface) |
| **Task 6** | `Sources/BackbufferApp/{CaptureCoordinator,HotKeyManager}.swift` | After Tasks 1–3 |
| **Task 7** | `Sources/BackbufferApp/{BackbufferMain,AppViewModel,MenuBarPopoverView,SettingsWindowView,LibraryTrimmerWindowView,FilmstripTimelineView}.swift`, `scripts/render_ui_previews.swift` | After Tasks 1–6 + Max's `Q9` choice |
| **Task 8** | `Resources/Info.plist`, `scripts/{generate_icon.swift,package_app.sh}`, `.github/workflows/ci.yml`, `README.md` | After Tasks 6–7 |

---

### Task 1: SwiftPM Package, Shared Core Models, Dimension Math & Live Settings Estimator

**Files:**
- Create: `Package.swift`, `.gitignore`
- Create: `Sources/BackbufferCore/Models.swift`
- Create: `Sources/BackbufferCore/SettingsStore.swift`
- Create: `Sources/BackbufferCore/CaptureDimensionCalculator.swift`
- Create: `Sources/BackbufferCore/HotKeyShortcut.swift`
- Create: `Tests/BackbufferCoreTests/TestMediaFactory.swift`
- Create: `Tests/BackbufferCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces in `BackbufferCore`:
  - `CaptureFPS` (`fps24 = 24`, `fps30 = 30`, `fps60 = 60`), `ResolutionCap` (`p720`, `p1080`, `native`), `QualityPreset` (`compact`, `balanced`, `high`, `postMaster`), `VideoCodecChoice` (`hevc`, `h264`), `BufferDurationOption` (`s15`, `s30`, `s60`, `s120`), `ShareCapOption` (`off = 0`, `mb10 = 10`, `mb20 = 20`, `mb50 = 50`; `var capBytes: Int64?`).
  - `HotKeyShortcut` (`keyCode: UInt32`, `carbonModifiers: UInt32`, `displayString: String`, `static let defaultSaveClip`).
  - `CaptureSettings` (`fps`, `resolutionCap`, `quality`, `codec`, `bufferDuration`, `shareCap`, `outputRootPath`, `saveHotKey`, `static var default`, `var mastersDirectoryURL: URL`, `var sharedDirectoryURL: URL`).
  - `CaptureSizeEstimate` (`videoBitrateBps: Int`, `audioBitrateBps: Int`, `estimatedMasterMB: Double`, `estimatedRAMBufferMB: Double`, `willAutoCompress: Bool`).
  - `BufferedVideoPacket` (`pts: CMTime`, `isKeyframe: Bool`, `sampleBuffer: CMSampleBuffer`), `BufferedAudioChunk` (`pts: CMTime`, `duration: CMTime`, `pcmData: Data`, `asbd: AudioStreamBasicDescription`, `frameCount: UInt32`), `AudioTrackInput` (`trackID: String`, `chunks: [BufferedAudioChunk]`, `aacBitrateBps: Int`).
  - `ShareStatus` (`fitsDirectly`, `compressing`, `compressed(bytes: Int64)`, `overNewCap(bytes: Int64)`, `disabled`), `ClipPairRecord`, `TrimRange` (`startSeconds: Double`, `endSeconds: Double`, `var cmTimeRange: CMTimeRange`), `BackbufferError`.
  - `SettingsStore.estimate(for: CaptureSettings, targetPixelSize: CGSize?) -> CaptureSizeEstimate` & `SettingsStore.bitratePair(...)` (applying spec 5.3 preset table, FPS scaling `0.72 / 0.82 / 1.0`, and `1.5×` multiplier when `Native` exceeds `2560×1440`).
  - `CaptureDimensionCalculator.computeTargetDimensions(logicalWidth: CGFloat, logicalHeight: CGFloat, pointPixelScale: CGFloat, cap: ResolutionCap) -> (width: Int, height: Int)`.
  - `TestMediaFactory` in `BackbufferCoreTests` (`makeNV12PixelBuffer(...)` + `makeSineAudioChunk(...)` + `makeSyntheticMP4(...)`).

- [ ] **Step 1: Write failing tests in `Tests/BackbufferCoreTests/SettingsStoreTests.swift`**
  Include:
  - `testDefaultBalanced1080p60FitsUnder20MB`: asserts `CaptureSettings.default` gives `4_500_000` video bps, `160_000` audio bps, `estimatedMasterMB` within `17.0...18.2`, and `willAutoCompress == false` under `mb20`.
  - `testPostMasterAndNative4KScaling`: asserts `postMaster` at `native` `3840×2160` scales video bps by `1.5×` (`45_000_000`) and sets `willAutoCompress == true`.
  - `testComputeTargetDimensionsOddAnd5KClamp`: asserts `(1365, 767, scale: 1.0, .native)` yields `(1364, 766)` (even dimensions), `(1512, 982, scale: 2.0, .p1080)` yields `(1662, 1080)` (physical Retina backing pixels, not `982p` logical), and `(2560, 1440, scale: 2.0, .native)` clamps to `(4096, 2304)`.
  - `testSettingsStorePersistenceRoundTrip`: saves custom `CaptureSettings` to an ephemeral `UserDefaults(suiteName:)` and reloads identically.
- [ ] **Step 2: Create `Package.swift`, `.gitignore`, and stub `BackbufferCore` types so `swift test --filter SettingsStoreTests` compiles and fails**
  Run `swift test --filter SettingsStoreTests` on `macos-15` -> Expected: FAIL assertions.
- [ ] **Step 3: Implement `Models.swift`, `SettingsStore.swift`, `CaptureDimensionCalculator.swift`, `HotKeyShortcut.swift`, and `TestMediaFactory.swift`**
  Pin exact preset numbers from spec Section 5.3 (`Compact`: 2.0/3.0/4.5 Mbps + 128k; `Balanced`: 3.0/4.5/7.0 Mbps + 160k; `High`: 6.5/10.0/15.0 Mbps + 160k; `Post Master`: 12.0/20.0/30.0 Mbps + 192k), even rounding `((Int(value) / 2) * 2)`, and `max(width, 2)` floor.
- [ ] **Step 4: Run `swift test --filter SettingsStoreTests`**
  Expected: PASS (4/4 tests green).
- [ ] **Step 5: Commit Task 1**
  `git add Package.swift .gitignore Sources/BackbufferCore Tests/BackbufferCoreTests`
  `git commit -m "feat: scaffold Backbuffer SwiftPM package and core settings models"`

---

### Task 2: Thread-Safe Keyframe-Aware RAM `ReplayRingBuffer`

**Files:**
- Create: `Sources/BackbufferCore/ReplayRingBuffer.swift`
- Create: `Tests/BackbufferCoreTests/ReplayRingBufferTests.swift`

**Interfaces:**
- Consumes: `BufferedVideoPacket`, `BufferedAudioChunk` from `Models.swift`.
- Produces:
  ```swift
  public final class ReplayRingBuffer: @unchecked Sendable {
      public init(maxBufferSeconds: Double, headroomSeconds: Double = 2.0)
      public func updateMaxBufferSeconds(_ seconds: Double)
      public func appendVideo(_ packet: BufferedVideoPacket)
      public func appendAudio(_ chunk: BufferedAudioChunk)
      public func snapshot() -> (video: [BufferedVideoPacket], audio: [BufferedAudioChunk])
      public func currentEstimatedBytes() -> Int
      public func clear()
  }
  ```

- [ ] **Step 1: Write failing tests in `Tests/BackbufferCoreTests/ReplayRingBufferTests.swift`**
  Include:
  - `testSnapshotStartsOnKeyframeAndTrimsExpiredSegments`: feeds 10s of 1s-GOP dummy `CMSampleBuffer` packets into a `4.0s` buffer; asserts `snapshot().video.first?.isKeyframe == true` and total retained span covers `4.0s` without leaking packets older than `latestVideoPTS - 6.0s`.
  - `testAudioEvictionDecoupledWhenVideoStalls`: advances `appendAudio` by `20s` with no new video frames; asserts audio count stays bounded (`<= maxBufferSeconds + 4.0s`) instead of growing unboundedly.
  - `testSnapshotClampsAudioToVideoSpan`: asserts every audio chunk in `snapshot().audio` satisfies `firstVideoPTS <= chunk.pts <= lastVideoPTS`.
  - `testSnapshotShortAndEmptyBuffer`: asserts empty ring buffer returns `([], [])`, and a `0.8s` partial capture returns all packets cleanly starting at the initial keyframe.
- [ ] **Step 2: Run `swift test --filter ReplayRingBufferTests` -> verify compile/failure**
- [ ] **Step 3: Implement `ReplayRingBuffer.swift`**
  Use `NSLock` protecting video/audio ring deques; prune expired prefix strictly up to the latest keyframe strictly before `latestVideoPTS - (maxBufferSeconds + headroomSeconds)`; decouple audio prefix eviction by `min(oldestRetainedVideoPTS, latestAudioPTS - (maxBufferSeconds + 4.0))`.
- [ ] **Step 4: Run `swift test --filter ReplayRingBufferTests`**
  Expected: PASS (4/4 tests green).
- [ ] **Step 5: Commit Task 2**

---

### Task 3: Hardware `VideoEncoder` (`VTCompressionSession` + `PixelTransferPool`) & `ClipMuxer` (`AVAssetWriter` Passthrough)

**Files:**
- Create: `Sources/BackbufferCore/VideoEncoder.swift`
- Create: `Sources/BackbufferCore/ClipMuxer.swift`
- Create: `Tests/BackbufferCoreTests/VideoEncoderAndMuxerTests.swift`

**Interfaces:**
- Consumes: `VideoCodecChoice`, `BufferedVideoPacket`, `BufferedAudioChunk`, `AudioTrackInput`, `BackbufferError` from `Models.swift`.
- Produces:
  - `PixelTransferPool`: `init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) throws` and `func copyToDetachedBuffer(_ source: CVPixelBuffer) throws -> CVPixelBuffer` (2-slot `CVPixelBufferPool` + `VTPixelTransferSession`).
  - `VideoEncoder`: `init(width: Int, height: Int, codec: VideoCodecChoice, bitrateBps: Int, maxKeyframeIntervalSeconds: Double = 1.0, onPacket: @escaping @Sendable (BufferedVideoPacket) -> Void) throws`, `func encode(_ pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime) throws`, `func flush() throws`, `func invalidate()`.
  - `ClipMuxer`: `public static func writeMP4(videoPackets: [BufferedVideoPacket], audioTracks: [AudioTrackInput], to outputURL: URL) async throws`.

- [ ] **Step 1: Write failing tests in `Tests/BackbufferCoreTests/VideoEncoderAndMuxerTests.swift`**
  Include:
  - `testEncodeAndMuxNormalizedZeroStartMP4`: encodes 60 synthetic frames @ 30fps (`2.0s`, starting at non-zero host `PTS = 4123.5s`) + matching 48 kHz sine audio chunks, calls `ClipMuxer.writeMP4(...)`, inspects result via `AVURLAsset` -> asserts file exists, 1 video track (`HEVC`), 1 audio track (`AAC`), `duration` in `1.8...2.2s`, and video track `timeRange.start == .zero`.
  - `testMuxVideoOnlyWhenAudioChunksEmpty`: passes `audioTracks: []` (or empty chunks) -> asserts valid playable `.mp4` with 1 video track and 0 broken audio tracks; passing empty `videoPackets` throws `BackbufferError.emptyBuffer`.
  - `testEncoderHandlesOddDimensionsSafely`: initializes `VideoEncoder` and `PixelTransferPool` with odd inputs `(1279, 719)` rounded via `CaptureDimensionCalculator` -> asserts zero `VTCompressionSession` error and valid keyframe packets emitted.
  - `testMultiTrackAudioSeamWritesTwoDiscreteAudioTracks`: passes two `AudioTrackInput`s (`game`, `mic`) -> asserts output `AVURLAsset` contains 2 distinct playable `.audio` tracks (`3C` readiness).
- [ ] **Step 2: Run `swift test --filter VideoEncoderAndMuxerTests` -> verify failure**
- [ ] **Step 3: Implement `VideoEncoder.swift` and `ClipMuxer.swift`**
  Important `CMSampleBuffer` timing shift in `ClipMuxer`: copy each compressed packet with `CMSampleBufferCreateCopyWithNewTiming` subtracting `firstVideoPTS` from `presentationTimeStamp` (keeping `decodeTimeStamp = .invalid` since `AllowFrameReordering == false` has no B-frames).
- [ ] **Step 4: Run `swift test --filter VideoEncoderAndMuxerTests`**
  Expected: PASS (4/4 tests green).
- [ ] **Step 5: Commit Task 3**

---

### Task 4: Non-Destructive `ClipCompressor` (Target-Byte Cap) & `ClipTrimmer` (Lossless + Compressed)

**Files:**
- Create: `Sources/BackbufferCore/ClipCompressor.swift`
- Create: `Sources/BackbufferCore/ClipTrimmer.swift`
- Create: `Tests/BackbufferCoreTests/ClipCompressorAndTrimmerTests.swift`

**Interfaces:**
- Consumes: `VideoCodecChoice`, `TrimRange`, `BackbufferError` from `Models.swift`.
- Produces:
  ```swift
  public enum ClipCompressor {
      public static func computeTargetBitrate(capBytes: Int64, durationSeconds: Double) -> (videoBps: Int, audioBps: Int, shouldDownscaleTo720p: Bool)
      public static func compressIfNeeded(masterURL: URL, outputURL: URL, capBytes: Int64, codec: VideoCodecChoice) async throws -> URL
  }
  public enum ClipTrimmer {
      public static func trimLossless(masterURL: URL, range: TrimRange, outputURL: URL) async throws -> URL
      public static func trimCompressed(masterURL: URL, range: TrimRange, outputURL: URL, capBytes: Int64, codec: VideoCodecChoice) async throws -> URL
  }
  ```

- [ ] **Step 1: Write failing tests in `Tests/BackbufferCoreTests/ClipCompressorAndTrimmerTests.swift`**
  Include:
  - `testBitrateCalculationAndSmart720pDownscale`: asserts `capBytes = 10 MB, duration = 120s` yields `shouldDownscaleTo720p == true` (`targetVideoBps < 1_200_000`), while `capBytes = 20 MB, duration = 30s` yields `shouldDownscaleTo720p == false`.
  - `testCompressorEnforcesHardByteCeilingAndPreservesMasterSHA256`: creates a synthetic noisy high-bitrate master (~4 MB over 4s), runs `compressIfNeeded(..., capBytes: 1_500_000, ...)` -> asserts `outputURL` size `<= 1_500_000` bytes AND `SHA256(masterURL)` is identical before and after.
  - `testCompressorSkipsAlreadySmallMaster`: calls `compressIfNeeded` on a `500 KB` clip with `10 MB` cap -> asserts returned URL equals `masterURL` and no redundant `outputURL` file is created.
  - `testTrimLosslessAndTrimCompressed`: trims `[1.0s, 3.0s]` from a `5.0s` synthetic clip via `trimLossless` (asserts `AVURLAsset` duration ~`2.0s`, passthrough bitrate preserved) and `trimCompressed(..., capBytes: 700_000, ...)` (asserts duration ~`2.0s` and size `<= 700_000` bytes).
- [ ] **Step 2: Run `swift test --filter ClipCompressorAndTrimmerTests` -> verify failure**
- [ ] **Step 3: Implement `ClipCompressor.swift` and `ClipTrimmer.swift`**
  Use `AVAssetReader` + `VTCompressionSession` + `AVAssetWriter` for exact target-bitrate transcoding (with one automatic `0.85×` retry if `outputBytes > capBytes`), and `AVAssetExportSession(presetName: AVAssetExportPresetPassthrough)` for `trimLossless`.
- [ ] **Step 4: Run `swift test --filter ClipCompressorAndTrimmerTests`**
  Expected: PASS (4/4 tests green).
- [ ] **Step 5: Commit Task 4**

---

### Task 5: Dual-Folder `ClipLibraryStore` & Lazy `Share Cap` Resolution (`Q7 = A`)

**Files:**
- Create: `Sources/BackbufferCore/ClipLibraryStore.swift`
- Create: `Tests/BackbufferCoreTests/ClipLibraryStoreTests.swift`

**Interfaces:**
- Consumes: `ShareCapOption`, `ShareStatus`, `ClipPairRecord`, `TrimRange`, `VideoCodecChoice` (`Models.swift`), `ClipCompressor` (`ClipCompressor.swift`).
- Produces:
  ```swift
  public final class ClipLibraryStore {
      public init(rootDirectory: URL) throws
      public var mastersDirectory: URL { get }
      public var sharedDirectory: URL { get }
      public func nextMasterURL(for date: Date = Date()) -> URL
      public func nextTrimMasterURL(from masterURL: URL, range: TrimRange) -> URL
      public func shareURL(for masterURL: URL, trimRange: TrimRange? = nil) -> URL
      public func loadClips(activeCap: ShareCapOption) async throws -> [ClipPairRecord]
      public func resolveShareClip(for record: ClipPairRecord, activeCap: ShareCapOption, codec: VideoCodecChoice) async throws -> URL
  }
  ```

- [ ] **Step 1: Write failing tests in `Tests/BackbufferCoreTests/ClipLibraryStoreTests.swift`**
  Include:
  - `testUniqueMasterURLCollisionDisambiguation`: creates `Backbuffer_2026-11-15_16-00-00.mp4` in `Masters/` and calls `nextMasterURL` with the same `Date` twice -> asserts `-2.mp4` and `-3.mp4` returned without overwriting.
  - `testTrimShareURLDoesNotOverwriteFullShareFile`: verifies `shareURL(for: master)` (`<stem>_share.mp4`) and `shareURL(for: master, trimRange: TrimRange(startSeconds: 4, endSeconds: 18))` (`<stem>_trim_04s-18s_share.mp4`) are distinct paths.
  - `testResolveShareClipLazilyRecompressesWhenCapLowered`: places a `1.6 MB` synthetic master in `Masters/` and a `1.4 MB` `_share.mp4` in `Shared/`, calls `loadClips(activeCap: .mb10)` -> first asserts `loadClips` marks `.overNewCap` or `.compressed` appropriately without modifying disk (`Q7 = A`); then tests with a cap smaller than existing `_share.mp4` (injecting a test cap override or larger synthetic `11 MB` `_share.mp4` vs `10 MB` cap) -> asserts `resolveShareClip` lazily re-encodes from `Masters/` to `<= 10 MB` while `Masters/` remains byte-for-byte untouched.
- [ ] **Step 2: Run `swift test --filter ClipLibraryStoreTests` -> verify failure**
- [ ] **Step 3: Implement `ClipLibraryStore.swift`**
  Note: expose an internal/public overload `resolveShareClip(for record: ClipPairRecord, maxCapBytes: Int64?, codec: VideoCodecChoice)` so tests run fast with `500 KB`–`1.5 MB` files without generating 25 MB synthetic videos in CI!
- [ ] **Step 4: Run `swift test --filter ClipLibraryStoreTests`**
  Expected: PASS (3/3 tests green).
- [ ] **Step 5: Commit Task 5**

---

### Task 6: macOS Capture Coordinator (`ScreenCaptureKit` + CFR Keepalive) & Global `HotKeyManager`

**Files:**
- Create: `Sources/BackbufferApp/CaptureCoordinator.swift`
- Create: `Sources/BackbufferApp/HotKeyManager.swift`

**Interfaces:**
- Consumes: `BackbufferCore` (`CaptureSettings`, `CaptureDimensionCalculator`, `PixelTransferPool`, `VideoEncoder`, `ReplayRingBuffer`, `ClipMuxer`, `HotKeyShortcut`, `BackbufferError`).
- Produces:
  - `CaptureTarget` (`enum`: `.display(SCDisplay)` / `.window(SCWindow)`), `CaptureState` (`idle`, `buffering(secondsBuffered: Double, estimatedRAMBytes: Int64)`, `paused`, `permissionDenied`, `error(String)`).
  - `CaptureCoordinator` (`@MainActor ObservableObject`): `availableTargets()`, `startCapture(target: CaptureTarget, settings: CaptureSettings)`, `stopCapture()`, `pauseBuffering()`, `resumeBuffering()`, `saveCurrentBuffer(libraryStore: ClipLibraryStore, activeCap: ShareCapOption) async throws -> URL`.
  - `HotKeyManager`: wraps Carbon `RegisterEventHotKey` / `UnregisterEventHotKey` + `InstallEventHandler` for `HotKeyShortcut`, invoking `onTrigger: () -> Void` without requiring Accessibility permissions.

- [ ] **Step 1: Implement `HotKeyManager.swift`**
  Translate `HotKeyShortcut.keyCode` & `carbonModifiers` into Carbon `EventHotKeyID`, register cleanly, and unregister on `deinit` or shortcut update.
- [ ] **Step 2: Implement `CaptureCoordinator.swift`**
  - Fetch `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`.
  - Configure `SCStreamConfiguration` using `CaptureDimensionCalculator.computeTargetDimensions`, `capturesAudio = true`, `excludesCurrentProcessAudio = true`, `minimumFrameInterval = CMTime(value: 1, timescale: Int32(settings.fps))`, `queueDepth = 6`, `pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.
  - In `SCStreamOutput`: check `SCFrameStatus.complete`, GPU-blit into `PixelTransferPool` (2-slot pool), encode immediately via `VideoEncoder`, retain ONLY the detached app `CVPixelBuffer` as `latestAppFrame` for the CFR keepalive timer (`DispatchSourceTimer` firing every `1.0 / Double(fps)` whenever no `.complete` frame arrived in the last `1.5 * frameDuration`).
  - Handle target window closure / stream error (`SCStreamDelegate.stream(_:didStopWithError:)`) cleanly by transitioning state rather than recording black frames.
- [ ] **Step 3: Build on `macos-15` via `swift build`**
  Expected: zero compiler warnings or errors across `BackbufferApp` (`CaptureCoordinator` + `HotKeyManager` compile cleanly on Swift 5.9+ macOS SDK).
- [ ] **Step 4: Commit Task 6**

---

### Task 7: Native macOS SwiftUI App, Visual Theme (`Q9`) & Retina Screenshot Preview Harness

**Files:**
- Create: `Sources/BackbufferApp/BackbufferMain.swift`
- Create: `Sources/BackbufferApp/AppViewModel.swift`
- Create: `Sources/BackbufferApp/MenuBarPopoverView.swift`
- Create: `Sources/BackbufferApp/SettingsWindowView.swift`
- Create: `Sources/BackbufferApp/LibraryTrimmerWindowView.swift`
- Create: `Sources/BackbufferApp/FilmstripTimelineView.swift`
- Create: `scripts/render_ui_previews.swift` *(offscreen `NSHostingView` Retina PNG renderer run in CI so Max sees real rendered macOS windows before signing off on visuals!)*

**Interfaces:**
- Consumes: `SettingsStore`, `ClipLibraryStore`, `ClipTrimmer`, `ClipCompressor`, `CaptureCoordinator`, `HotKeyManager`.
- Visual style & layout: Implements **Max's chosen `Q9` visual direction** verbatim across all three surfaces (Menu Bar Popover, Settings Window, Clip Library + Filmstrip Trimmer).

- [ ] **Step 1: Implement `AppViewModel.swift` and `BackbufferMain.swift`**
  Wire `@main` SwiftUI `App` with `MenuBarExtra("Backbuffer", systemImage: ...)` + `Window("Clip Library", id: "library")` + `Settings` scene, `NSPasteboard` `.MP4` file-URL writing (`Copy Share Clip`), Finder reveal (`NSWorkspace.shared.activateFileViewerSelecting`), and non-blocking toast confirmations.
- [ ] **Step 2: Implement `MenuBarPopoverView.swift` and `SettingsWindowView.swift`**
  Include live FPS (`24 / 30 / 60`), Resolution Cap (`720p / 1080p / Native`), Quality Preset (`Compact / Balanced / High / Post Master`), Codec (`HEVC / H.264`), Buffer Duration (`15s / 30s / 60s / 120s`), Share Cap (`Off / 10 MB / 20 MB / 50 MB`), hotkey recorder control, output folder picker, and real-time `Original Master (Post)` / `Share Copy (Discord)` / `RAM Ring Buffer` readout card.
- [ ] **Step 3: Implement `FilmstripTimelineView.swift` and `LibraryTrimmerWindowView.swift`**
  Extract real thumbnail strip via `AVAssetImageGenerator`, bind `AVPlayer` scrubbing to interactive start/end trim handles, show dual `Master` / `Share` status badges, and wire `Copy Share Clip`, `Reveal Original Master`, `Save Master Trim (Lossless)`, and `Copy Compressed Trim` (showing `Copy Trim (20 MB Discord)` when `Share Cap == Off`).
- [ ] **Step 4: Add `scripts/render_ui_previews.swift` & verify build + offscreen Retina PNG capture on `macos-15`**
  Build `swift build` cleanly and verify CI uploads rendered `2x` Retina screenshots (`menubar_preview.png`, `settings_preview.png`, `library_trimmer_preview.png`) using seeded sample clips from `TestMediaFactory`.
- [ ] **Step 5: Commit Task 7**

---

### Task 8: Programmatic App Icon, Universal `.dmg` Bundling, Gatekeeper Helper & GitHub Actions Release Workflow

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/generate_icon.swift`
- Create: `scripts/package_app.sh`
- Create: `.github/workflows/ci.yml`
- Create: `README.md`

- [ ] **Step 1: Create `Resources/Info.plist` and `scripts/generate_icon.swift`**
  - `Info.plist`: `CFBundleIdentifier = io.github.malachite-ore.backbuffer`, `LSMinimumSystemVersion = 13.0`, `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `CFBundleIconFile = AppIcon`, `LSApplicationCategoryType = public.app-category.video`.
  - `generate_icon.swift`: uses CoreGraphics/AppKit to render crisp `16..1024 px` PNGs for a custom Backbuffer icon and compiles `AppIcon.icns` via `iconutil -c icns` (no blank default app icon).
- [ ] **Step 2: Create `scripts/package_app.sh`**
  1. `swift build -c release --arch arm64 --arch x86_64`
  2. Assert `lipo -archs .build/apple/Products/Release/BackbufferApp` contains both `x86_64` and `arm64`.
  3. Assemble `Backbuffer.app/Contents/{MacOS,Resources}`, generate `AppIcon.icns`, copy `Info.plist`, and ad-hoc sign: `codesign --force --deep --sign - Backbuffer.app && codesign --verify --deep --strict Backbuffer.app`.
  4. Stage `dist/dmg/`: `Backbuffer.app`, symlink `/Applications`, and executable `Open First Time (Bypass Gatekeeper).command` (`#!/bin/bash` running `xattr -cr /Applications/Backbuffer.app && open /Applications/Backbuffer.app`).
  5. Run `hdiutil create -volname "Backbuffer" -srcfolder dist/dmg -ov -format UDZO dist/Backbuffer-Universal.dmg`.
- [ ] **Step 3: Create `.github/workflows/ci.yml` and `README.md`**
  - `ci.yml` on `macos-15`: runs `swift test`, executes `scripts/package_app.sh`, runs `scripts/render_ui_previews.swift` uploading UI screenshots as workflow artifacts, and publishes `dist/Backbuffer-Universal.dmg` to GitHub Releases on `v*` tags via `softprops/action-gh-release@v2` (`permissions: contents: write`).
  - `README.md`: simple 3-step install guide for Max's friend (download `.dmg`, drag to Applications, run `Open First Time` helper + grant Screen Recording permission).
- [ ] **Step 4: Run full CI pipeline on GitHub (`macos-15`) and inspect test logs + Universal `lipo` output + UI screenshot artifacts**
  Expected: 100% of `BackbufferCoreTests` pass, `lipo -archs` shows `x86_64 arm64`, `Backbuffer-Universal.dmg` builds cleanly, and UI screenshots render cleanly without clipping.
- [ ] **Step 5: Commit & tag release candidate**

---

## Self-Review Checklist (Passed)

- **Spec coverage:** Every section (`1..8` including Builder Calls and `Q7 = A` lazy Share Cap re-evaluation + `3C` `AudioTrackInput` seam + CFR keepalive + `pointPixelScale`/`4096 px` Intel guard + Gatekeeper `.command` script) maps directly to Tasks 1–8.
- **Step granularity & proportion:** Every task defines exact file paths, `Consumes`/`Produces` Swift signatures, concrete `XCTest` test names with spec constants, and exact build/test verification commands without dumping giant redundant code blocks.
- **Type consistency:** `CaptureSettings`, `CaptureSizeEstimate`, `BufferedVideoPacket`, `BufferedAudioChunk`, `AudioTrackInput`, `ClipPairRecord`, `TrimRange`, `ShareCapOption`, `ClipLibraryStore`, `ClipCompressor`, `ClipTrimmer`, `VideoEncoder`, `ClipMuxer`, and `CaptureDimensionCalculator` use identical names and parameter signatures across Tasks 1–8.
- **Review Focus coverage:** All 5 edge cases are pinned to concrete `XCTest` methods in Tasks 1, 2, 3, 4, and 5.
