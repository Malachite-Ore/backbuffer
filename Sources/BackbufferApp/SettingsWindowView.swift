import AppKit
import BackbufferCore
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var viewModel: AppViewModel

    private var bitrateSummary: String {
        let vMbps = Double(viewModel.estimate.videoBitrateBps) / 1_000_000.0
        let aKbps = viewModel.estimate.audioBitrateBps / 1_000
        return String(format: "%.1f Mbps video + %dk AAC", vMbps, aKbps)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerBar

                    HStack(alignment: .top, spacing: 12) {
                        fpsCard
                        resolutionCard
                    }

                    qualityCard

                    HStack(alignment: .top, spacing: 12) {
                        codecCard
                        bufferDurationCard
                    }

                    shareCapCard

                    HStack(alignment: .top, spacing: 12) {
                        hotkeyCard
                        outputFolderCard
                    }
                }
                .padding(18)
            }

            stickyEstimatorFooter
        }
        .frame(minWidth: 700, minHeight: 580)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Capture & Share Settings")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    StatusPill(text: "macOS 13+ Hardware", tone: .amber, fontSize: 10.5)
                }
                Text("Configure continuous RAM replay buffering, untouched Masters, and Discord-sized Shared copies.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            Button("Reset Defaults") {
                viewModel.resetSettingsToDefault()
            }
            .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
        }
    }

    // MARK: - Cards

    private var fpsCard: some View {
        settingCard(title: "Frame Rate (FPS)", subtitle: "CFR Keepalive") {
            HStack(spacing: 6) {
                ForEach(CaptureFPS.allCases) { fps in
                    Button(fps.displayName) {
                        viewModel.updateFPS(fps)
                    }
                    .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.fps == fps))
                }
            }
        }
    }

    private var resolutionCard: some View {
        settingCard(title: "Resolution Cap", subtitle: "Retina · <= 4096 px") {
            HStack(spacing: 6) {
                ForEach(ResolutionCap.allCases) { cap in
                    Button(cap.displayName) {
                        viewModel.updateResolutionCap(cap)
                    }
                    .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.resolutionCap == cap))
                }
            }
        }
    }

    private var qualityCard: some View {
        settingCard(
            title: "Master Capture Quality",
            subtitle: bitrateSummary
        ) {
            HStack(spacing: 8) {
                ForEach(QualityPreset.allCases) { preset in
                    Button {
                        viewModel.updateQuality(preset)
                    } label: {
                        VStack(spacing: 2) {
                            Text(preset.displayName)
                                .font(Theme.tabular(12, weight: viewModel.settings.quality == preset ? .bold : .medium))
                            Text(qualityTagline(preset))
                                .font(Theme.mono(10, weight: .regular))
                                .opacity(0.78)
                        }
                    }
                    .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.quality == preset))
                }
            }
        }
    }

    private var codecCard: some View {
        settingCard(title: "Hardware Video Codec", subtitle: "VideoToolbox") {
            HStack(spacing: 6) {
                ForEach(VideoCodecChoice.allCases) { codec in
                    Button(codec.pickerLabel) {
                        viewModel.updateCodec(codec)
                    }
                    .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.codec == codec))
                }
            }
        }
    }

    private var bufferDurationCard: some View {
        settingCard(title: "Replay Buffer Window", subtitle: "RAM Only · 0 SSD Writes") {
            HStack(spacing: 6) {
                ForEach(BufferDurationOption.allCases) { option in
                    Button(option.displayName) {
                        viewModel.updateBufferDuration(option)
                    }
                    .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.bufferDuration == option))
                }
            }
        }
    }

    private var shareCapCard: some View {
        settingCard(
            title: "Discord Auto-Compress Cap",
            subtitle: "Shared/ Only · Lazy Re-Evaluation"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(ShareCapOption.allCases) { option in
                        Button(option.displayName) {
                            viewModel.updateShareCap(option)
                        }
                        .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.shareCap == option))
                    }
                }
                Text("Originals in Masters/ are never overwritten or degraded. Lowering the cap lazily re-compresses older clips only when you click Copy Discord Clip.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    private var hotkeyCard: some View {
        settingCard(title: "Global Save Hotkey", subtitle: "Carbon · Zero Keylogger TCC") {
            HStack(spacing: 10) {
                HotKeyRecorderControl(
                    shortcut: viewModel.settings.saveHotKey,
                    onChange: { newShortcut in
                        viewModel.updateSaveHotKey(newShortcut)
                    }
                )
                Spacer()
                Text("Works over fullscreen games")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }

    private var outputFolderCard: some View {
        settingCard(title: "Clip Storage Folder", subtitle: "Masters/ + Shared/") {
            HStack(spacing: 8) {
                Text(abbreviatedPath(viewModel.settings.outputRootPath))
                    .font(Theme.mono(11.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surfaceSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )

                Button("Choose...") {
                    viewModel.chooseOutputFolder()
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
            }
        }
    }

    // MARK: - Sticky Live Estimator Footer

    private var stickyEstimatorFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.borderStrong)
                .frame(height: 1)

            HStack(spacing: 12) {
                estimatorMetric(
                    label: "Estimated Master (\(viewModel.settings.bufferDuration.rawValue)s)",
                    value: "~\(Theme.formatMB(viewModel.estimate.estimatedMasterMB))",
                    detail: "Untouched in Masters/",
                    valueColor: Theme.textPrimary
                )

                estimatorMetric(
                    label: "RAM Ring Buffer",
                    value: "~\(Theme.formatMB(viewModel.estimate.estimatedRAMBufferMB))",
                    detail: "Includes +2s GOP headroom",
                    valueColor: Theme.textPrimary
                )

                estimatorMetric(
                    label: "Share Auto-Compress",
                    value: shareEstimateHeadline,
                    detail: shareEstimateSubtitle,
                    valueColor: shareEstimateColor
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.surfaceSubtle)
        }
    }

    private func estimatorMetric(
        label: String,
        value: String,
        detail: String,
        valueColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text(value)
                .font(Theme.mono(15, weight: .bold))
                .foregroundColor(valueColor)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 8)
    }

    // MARK: - Layout Helpers

    private func settingCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(subtitle)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)
    }

    private func qualityTagline(_ preset: QualityPreset) -> String {
        switch preset {
        case .compact: return "Small files"
        case .balanced: return "Discord fit"
        case .high: return "Crisp + Share"
        case .postMaster: return "NLE edit grade"
        }
    }

    private var shareEstimateHeadline: String {
        guard let capBytes = viewModel.settings.shareCap.capBytes else {
            return "Disabled"
        }
        let capMB = Double(capBytes) / 1_000_000.0
        if !viewModel.estimate.willAutoCompress {
            return String(format: "Fits <= %.0f MB", capMB)
        }
        let targetLabel = capMB * 0.94
        return String(format: "<= %.1f MB", targetLabel)
    }

    private var shareEstimateSubtitle: String {
        guard viewModel.settings.shareCap.capBytes != nil else {
            return "Master only (trim still shares at 20 MB)"
        }
        return viewModel.estimate.willAutoCompress
            ? "Auto hardware copy in Shared/"
            : "Master already under cap (no duplicate)"
    }

    private var shareEstimateColor: Color {
        guard viewModel.settings.shareCap.capBytes != nil else {
            return Theme.textSecondary
        }
        return viewModel.estimate.willAutoCompress ? Theme.amber : Theme.emerald
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - macOS 13 Safe Carbon Hotkey Recorder

private struct HotKeyRecorderControl: View {
    let shortcut: HotKeyShortcut
    let onChange: (HotKeyShortcut) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isRecording ? Theme.crimson : Theme.amber)
                Text(isRecording ? "Press shortcut (⌘/⌥/⌃ + key)..." : shortcut.displayString)
                    .font(Theme.mono(12.5, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isRecording ? Theme.amberSoft : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isRecording ? Theme.amber : Theme.borderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels recording
                stopRecording()
                return nil
            }
            if let captured = HotKeyShortcut(event: event) {
                onChange(captured)
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }
}
