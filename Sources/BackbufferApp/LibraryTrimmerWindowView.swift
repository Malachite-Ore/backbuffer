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
    @State private var displayMode: LibraryDisplayMode
    @State private var hoveredClipID: String?

    init(viewModel: AppViewModel, initialMode: LibraryDisplayMode = .hub) {
        self.viewModel = viewModel
        self._displayMode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            topToolbar

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            Group {
                switch displayMode {
                case .hub:
                    hubGridBody
                case .trimmer:
                    trimmerTheatreBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let toast = viewModel.toast {
                toastFooterBar(toast)
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
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
                TextField("Filter clips, codec, resolution...", text: $viewModel.librarySearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 190)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.surfaceSubtle)
    }

    // MARK: - Mode 1: 16:9 Clip Hub Grid

    private var hubGridBody: some View {
        Group {
            if viewModel.filteredClips.isEmpty {
                emptyLibraryView
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

    private func hubClipCard(_ clip: ClipPairRecord) -> some View {
        let isHovered = hoveredClipID == clip.id
        let isSelected = viewModel.selectedClip?.id == clip.id
        let status = viewModel.effectiveShareStatus(for: clip)

        return VStack(alignment: .leading, spacing: 0) {
            // 16:9 Thumbnail header
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    thumbnailImage(for: clip)
                )
                .clipped()
                .overlay(
                    // Subtle bottom vignette for legibility
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.68)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    // Overlay badges
                    VStack {
                        HStack {
                            StatusPill(
                                text: "\(clip.height)p\(Int(clip.fps.rounded())) · \(clip.codecName)",
                                tone: .neutral,
                                fontSize: 10
                            )
                            Spacer()
                            Text(Theme.formatDuration(clip.durationSeconds))
                                .font(Theme.mono(11, weight: .bold))
                                .foregroundColor(Theme.textPrimary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.black.opacity(0.76))
                                )
                        }
                        Spacer()

                        if isHovered {
                            HStack(spacing: 8) {
                                Button {
                                    viewModel.selectClip(clip)
                                    displayMode = .trimmer
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "scissors")
                                        Text("Open Trimmer")
                                    }
                                }
                                .buttonStyle(AmberCTAButtonStyle(compact: true))

                                Button {
                                    Task {
                                        await viewModel.copyShareClip(clip)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Quick Copy")
                                    }
                                }
                                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                            }
                            .padding(.bottom, 6)
                        }
                    }
                    .padding(10)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.selectClip(clip)
                    displayMode = .trimmer
                }

            // Metadata + Dual Storage Badges + Action Row
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(clip.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(formattedTimestamp(clip.createdAt))
                        .font(Theme.mono(10.5, weight: .regular))
                        .foregroundColor(Theme.textMuted)
                }

                HStack(spacing: 6) {
                    StatusPill(
                        text: "Master: \(Theme.formatMB(clip.masterBytes))",
                        icon: "film",
                        tone: .neutral,
                        fontSize: 10.5
                    )
                    shareStatusBadge(for: clip, status: status)
                    Spacer()
                }

                HStack(spacing: 7) {
                    Button {
                        Task {
                            await viewModel.copyShareClip(clip)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 11, weight: .semibold))
                            Text(copyButtonTitle(for: status))
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
                                .font(.system(size: 11, weight: .semibold))
                            Text("Trim")
                        }
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

                    Button {
                        viewModel.revealMaster(clip)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                    .help("Reveal original Master in Finder")
                }
            }
            .padding(12)
        }
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

            ScrollView {
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
                                        Text("\(Theme.formatDuration(clip.durationSeconds)) · \(clip.height)p\(Int(clip.fps.rounded()))")
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
        }
    }

    private func trimmerInspectorStage(_ clip: ClipPairRecord) -> some View {
        let status = viewModel.effectiveShareStatus(for: clip)
        let trimMasterEstMB = viewModel.estimatedTrimMasterMB(for: clip)
        let effectiveShareCapMB = Double((viewModel.settings.shareCap.capBytes ?? 20_000_000)) / 1_000_000.0
        let trimShareEstText: String = {
            if trimMasterEstMB <= effectiveShareCapMB * 0.96 {
                return String(format: "%.1f MB (Direct)", trimMasterEstMB)
            }
            return String(format: "<= %.1f MB", effectiveShareCapMB * 0.94)
        }()

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Clip Header
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(clip.displayTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.textPrimary)
                        Text(clip.masterURL.lastPathComponent)
                            .font(Theme.mono(11, weight: .regular))
                            .foregroundColor(Theme.textSecondary)
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

                    if viewModel.player.currentItem != nil {
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
                        HStack(spacing: 10) {
                            Button {
                                viewModel.togglePlayPause()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 11.5, weight: .bold))
                                    Text(viewModel.isPlaying ? "Pause" : "Play")
                                        .font(.system(size: 11.5, weight: .semibold))
                                }
                                .foregroundColor(Theme.amberInk)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Theme.amber)
                                )
                            }
                            .buttonStyle(.plain)

                            Text("\(Theme.formatPreciseTime(viewModel.playheadSeconds)) / \(Theme.formatPreciseTime(clip.durationSeconds))")
                                .font(Theme.mono(11.5, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)

                            Spacer()

                            Text(String(format: "Trim Est -> Master: ~%.1f MB · Share: %@", trimMasterEstMB, trimShareEstText))
                                .font(Theme.mono(11, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.78))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.borderStrong, lineWidth: 1)
                        )
                        .padding(10)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: 310)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.borderStrong, lineWidth: 1)
                )

                // Filmstrip Timeline Card
                VStack(alignment: .leading, spacing: 8) {
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
                .padding(12)
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
                .padding(12)
                .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)
            }
            .padding(16)
        }
    }

    // MARK: - Empty State & Helpers

    private var emptyLibraryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Theme.amber)
            Text("No Saved Clips Yet")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Text("Hit \(viewModel.settings.saveHotKey.displayString) while gaming to save your last \(viewModel.settings.bufferDuration.rawValue)s untouched into Masters/.")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
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
