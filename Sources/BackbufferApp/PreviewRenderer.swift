import AppKit
import BackbufferCore
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
enum PreviewRenderer {
    enum RenderError: LocalizedError {
        case cgImageCreationFailed(String)
        case pngEncodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .cgImageCreationFailed(let name):
                return "ImageRenderer failed to produce CGImage for \(name)"
            case .pngEncodingFailed(let name):
                return "Failed to encode PNG bytes for \(name)"
            }
        }
    }

    static func renderAll(to directoryURL: URL) throws {
        // Initialize AppKit headless graphics state safely without showing a Dock icon.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let sample = buildSampleViewModel()

        // 1. Hub Clip Library Preview
        let hubView = windowChromeFrame(
            title: "Backbuffer — Clip Library",
            subtitle: "Masters/ untouched · Shared/ Discord-ready",
            width: 1160,
            height: 682
        ) {
            LibraryTrimmerWindowView(
                viewModel: sample.hubViewModel,
                initialMode: .hub,
                isStaticPreview: true
            )
        }
        try renderPNG(
            view: hubView,
            size: CGSize(width: 1160, height: 720),
            to: directoryURL.appendingPathComponent("hub_library_preview.png")
        )

        // 2. Trimmer Theatre Preview
        let trimmerView = windowChromeFrame(
            title: "Backbuffer — Trimmer Theatre",
            subtitle: "Lossless Master Trim + Lazy Discord Copy",
            width: 1160,
            height: 702
        ) {
            LibraryTrimmerWindowView(
                viewModel: sample.trimmerViewModel,
                initialMode: .trimmer,
                isStaticPreview: true
            )
        }
        try renderPNG(
            view: trimmerView,
            size: CGSize(width: 1160, height: 740),
            to: directoryURL.appendingPathComponent("trimmer_theatre_preview.png")
        )

        // 3. Settings Preview (Video & Storage)
        let settingsView = windowChromeFrame(
            title: "Backbuffer — Studio Settings",
            subtitle: "VideoToolbox · Dual Storage · Live Estimator",
            width: 780,
            height: 582
        ) {
            SettingsWindowView(viewModel: sample.settingsVideoViewModel, isStaticPreview: true)
        }
        try renderPNG(
            view: settingsView,
            size: CGSize(width: 780, height: 620),
            to: directoryURL.appendingPathComponent("settings_preview.png")
        )

        // 4. Settings Preview (Allowed Apps Privacy Allowlist)
        let privacyAppsView = windowChromeFrame(
            title: "Backbuffer — Allowed Apps",
            subtitle: "Default-Private Allowlist · Per-App Recording",
            width: 780,
            height: 642
        ) {
            SettingsWindowView(viewModel: sample.privacyAppsViewModel, isStaticPreview: true)
        }
        try renderPNG(
            view: privacyAppsView,
            size: CGSize(width: 780, height: 680),
            to: directoryURL.appendingPathComponent("privacy_apps_preview.png")
        )

        // 5. Settings Preview (Shortcuts & Microphone)
        let shortcutsMicView = windowChromeFrame(
            title: "Backbuffer — Shortcuts & Microphone",
            subtitle: "Carbon F-Key Hotkeys · Multi-Track NLE Stems",
            width: 780,
            height: 602
        ) {
            SettingsWindowView(viewModel: sample.shortcutsMicViewModel, isStaticPreview: true)
        }
        try renderPNG(
            view: shortcutsMicView,
            size: CGSize(width: 780, height: 640),
            to: directoryURL.appendingPathComponent("shortcuts_mic_preview.png")
        )

        // 6. Menu Bar Popover Preview
        let menuBarView = menuBarShowcaseFrame {
            MenuBarPopoverView(viewModel: sample.menuBarViewModel)
        }
        try renderPNG(
            view: menuBarView,
            size: CGSize(width: 380, height: 540),
            to: directoryURL.appendingPathComponent("menubar_preview.png")
        )
    }

    // MARK: - Core ImageRenderer Export (2x Retina)

    private static func renderPNG<Content: View>(
        view: Content,
        size: CGSize,
        to fileURL: URL
    ) throws {
        let sizedView = view
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: sizedView)
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)

        guard let cgImage = renderer.cgImage else {
            throw RenderError.cgImageCreationFailed(fileURL.lastPathComponent)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed(fileURL.lastPathComponent)
        }

        try pngData.write(to: fileURL, options: .atomic)
        print("Rendered \(fileURL.lastPathComponent) (\(cgImage.width)x\(cgImage.height) px)")
    }

    // MARK: - Dark Window Chrome Frames

    private static func windowChromeFrame<Content: View>(
        title: String,
        subtitle: String,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
                    Circle().fill(Color(red: 0.15, green: 0.79, blue: 0.25)).frame(width: 11, height: 11)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("·")
                        .foregroundColor(Theme.textMuted)
                    Text(subtitle)
                        .font(Theme.mono(11, weight: .regular))
                        .foregroundColor(Theme.textSecondary)
                }

                Spacer()

                StatusPill(text: "v1.1.0", tone: .neutral, fontSize: 10)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Theme.surfaceSubtle)

            Rectangle()
                .fill(Theme.borderStrong)
                .frame(height: 1)

            content()
                .frame(width: width, height: height - 1, alignment: .top)
                .clipped()
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.borderStrong, lineWidth: 1)
        )
    }

    private static func menuBarShowcaseFrame<Content: View>(
        @ViewBuilder popover: () -> Content
    ) -> some View {
        ZStack(alignment: .top) {
            // Subtle dark desktop backdrop
            LinearGradient(
                colors: [
                    Color(red: 10.0 / 255.0, green: 12.0 / 255.0, blue: 18.0 / 255.0),
                    Color(red: 18.0 / 255.0, green: 22.0 / 255.0, blue: 32.0 / 255.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                // Simulated macOS menu bar strip
                HStack(spacing: 10) {
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.crimson)
                            .frame(width: 7, height: 7)
                        Image(systemName: "record.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.amber)
                        Text("Backbuffer")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.amber.opacity(0.65), lineWidth: 1)
                    )

                    Text("Wi-Fi  100%  Sun 22:15")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.black.opacity(0.55))

                // Real MenuBarPopoverView
                popover()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.borderStrong, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.6), radius: 18, x: 0, y: 10)

                Spacer()
            }
        }
    }

    // MARK: - Synthetic Sample Clips & Game Artwork

    private struct SampleBundle {
        let hubViewModel: AppViewModel
        let trimmerViewModel: AppViewModel
        let settingsVideoViewModel: AppViewModel
        let privacyAppsViewModel: AppViewModel
        let shortcutsMicViewModel: AppViewModel
        let menuBarViewModel: AppViewModel
    }

    private static func buildSampleViewModel() -> SampleBundle {
        let now = Date(timeIntervalSince1970: 1_794_780_848) // Nov 15, 2026
        let mastersDir = URL(fileURLWithPath: "/Users/player/Movies/Backbuffer/Masters", isDirectory: true)
        let sharedDir = URL(fileURLWithPath: "/Users/player/Movies/Backbuffer/Shared", isDirectory: true)

        let valorantMaster = mastersDir.appendingPathComponent("Backbuffer_2026-11-15_22-14-08.mp4")
        let valorantShare = sharedDir.appendingPathComponent("Backbuffer_2026-11-15_22-14-08_share.mp4")
        let minecraftMaster = mastersDir.appendingPathComponent("Backbuffer_2026-11-15_21-48-19.mp4")
        let eldenMaster = mastersDir.appendingPathComponent("Backbuffer_2026-11-15_20-32-55.mp4")
        let eldenShare = sharedDir.appendingPathComponent("Backbuffer_2026-11-15_20-32-55_share.mp4")
        let rocketMaster = mastersDir.appendingPathComponent("Backbuffer_2026-11-15_19-11-03.mp4")

        let clips: [ClipPairRecord] = [
            ClipPairRecord(
                masterURL: valorantMaster,
                shareURL: valorantShare,
                createdAt: now,
                durationSeconds: 30.0,
                width: 1920,
                height: 1080,
                fps: 60,
                codecName: "HEVC",
                masterBytes: 38_100_000,
                shareStatus: .compressed(bytes: 18_400_000),
                displayTitle: "Valorant — Ascent 1v4 Clutch"
            ),
            ClipPairRecord(
                masterURL: minecraftMaster,
                shareURL: nil,
                createdAt: now.addingTimeInterval(-1540),
                durationSeconds: 30.0,
                width: 1920,
                height: 1080,
                fps: 60,
                codecName: "HEVC",
                masterBytes: 17_500_000,
                shareStatus: .fitsDirectly,
                displayTitle: "Minecraft — Ender Pearl Trap"
            ),
            ClipPairRecord(
                masterURL: eldenMaster,
                shareURL: eldenShare,
                createdAt: now.addingTimeInterval(-6080),
                durationSeconds: 60.0,
                width: 2560,
                height: 1440,
                fps: 60,
                codecName: "HEVC",
                masterBytes: 64_200_000,
                shareStatus: .overNewCap(bytes: 28_600_000),
                displayTitle: "Elden Ring — Malenia No-Hit"
            ),
            ClipPairRecord(
                masterURL: rocketMaster,
                shareURL: nil,
                createdAt: now.addingTimeInterval(-10985),
                durationSeconds: 15.0,
                width: 1920,
                height: 1080,
                fps: 60,
                codecName: "H.264",
                masterBytes: 9_800_000,
                shareStatus: .fitsDirectly,
                displayTitle: "Rocket League — OT Ceiling Shot"
            )
        ]

        let thumbs: [String: NSImage] = [
            clips[0].id: makeGameSceneArtwork(theme: .valorant, phase: 0.45, width: 640, height: 360),
            clips[1].id: makeGameSceneArtwork(theme: .minecraft, phase: 0.35, width: 640, height: 360),
            clips[2].id: makeGameSceneArtwork(theme: .eldenRing, phase: 0.60, width: 640, height: 360),
            clips[3].id: makeGameSceneArtwork(theme: .rocketLeague, phase: 0.50, width: 640, height: 360)
        ]

        let valorantFilmstrip: [NSImage] = (0..<10).map { idx in
            makeGameSceneArtwork(
                theme: .valorant,
                phase: Double(idx) / 9.0,
                width: 240,
                height: 135
            )
        }

        let targets: [CaptureTargetOption] = [
            CaptureTargetOption(
                id: "display-main",
                title: "Built-in Retina Display",
                subtitle: "1512×982 pts · 1080p60",
                isDisplay: true
            ),
            CaptureTargetOption(
                id: "window-valorant",
                title: "VALORANT — Riot Client",
                subtitle: "Game Window · 1920×1080",
                isDisplay: false
            ),
            CaptureTargetOption(
                id: "window-minecraft",
                title: "Minecraft 1.21.11",
                subtitle: "Java Edition · 1920×1080",
                isDisplay: false
            )
        ]

        let allowedIDs: Set<String> = [
            "com.riotgames.valorant",
            "com.mojang.minecraft"
        ]
        let rememberedApps: [RememberedAppInfo] = [
            RememberedAppInfo(bundleIdentifier: "com.riotgames.valorant", displayName: "VALORANT"),
            RememberedAppInfo(bundleIdentifier: "com.mojang.minecraft", displayName: "Minecraft")
        ]

        let sampleApps: [RunningAppCandidate] = [
            RunningAppCandidate(bundleIdentifier: "com.riotgames.valorant", displayName: "VALORANT", isRunning: true, windowCount: 1),
            RunningAppCandidate(bundleIdentifier: "com.mojang.minecraft", displayName: "Minecraft", isRunning: true, windowCount: 1),
            RunningAppCandidate(bundleIdentifier: "com.hnc.Discord", displayName: "Discord", isRunning: true, windowCount: 1),
            RunningAppCandidate(bundleIdentifier: "com.valvesoftware.steam", displayName: "Steam", isRunning: true, windowCount: 1),
            RunningAppCandidate(bundleIdentifier: "com.apple.Safari", displayName: "Safari", isRunning: true, windowCount: 3)
        ]

        let sampleMics: [MicrophoneDeviceOption] = [
            MicrophoneDeviceOption(
                id: "mic-shure-mv7",
                name: "Shure MV7 USB Microphone",
                isDefault: true,
                localizedDetail: "USB Audio · System Default"
            ),
            MicrophoneDeviceOption(
                id: "mic-macbook-pro",
                name: "MacBook Pro Microphone",
                isDefault: false,
                localizedDetail: "Built-in Microphone"
            )
        ]

        let baseSettings = CaptureSettings(
            fps: .fps60,
            resolutionCap: .p1080,
            quality: .balanced,
            codec: .hevc,
            bufferDuration: .s30,
            shareCap: .mb20,
            outputRootPath: "~/Movies/Backbuffer",
            saveHotKey: .f8Preset,
            togglePauseHotKey: .f9Preset,
            playSoundOnSave: true,
            recordMicrophone: true,
            selectedMicrophoneID: "mic-shure-mv7",
            microphoneGain: 1.15,
            isMicrophoneMuted: false,
            separateAudioTracksInMaster: true,
            privacyMode: .strictAllowlist,
            allowedAppBundleIDs: allowedIDs,
            blockedAppBundleIDs: [],
            rememberedApps: rememberedApps
        )

        let hubVM = AppViewModel.makePreviewSample(
            settings: baseSettings,
            clips: clips,
            selectedClipID: clips[0].id,
            trimRange: TrimRange(startSeconds: 4.0, endSeconds: 22.0),
            playheadSeconds: 12.4,
            thumbnailsByClipID: thumbs,
            filmstripByClipID: [clips[0].id: valorantFilmstrip],
            targetOptions: targets,
            selectedTargetID: targets[1].id,
            captureState: .buffering(secondsBuffered: 30.0, estimatedRAMBytes: 18_700_000),
            toast: nil,
            selectedSettingsTab: .videoAndStorage,
            previewApps: sampleApps,
            previewMicDevices: sampleMics,
            previewMicLevel: 0.68,
            previewMicPermission: .authorized,
            activeCaptureSummary: "Buffering VALORANT (2 allowed)"
        )

        let trimmerVM = AppViewModel.makePreviewSample(
            settings: baseSettings,
            clips: clips,
            selectedClipID: clips[0].id,
            trimRange: TrimRange(startSeconds: 4.0, endSeconds: 22.0),
            playheadSeconds: 12.4,
            thumbnailsByClipID: thumbs,
            filmstripByClipID: [clips[0].id: valorantFilmstrip],
            targetOptions: targets,
            selectedTargetID: targets[1].id,
            captureState: .buffering(secondsBuffered: 30.0, estimatedRAMBytes: 18_700_000),
            toast: ToastBanner(tone: .success, message: "Copied Backbuffer_2026-11-15_22-14-08_share.mp4 (18.4 MB) — ready for Discord ⌘V"),
            selectedSettingsTab: .videoAndStorage,
            previewApps: sampleApps,
            previewMicDevices: sampleMics,
            previewMicLevel: 0.68,
            previewMicPermission: .authorized,
            activeCaptureSummary: "Buffering VALORANT (2 allowed)"
        )

        let settingsVideoVM = AppViewModel.makePreviewSample(
            settings: baseSettings,
            clips: clips,
            selectedClipID: clips[0].id,
            trimRange: TrimRange(startSeconds: 4.0, endSeconds: 22.0),
            playheadSeconds: 12.4,
            thumbnailsByClipID: thumbs,
            filmstripByClipID: [clips[0].id: valorantFilmstrip],
            targetOptions: targets,
            selectedTargetID: targets[1].id,
            captureState: .buffering(secondsBuffered: 30.0, estimatedRAMBytes: 18_700_000),
            toast: nil,
            selectedSettingsTab: .videoAndStorage,
            previewApps: sampleApps,
            previewMicDevices: sampleMics,
            previewMicLevel: 0.68,
            previewMicPermission: .authorized,
            activeCaptureSummary: "Buffering VALORANT + 1 allowed app"
        )

        let privacyAppsVM = AppViewModel.makePreviewSample(
            settings: baseSettings,
            clips: clips,
            selectedClipID: clips[0].id,
            trimRange: TrimRange(startSeconds: 4.0, endSeconds: 22.0),
            playheadSeconds: 12.4,
            thumbnailsByClipID: thumbs,
            filmstripByClipID: [clips[0].id: valorantFilmstrip],
            targetOptions: targets,
            selectedTargetID: targets[1].id,
            captureState: .buffering(secondsBuffered: 30.0, estimatedRAMBytes: 18_700_000),
            toast: nil,
            selectedSettingsTab: .privacy,
            previewApps: sampleApps,
            previewMicDevices: sampleMics,
            previewMicLevel: 0.68,
            previewMicPermission: .authorized,
            activeCaptureSummary: "2 Allowed Apps · 2 Open"
        )

        let shortcutsMicVM = AppViewModel.makePreviewSample(
            settings: baseSettings,
            clips: clips,
            selectedClipID: clips[0].id,
            trimRange: TrimRange(startSeconds: 4.0, endSeconds: 22.0),
            playheadSeconds: 12.4,
            thumbnailsByClipID: thumbs,
            filmstripByClipID: [clips[0].id: valorantFilmstrip],
            targetOptions: targets,
            selectedTargetID: targets[1].id,
            captureState: .buffering(secondsBuffered: 30.0, estimatedRAMBytes: 18_700_000),
            toast: nil,
            selectedSettingsTab: .shortcutsAndMic,
            previewApps: sampleApps,
            previewMicDevices: sampleMics,
            previewMicLevel: 0.68,
            previewMicPermission: .authorized,
            activeCaptureSummary: "Save F8 · Shure MV7 Active"
        )

        let menuBarVM = AppViewModel.makePreviewSample(
            settings: baseSettings,
            clips: clips,
            selectedClipID: clips[0].id,
            trimRange: TrimRange(startSeconds: 4.0, endSeconds: 22.0),
            playheadSeconds: 12.4,
            thumbnailsByClipID: thumbs,
            filmstripByClipID: [clips[0].id: valorantFilmstrip],
            targetOptions: targets,
            selectedTargetID: targets[1].id,
            captureState: .buffering(secondsBuffered: 27.4, estimatedRAMBytes: 18_700_000),
            toast: ToastBanner(tone: .success, message: "Saved Master (38.1 MB · Mix + 2 NLE Stems)"),
            selectedSettingsTab: .privacy,
            previewApps: sampleApps,
            previewMicDevices: sampleMics,
            previewMicLevel: 0.68,
            previewMicPermission: .authorized,
            activeCaptureSummary: "Buffering VALORANT (2 allowed)"
        )

        return SampleBundle(
            hubViewModel: hubVM,
            trimmerViewModel: trimmerVM,
            settingsVideoViewModel: settingsVideoVM,
            privacyAppsViewModel: privacyAppsVM,
            shortcutsMicViewModel: shortcutsMicVM,
            menuBarViewModel: menuBarVM
        )
    }

    private enum ArtworkTheme {
        case valorant
        case minecraft
        case eldenRing
        case rocketLeague
    }

    private static func makeGameSceneArtwork(
        theme: ArtworkTheme,
        phase: Double,
        width: Int,
        height: Int
    ) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1))
        ctx.fill(rect)

        switch theme {
        case .valorant:
            let colors = [
                CGColor(red: 0.11, green: 0.09, blue: 0.18, alpha: 1),
                CGColor(red: 0.34, green: 0.14, blue: 0.24, alpha: 1),
                CGColor(red: 0.85, green: 0.34, blue: 0.23, alpha: 1)
            ] as CFArray
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.55, 1.0]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: h * 0.2), options: [])
            }
            // Architectural site monoliths
            ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.13, alpha: 0.92))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.30))
            ctx.fill(CGRect(x: w * 0.06, y: h * 0.28, width: w * 0.20, height: h * 0.50))
            ctx.fill(CGRect(x: w * 0.68, y: h * 0.25, width: w * 0.24, height: h * 0.58))
            // Tactical laser/flash sweep modulated by phase
            let flashX = w * (0.34 + 0.26 * CGFloat(phase))
            let flashY = h * 0.48
            ctx.setFillColor(CGColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 0.45))
            ctx.fillEllipse(in: CGRect(x: flashX - 42, y: flashY - 42, width: 84, height: 84))
            // Crisp cyan crosshair at center
            ctx.setStrokeColor(CGColor(red: 0.25, green: 0.95, blue: 0.85, alpha: 0.95))
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: w * 0.5 - 10, y: h * 0.5))
            ctx.addLine(to: CGPoint(x: w * 0.5 - 3, y: h * 0.5))
            ctx.move(to: CGPoint(x: w * 0.5 + 3, y: h * 0.5))
            ctx.addLine(to: CGPoint(x: w * 0.5 + 10, y: h * 0.5))
            ctx.move(to: CGPoint(x: w * 0.5, y: h * 0.5 - 10))
            ctx.addLine(to: CGPoint(x: w * 0.5, y: h * 0.5 - 3))
            ctx.move(to: CGPoint(x: w * 0.5, y: h * 0.5 + 3))
            ctx.addLine(to: CGPoint(x: w * 0.5, y: h * 0.5 + 10))
            ctx.strokePath()
            // HUD health & ability bar silhouette
            ctx.setFillColor(CGColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.82))
            ctx.fill(CGRect(x: w * 0.34, y: h * 0.06, width: w * 0.32, height: h * 0.08))
            ctx.setFillColor(CGColor(red: 0.18, green: 0.88, blue: 0.58, alpha: 0.9))
            ctx.fill(CGRect(x: w * 0.355, y: h * 0.085, width: w * 0.12, height: h * 0.03))

        case .minecraft:
            let colors = [
                CGColor(red: 0.11, green: 0.28, blue: 0.45, alpha: 1),
                CGColor(red: 0.48, green: 0.34, blue: 0.58, alpha: 1),
                CGColor(red: 0.95, green: 0.65, blue: 0.24, alpha: 1)
            ] as CFArray
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.65, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
            }
            // Voxel terrain blocks
            let cols = 12
            let blockW = w / CGFloat(cols)
            for c in 0..<cols {
                let elev = 0.26 + 0.08 * sin(Double(c) * 0.9 + phase * 3.0)
                let terrainH = h * CGFloat(elev)
                ctx.setFillColor(CGColor(red: 0.14, green: 0.22, blue: 0.15, alpha: 1))
                ctx.fill(CGRect(x: CGFloat(c) * blockW, y: 0, width: blockW + 1, height: terrainH))
                ctx.setFillColor(CGColor(red: 0.24, green: 0.64, blue: 0.31, alpha: 1))
                ctx.fill(CGRect(x: CGFloat(c) * blockW, y: terrainH - blockW * 0.28, width: blockW + 1, height: blockW * 0.28))
            }
            // Nether/End portal silhouette
            ctx.setFillColor(CGColor(red: 0.12, green: 0.08, blue: 0.16, alpha: 1))
            ctx.fill(CGRect(x: w * 0.42, y: h * 0.28, width: w * 0.16, height: h * 0.42))
            ctx.setFillColor(CGColor(red: 0.68, green: 0.24, blue: 0.92, alpha: 0.85))
            ctx.fill(CGRect(x: w * 0.445, y: h * 0.32, width: w * 0.11, height: h * 0.33))
            // Hotbar HUD
            ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 0.85))
            ctx.fill(CGRect(x: w * 0.28, y: h * 0.05, width: w * 0.44, height: h * 0.08))

        case .eldenRing:
            let colors = [
                CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1),
                CGColor(red: 0.22, green: 0.11, blue: 0.10, alpha: 1),
                CGColor(red: 0.56, green: 0.34, blue: 0.14, alpha: 1)
            ] as CFArray
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.58, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
            }
            // Golden Erdtree / scarlet aura arc
            ctx.setFillColor(CGColor(red: 0.96, green: 0.68, blue: 0.22, alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: w * 0.58, y: h * 0.34, width: w * 0.26, height: w * 0.26))
            ctx.setFillColor(CGColor(red: 0.08, green: 0.06, blue: 0.07, alpha: 0.92))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.24))
            // Boss health bar at bottom
            ctx.setFillColor(CGColor(red: 0.15, green: 0.05, blue: 0.06, alpha: 0.9))
            ctx.fill(CGRect(x: w * 0.14, y: h * 0.10, width: w * 0.72, height: h * 0.035))
            ctx.setFillColor(CGColor(red: 0.85, green: 0.20, blue: 0.22, alpha: 0.95))
            ctx.fill(CGRect(x: w * 0.14, y: h * 0.10, width: w * 0.28, height: h * 0.035))

        case .rocketLeague:
            let colors = [
                CGColor(red: 0.06, green: 0.12, blue: 0.24, alpha: 1),
                CGColor(red: 0.10, green: 0.26, blue: 0.42, alpha: 1),
                CGColor(red: 0.09, green: 0.42, blue: 0.32, alpha: 1)
            ] as CFArray
            if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 0.55, 1]) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
            }
            // Stadium floodlights & neon boost arc
            ctx.setStrokeColor(CGColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 0.9))
            ctx.setLineWidth(5)
            ctx.move(to: CGPoint(x: w * 0.12, y: h * 0.20))
            ctx.addQuadCurve(
                to: CGPoint(x: w * 0.66, y: h * 0.62),
                control: CGPoint(x: w * 0.42, y: h * 0.82)
            )
            ctx.strokePath()
            // Glowing soccer ball
            ctx.setFillColor(CGColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 0.95))
            ctx.fillEllipse(in: CGRect(x: w * 0.64, y: h * 0.56, width: 34, height: 34))
            // Scoreboard pill top center
            ctx.setFillColor(CGColor(red: 0.05, green: 0.07, blue: 0.11, alpha: 0.85))
            ctx.fill(CGRect(x: w * 0.38, y: h * 0.86, width: w * 0.24, height: h * 0.08))
        }

        guard let cgImage = ctx.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
