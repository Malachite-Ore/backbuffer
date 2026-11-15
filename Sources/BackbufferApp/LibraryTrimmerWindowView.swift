import AppKit
import AVFoundation
import AVKit
import BackbufferCore
import SwiftUI

enum LibraryDisplayMode: String, CaseIterable {
    case hub
    case trimmer

    var label: String {
        switch self {
        case .hub: return "Clip Hub"
        case .trimmer: return "Trimmer Theatre"
        }
    }
}

struct LibraryTrimmerWindowView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    private let isStaticPreview: Bool
    @State private var displayMode: LibraryDisplayMode
    @State private var hoveredClipID: String?

    init(
        viewModel: AppViewModel,
        initialMode: LibraryDisplayMode = .hub,
        isStaticPreview: Bool = false
    ) {
        self.viewModel = viewModel
        self.isStaticPreview = isStaticPreview
        self._displayMode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            topToolbar

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            liveCaptureStrip

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            if case .awaitingAllowedApps(let allowedCount) = viewModel.effectiveCaptureState {
                privacyLockBanner(allowedCount: allowedCount)
            }

            Group {
                switch displayMode {
                case .hub:
                    hubGridBody
                case .trimmer:
                    trimmerTheatreBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let toast = viewModel.toast {
                toastFooterBar(toast)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear {
            guard !isStaticPreview else { return }
            viewModel.onRequestOpenSettingsWindow = {
                openWindow(id: "settings")
            }
        }
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.amber)
                Text("Backbuffer Library")
                    .font(.system(size: 15, weight: .bold))
                StatusPill(
                    text: "\(viewModel.clips.count) Clips",
                    tone: .neutral,
                    fontSize: 10.5
                )
            }

            if let capBytes = viewModel.settings.shareCap.capBytes {
                StatusPill(
                    text: "Share Cap: \(capBytes / 1_000_000) MB",
                    tone: .emerald,
                    fontSize: 10.5
                )
            } else {
                StatusPill(
                    text: "Share Cap: Off",
                    tone: .neutral,
                    fontSize: 10.5
                )
            }

            Spacer()

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textMuted)
                if isStaticPreview {
                    Text(
                        viewModel.librarySearchText.isEmpty
                            ? "Filter clips, codec, resolution..."
                            : viewModel.librarySearchText
                    )
                    .font(.system(size: 12))
                    .foregroundColor(
                        viewModel.librarySearchText.isEmpty
                            ? Theme.textMuted
                            : Theme.textPrimary
                    )
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)
                } else {
                    TextField("Filter clips, codec, resolution...", text: $viewModel.librarySearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                        .frame(width: 160)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )

            // View mode switch
            HStack(spacing: 3) {
                ForEach(LibraryDisplayMode.allCases, id: \.self) { mode in
                    Button {
                        displayMode = mode
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: mode == .hub ? "square.grid.2x2" : "scissors")
                                .font(.system(size: 11, weight: .semibold))
                            Text(mode.label)
                                .font(.system(size: 11.5, weight: displayMode == mode ? .semibold : .medium))
                        }
                        .foregroundColor(displayMode == mode ? Theme.amberInk : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(displayMode == mode ? Theme.amber : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )

            Button {
                Task {
                    await viewModel.reloadClips()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Refresh")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Settings")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.surfaceSubtle)
    }

    // MARK: - Live Capture Strip

    private var liveCaptureStrip: some View {
        let state = viewModel.effectiveCaptureState

        return HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(captureDotColor)
                    .frame(width: 8, height: 8)
                Text(verbatim: captureStripStatusText)
                    .font(Theme.mono(11.5, weight: .semibold))
                    .foregroundColor(
                        state == .permissionDenied
                            ? Theme.crimson
                            : (viewModel.isPrivacyLocked ? Theme.amber : Theme.textPrimary)
                    )
                    .lineLimit(1)
            }

            if state != .permissionDenied {
                let targetTitle = viewModel.selectedTargetOption?.title ?? "Main Display"
                let targetIcon = viewModel.selectedTargetOption?.systemImageName ?? "display"

                if isStaticPreview {
                    targetSelectorPill(title: targetTitle, systemImage: targetIcon)
                } else {
                    Menu {
                        ForEach(viewModel.targetOptions) { option in
                            Button {
                                Task {
                                    await viewModel.selectCaptureTarget(option)
                                }
                            } label: {
                                Label {
                                    Text(verbatim: option.title)
                                } icon: {
                                    Image(systemName: option.systemImageName)
                                }
                            }
                        }

                        if !viewModel.targetOptions.isEmpty {
                            Divider()
                        }

                        Button("Refresh Targets") {
                            Task {
                                await viewModel.refreshTargetsAndAutoStart()
                            }
                        }
                    } label: {
                        targetSelectorPill(title: targetTitle, systemImage: targetIcon)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 8)

            if state == .permissionDenied {
                Button {
                    viewModel.captureCoordinator.requestScreenCapturePermission()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Grant Screen Recording")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .buttonStyle(AmberCTAButtonStyle(compact: true))

                Button {
                    Task {
                        await viewModel.refreshTargetsAndAutoStart()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Check Again")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
            } else if case .awaitingAllowedApps = state {
                Button {
                    viewModel.openSettings(tab: .privacy)
                    openWindow(id: "settings")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Choose Allowed Apps...")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .buttonStyle(AmberCTAButtonStyle(compact: true))

                Button {
                    Task {
                        await viewModel.refreshTargetsAndAutoStart()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
            } else {
                // Allowed Apps quick jump
                Button {
                    viewModel.openSettings(tab: .privacy)
                    openWindow(id: "settings")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(viewModel.settings.privacyMode == .strictAllowlist ? Theme.emerald : Theme.amber)
                        Text(verbatim: viewModel.settings.privacyMode == .strictAllowlist
                             ? "\(viewModel.allowedAppCount) Apps"
                             : "All Except Blocked")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                .help("Configure which games and apps Backbuffer may record")

                // Quick Mic mute/enable toggle
                Button {
                    if !viewModel.settings.recordMicrophone {
                        viewModel.toggleMicrophone()
                    } else {
                        viewModel.toggleMicrophoneMute()
                    }
                } label: {
                    HStack(spacing: 4) {
                        let micActive = viewModel.settings.recordMicrophone && !viewModel.settings.isMicrophoneMuted
                        Image(systemName: micActive ? "mic.fill" : "mic.slash.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(
                                !viewModel.settings.recordMicrophone
                                    ? Theme.textMuted
                                    : (viewModel.settings.isMicrophoneMuted ? Theme.amber : Theme.emerald)
                            )
                        Text(verbatim: !viewModel.settings.recordMicrophone
                             ? "Mic Off"
                             : (viewModel.settings.isMicrophoneMuted ? "Muted" : "Mic On"))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                .help("Toggle microphone capture or mute")

                Button {
                    Task {
                        await viewModel.toggleRecordingPause()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.isActivelyBuffering ? "pause.fill" : "play.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(captureToggleTitle)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

                if isStaticPreview {
                    HStack(spacing: 5) {
                        Text("Save")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                        Text(verbatim: viewModel.settings.saveHotKey.displayString)
                            .font(Theme.mono(11, weight: .bold))
                            .foregroundColor(Theme.amber)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.borderStrong, lineWidth: 1)
                    )
                } else {
                    HotKeyRecorderControl(
                        title: "Save",
                        shortcut: viewModel.settings.saveHotKey,
                        allowClear: false,
                        compact: true
                    ) { newShortcut in
                        if let newShortcut {
                            viewModel.updateSaveHotKey(newShortcut)
                        }
                    }
                }

                Button {
                    Task {
                        await viewModel.saveClipNow()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Save Clip")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                }
                .buttonStyle(AmberCTAButtonStyle(compact: true))
                .disabled(!state.isActivelyBuffering || viewModel.captureCoordinator.isSaving)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surfaceCard)
    }

    private func privacyLockBanner(allowedCount: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.amber)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    allowedCount == 0
                        ? "Privacy Lock Active · Capture Paused Until You Allow an App"
                        : "Waiting for an Allowed App · Capture Paused"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textPrimary)

                Text(
                    allowedCount == 0
                        ? "No apps are on your allowlist yet. Backbuffer never captures your screen until you allow at least one game or app."
                        : "None of your \(allowedCount) allowed app\(allowedCount == 1 ? "" : "s") currently has an open window. Launch one or add another app."
                )
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                viewModel.openSettings(tab: .privacy)
                openWindow(id: "settings")
            } label: {
                Text("Choose Allowed Apps...")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(AmberCTAButtonStyle(compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.amberSoft)
        .overlay(
            Rectangle()
                .fill(Theme.amber.opacity(0.32))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private func targetSelectorPill(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.amber)
            Text(verbatim: title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(Theme.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.borderStrong, lineWidth: 1)
        )
    }

    private var captureDotColor: Color {
        switch viewModel.effectiveCaptureState {
        case .buffering, .permissionDenied, .error:
            return Theme.crimson
        case .paused, .awaitingAllowedApps:
            return Theme.amber
        case .idle:
            return Theme.textMuted
        }
    }

    private var captureStripStatusText: String {
        switch viewModel.effectiveCaptureState {
        case .buffering(let sec, let bytes):
            let ram = bytes > 0 ? Theme.formatMB(bytes) : "~\(Theme.formatMB(viewModel.estimate.estimatedRAMBufferMB))"
            return "REC · \(Int(sec.rounded()))s / \(viewModel.settings.bufferDuration.rawValue)s · \(ram) RAM"
        case .paused:
            return "PAUSED · Buffer Held"
        case .permissionDenied:
            return "Screen Recording Permission Needed"
        case .awaitingAllowedApps(let allowedCount):
            if allowedCount == 0 {
                return "PRIVACY LOCK · 0 Allowed Apps"
            }
            return "WAITING · Launch Allowed App"
        case .error(let msg):
            return "Capture Error: \(msg)"
        case .idle:
            return "Idle · Ready to Buffer"
        }
    }

    private var captureToggleTitle: String {
        switch viewModel.effectiveCaptureState {
        case .buffering:
            return "Pause"
        case .paused:
            return "Resume"
        default:
            return "Start"
        }
    }

    // MARK: - Mode 1: 16:9 Clip Hub Grid

    private var hubGridBody: some View {
        Group {
            if viewModel.filteredClips.isEmpty {
                emptyLibraryView
            } else if isStaticPreview {
                VStack(alignment: .leading, spacing: 0) {
                    staticPreviewHubGrid
                    Spacer(minLength: 0)
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 14),
                            GridItem(.flexible(), spacing: 14)
                        ],
                        spacing: 14
                    ) {
                        ForEach(viewModel.filteredClips) { clip in
                            hubClipCard(clip)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var staticPreviewHubGrid: some View {
        let clips = viewModel.filteredClips
        let rows = stride(from: 0, to: clips.count, by: 2).map { start in
            Array(clips[start..<min(start + 2, clips.count)])
        }

        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(row) { clip in
                        hubClipCard(clip)
                    }
                    if row.count == 1 {
                        Color.clear
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
    }

    private func hubClipCard(_ clip: ClipPairRecord) -> some View {
        let isHovered = hoveredClipID == clip.id
        let isSelected = viewModel.selectedClip?.id == clip.id
        let status = viewModel.effectiveShareStatus(for: clip)

        return HStack(spacing: 0) {
            // 16:9 Thumbnail Left Column (240 x 135)
            ZStack {
                thumbnailImage(for: clip)
                    .frame(width: 240, height: 135)
                    .clipped()

                LinearGradient(
                    colors: [Color.black.opacity(0.12), Color.black.opacity(0.68)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack {
                    HStack {
                        StatusPill(
                            text: "\(clip.height)p\(Int(clip.fps.rounded())) · \(clip.codecName)",
                            tone: .neutral,
                            fontSize: 9.5
                        )
                        Spacer()
                        Text(Theme.formatDuration(clip.durationSeconds))
                            .font(Theme.mono(10.5, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.black.opacity(0.78))
                            )
                    }
                    Spacer()
                    if isHovered {
                        HStack(spacing: 6) {
                            Image(systemName: "scissors")
                                .font(.system(size: 10, weight: .bold))
                            Text("Open Trimmer")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundColor(Theme.amberInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Theme.amber)
                        )
                        .padding(.bottom, 4)
                    }
                }
                .padding(8)
            }
            .frame(width: 240, height: 135)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.selectClip(clip)
                displayMode = .trimmer
            }

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)

            // Right Metadata, Storage Badges & Actions
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(clip.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: formattedTimestamp(clip.createdAt))
                        .font(Theme.mono(10, weight: .regular))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }

                Text(verbatim: "\(clip.resolutionLabel) · \(Int(clip.fps.rounded())) FPS · \(clip.codecName)")
                    .font(Theme.mono(10.5, weight: .regular))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 3)

                HStack(spacing: 6) {
                    StatusPill(
                        text: "Master: \(Theme.formatMB(clip.masterBytes))",
                        icon: "film",
                        tone: .neutral,
                        fontSize: 10
                    )
                    shareStatusBadge(for: clip, status: status, compact: true)
                }
                .padding(.top, 10)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Button {
                        Task {
                            await viewModel.copyShareClip(clip)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(copyButtonTitle(for: status))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AmberCTAButtonStyle(compact: true))
                    .disabled(status == .compressing)

                    Button {
                        viewModel.selectClip(clip)
                        displayMode = .trimmer
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "scissors")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("Trim")
                        }
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

                    Button {
                        viewModel.revealMaster(clip)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                    .help("Reveal original Master in Finder")
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 135)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.surfaceCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isSelected || isHovered ? Theme.amber.opacity(0.65) : Theme.border,
                    lineWidth: 1
                )
        )
        .onHover { hovering in
            hoveredClipID = hovering ? clip.id : (hoveredClipID == clip.id ? nil : hoveredClipID)
        }
    }

    // MARK: - Mode 2: Trimmer Theatre

    private var trimmerTheatreBody: some View {
        HStack(spacing: 0) {
            leftClipRail
                .frame(width: 256)
                .background(Theme.surfaceSubtle)

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)

            if let selected = viewModel.selectedClip {
                trimmerInspectorStage(selected)
            } else {
                emptyLibraryView
            }
        }
    }

    private var leftClipRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT CLIPS")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Text("\(viewModel.filteredClips.count)")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if isStaticPreview {
                railClipsListContent
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    railClipsListContent
                }
            }
        }
    }

    private var railClipsListContent: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.filteredClips) { clip in
                let isSelected = clip.id == viewModel.selectedClip?.id
                let status = viewModel.effectiveShareStatus(for: clip)

                Button {
                    viewModel.selectClip(clip)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Color.clear
                                .frame(width: 68, height: 38)
                                .overlay(thumbnailImage(for: clip))
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Theme.border, lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.displayTitle)
                                    .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(verbatim: "\(Theme.formatDuration(clip.durationSeconds)) · \(clip.height)p\(Int(clip.fps.rounded()))")
                                    .font(Theme.mono(10.5, weight: .regular))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }

                        HStack(spacing: 5) {
                            StatusPill(
                                text: "M: \(Theme.formatMB(clip.masterBytes))",
                                tone: .neutral,
                                fontSize: 9.5
                            )
                            shareStatusBadge(for: clip, status: status, compact: true)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Theme.surfaceElevated : Theme.surfaceCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                isSelected ? Theme.amber : Theme.border,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func trimmerInspectorStage(_ clip: ClipPairRecord) -> some View {
        if isStaticPreview {
            VStack(alignment: .leading, spacing: 0) {
                trimmerInspectorContent(clip)
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                trimmerInspectorContent(clip)
            }
        }
    }

    private func trimmerInspectorContent(_ clip: ClipPairRecord) -> some View {
        let status = viewModel.effectiveShareStatus(for: clip)
        let trimMasterEstMB = viewModel.estimatedTrimMasterMB(for: clip)
        let effectiveShareCapMB = Double((viewModel.settings.shareCap.capBytes ?? 20_000_000)) / 1_000_000.0
        let trimShareEstText: String = {
            if trimMasterEstMB <= effectiveShareCapMB * 0.96 {
                return String(format: "%.1f MB (Direct)", trimMasterEstMB)
            }
            return String(format: "<= %.1f MB", effectiveShareCapMB * 0.94)
        }()

        return VStack(alignment: .leading, spacing: 10) {
            // Clip Header
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.displayTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(clip.masterURL.lastPathComponent)
                        .font(Theme.mono(10.5, weight: .regular))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                StatusPill(
                    text: "\(clip.resolutionLabel) · \(Int(clip.fps.rounded())) FPS · \(clip.codecName)",
                    tone: .neutral,
                    fontSize: 10.5
                )
                StatusPill(
                    text: "Master: \(Theme.formatMB(clip.masterBytes))",
                    icon: "film",
                    tone: .neutral,
                    fontSize: 10.5
                )
                shareStatusBadge(for: clip, status: status)
            }

            // 16:9 Theatre Video Stage
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)

                if !isStaticPreview, viewModel.player.currentItem != nil {
                    AVPlayerStageView(player: viewModel.player)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Color.clear
                        .overlay(thumbnailImage(for: clip))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                    // Bottom transport HUD bar
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Button {
                                viewModel.togglePlayPause()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text(viewModel.isPlaying ? "Pause" : "Play")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundColor(Theme.amberInk)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Theme.amber)
                                )
                            }
                            .buttonStyle(.plain)

                            Text(verbatim: "\(Theme.formatPreciseTime(viewModel.playheadSeconds)) / \(Theme.formatPreciseTime(clip.durationSeconds))")
                                .font(Theme.mono(11, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 6)

                            Text(verbatim: String(format: "~%.1f MB · Share %@", trimMasterEstMB, trimShareEstText))
                                .font(Theme.mono(10, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.78))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.borderStrong, lineWidth: 1)
                        )
                        .padding(8)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: 266)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.borderStrong, lineWidth: 1)
                )
                .frame(maxWidth: .infinity)

                // Filmstrip Timeline Card
                VStack(alignment: .leading, spacing: 6) {
                    FilmstripTimelineView(
                        durationSeconds: clip.durationSeconds,
                        trimRange: $viewModel.trimRange,
                        playheadSeconds: $viewModel.playheadSeconds,
                        thumbnails: viewModel.filmstripByClipID[clip.id] ?? [],
                        onScrub: { targetSeconds in
                            viewModel.scrubPlayer(to: targetSeconds)
                        }
                    )
                }
                .padding(10)
                .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)

                // Action Bar
                HStack(spacing: 10) {
                    Button {
                        Task {
                            await viewModel.copyShareClip(clip)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.clipboard.fill")
                            Text(copyButtonTitle(for: status))
                        }
                    }
                    .buttonStyle(AmberCTAButtonStyle())
                    .disabled(status == .compressing || viewModel.isExportingTrim)

                    Button {
                        Task {
                            await viewModel.saveMasterTrim()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "scissors")
                            Text("Save Trim (Master)")
                        }
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle())
                    .disabled(viewModel.isExportingTrim)

                    Button {
                        Task {
                            await viewModel.copyCompressedTrim()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "paperplane.fill")
                            Text(copyTrimTitle)
                        }
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle())
                    .disabled(viewModel.isExportingTrim)

                    Spacer()

                    Button {
                        viewModel.revealMaster(clip)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            Text("Reveal Master")
                        }
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle())

                    Button {
                        Task {
                            await viewModel.deleteClip(clip, shareOnly: false)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle(isDestructive: true))
                    .help("Delete Master & Shared clip files")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)
        }
        .padding(12)
    }

    // MARK: - Empty State & Helpers

    private var emptyLibraryView: some View {
        VStack(spacing: 12) {
            if viewModel.effectiveCaptureState == .permissionDenied {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Theme.amber)
                Text("Enable Screen Recording to Start Buffering")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Click Grant Screen Recording in the bar above, turn Backbuffer ON in System Settings → Privacy & Security → Screen Recording, then click Check Again.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            } else if case .awaitingAllowedApps(let allowedCount) = viewModel.effectiveCaptureState {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Theme.amber)
                Text(allowedCount == 0
                     ? "Choose Apps to Allow Recording"
                     : "Waiting for an Allowed App")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(allowedCount == 0
                     ? "Backbuffer stays privacy-locked until you select at least one game or app you want buffered. Desktop browsers, messages, and unapproved windows stay unrecorded."
                     : "None of your \(allowedCount) allowed app\(allowedCount == 1 ? "" : "s") currently has an open window. Launch an allowed app or adjust your allowlist.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button {
                    viewModel.openSettings(tab: .privacy)
                    openWindow(id: "settings")
                } label: {
                    Text("Choose Allowed Apps...")
                }
                .buttonStyle(AmberCTAButtonStyle())
                .padding(.top, 4)
            } else {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Theme.amber)
                Text("No Saved Clips Yet")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text(verbatim: "Hit \(viewModel.settings.saveHotKey.displayString) while gaming to save your last \(viewModel.settings.bufferDuration.rawValue)s untouched into Masters/.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func thumbnailImage(for clip: ClipPairRecord) -> some View {
        if let nsImage = viewModel.thumbnailsByClipID[clip.id] {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Theme.surfaceElevated, Theme.surfaceSubtle],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    private func shareStatusBadge(
        for clip: ClipPairRecord,
        status: ShareStatus,
        compact: Bool = false
    ) -> StatusPill {
        switch status {
        case .fitsDirectly:
            let capLabel = viewModel.settings.shareCap.shortLabel
            return StatusPill(
                text: compact ? "Fits <\(capLabel)" : "Discord Ready · Fits <\(capLabel)",
                icon: compact ? nil : "checkmark.circle.fill",
                tone: .emerald,
                fontSize: compact ? 9.5 : 10.5
            )
        case .compressed(let bytes):
            return StatusPill(
                text: compact ? "S: \(Theme.formatMB(bytes))" : "Discord: \(Theme.formatMB(bytes))",
                icon: compact ? nil : "checkmark.circle.fill",
                tone: .emerald,
                fontSize: compact ? 9.5 : 10.5
            )
        case .compressing:
            return StatusPill(
                text: "Compressing...",
                icon: compact ? nil : "hourglass",
                tone: .amber,
                fontSize: compact ? 9.5 : 10.5
            )
        case .overNewCap(let bytes):
            let label: String
            if clip.shareURL != nil {
                label = compact ? "Over Cap" : "Over New Cap (\(Theme.formatMB(bytes)))"
            } else {
                label = compact ? "Needs Share" : "Needs Share (\(Theme.formatMB(bytes)))"
            }
            return StatusPill(
                text: label,
                icon: compact ? nil : "exclamationmark.triangle.fill",
                tone: .amber,
                fontSize: compact ? 9.5 : 10.5
            )
        case .disabled:
            return StatusPill(
                text: "Share Off",
                tone: .neutral,
                fontSize: compact ? 9.5 : 10.5
            )
        }
    }

    private func copyButtonTitle(for status: ShareStatus) -> String {
        switch status {
        case .compressing:
            return "Compressing..."
        case .disabled:
            return "Copy Master Clip"
        case .overNewCap:
            return "Compress & Copy Discord"
        case .fitsDirectly, .compressed:
            return "Copy Discord Clip"
        }
    }

    private var copyTrimTitle: String {
        if let capBytes = viewModel.settings.shareCap.capBytes {
            return "Copy Trim (<=\(capBytes / 1_000_000) MB)"
        }
        return "Copy Trim (20 MB Discord)"
    }

    private func toastFooterBar(_ toast: ToastBanner) -> some View {
        let color: Color = {
            switch toast.tone {
            case .success: return Theme.emerald
            case .info, .warning: return Theme.amber
            case .error: return Theme.crimson
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: toast.tone == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundColor(color)
            Text(toast.message)
                .font(Theme.mono(11.5, weight: .medium))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surfaceSubtle)
        .overlay(
            Rectangle()
                .fill(color.opacity(0.35))
                .frame(height: 1),
            alignment: .top
        )
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - macOS 13 Safe AVPlayerView Wrapper

private struct AVPlayerStageView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
