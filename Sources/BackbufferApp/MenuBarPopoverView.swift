import AppKit
import BackbufferCore
import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var onOpenLibrary: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil

    private var currentTarget: CaptureTargetOption? {
        viewModel.selectedTargetOption
    }

    private var bufferSecondsProgress: Double {
        guard case .buffering(let buffered, _) = viewModel.effectiveCaptureState else {
            return 0
        }
        let target = max(1.0, viewModel.settings.bufferDuration.seconds)
        return min(1.0, max(0.0, buffered / target))
    }

    private var ramText: String {
        switch viewModel.effectiveCaptureState {
        case .buffering(_, let bytes):
            if bytes > 0 {
                return "\(Theme.formatMB(bytes)) RAM"
            }
            return "~\(Theme.formatMB(viewModel.estimate.estimatedRAMBufferMB)) RAM"
        case .paused:
            return "Paused"
        case .permissionDenied:
            return "TCC Needed"
        case .idle, .error:
            return "~\(Theme.formatMB(viewModel.estimate.estimatedRAMBufferMB)) est."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            savePrimarySection
            targetSection
            presetSummaryRow

            if let toast = viewModel.toast {
                toastRow(toast)
            }

            Divider()
                .background(Theme.border)

            footerActions
        }
        .padding(14)
        .frame(width: 344)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 8, height: 8)
                    Text(statusHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }

                Spacer()

                if case .buffering = viewModel.effectiveCaptureState {
                    StatusPill(text: "REC", tone: .crimson, fontSize: 10)
                } else if case .paused = viewModel.effectiveCaptureState {
                    StatusPill(text: "PAUSED", tone: .amber, fontSize: 10)
                } else if case .permissionDenied = viewModel.effectiveCaptureState {
                    StatusPill(text: "NO ACCESS", tone: .crimson, fontSize: 10)
                }

                Text(ramText)
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            // Buffer fill bar + Pause/Resume toggle
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.surfaceElevated)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(bufferBarColor)
                            .frame(width: max(4, geo.size.width * bufferSecondsProgress))
                    }
                }
                .frame(height: 5)

                Button {
                    Task {
                        await viewModel.toggleRecordingPause()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.captureCoordinator.isPaused || viewModel.effectiveCaptureState == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(toggleButtonTitle)
                            .font(Theme.tabular(11, weight: .semibold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if case .permissionDenied = viewModel.effectiveCaptureState {
                HStack(spacing: 8) {
                    Text("Screen Recording permission is required to capture gameplay.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Grant") {
                        viewModel.captureCoordinator.requestScreenCapturePermission()
                    }
                    .buttonStyle(AmberCTAButtonStyle(compact: true))
                }
                .padding(8)
                .graphiteCard(background: Theme.crimsonSoft, cornerRadius: 7, borderColor: Theme.crimson.opacity(0.35))
            } else if case .error(let detail) = viewModel.effectiveCaptureState {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.crimson)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 9)
    }

    private var savePrimarySection: some View {
        Button {
            Task {
                await viewModel.saveClipNow()
            }
        } label: {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: viewModel.captureCoordinator.isSaving ? "hourglass" : "square.and.arrow.down.fill")
                        .font(.system(size: 12.5, weight: .bold))
                    Text(viewModel.captureCoordinator.isSaving ? "Saving Replay..." : "Save Clip Now")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                Text(viewModel.settings.saveHotKey.displayString)
                    .font(Theme.mono(11.5, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Theme.amberInk.opacity(0.16))
                    )
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(AmberCTAButtonStyle())
        .disabled(viewModel.captureCoordinator.isSaving || viewModel.effectiveCaptureState == .permissionDenied)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("CAPTURE TARGET")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    Task {
                        await viewModel.refreshTargetsAndAutoStart()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            if viewModel.targetOptions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted)
                    Text("No active displays or windows detected yet.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .graphiteCard(background: Theme.surfaceCard, cornerRadius: 8)
            } else {
                VStack(spacing: 5) {
                    ForEach(Array(viewModel.targetOptions.prefix(4))) { option in
                        let isSelected = option.id == currentTarget?.id
                        Button {
                            Task {
                                await viewModel.selectCaptureTarget(option)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.systemImageName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(isSelected ? Theme.amber : Theme.textSecondary)
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.title)
                                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(option.subtitle)
                                        .font(Theme.mono(10.5, weight: .regular))
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12.5))
                                        .foregroundColor(Theme.amber)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isSelected ? Theme.surfaceElevated : Theme.surfaceCard)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(
                                        isSelected ? Theme.amber.opacity(0.65) : Theme.border,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var presetSummaryRow: some View {
        HStack(spacing: 6) {
            StatusPill(
                text: "\(viewModel.settings.resolutionCap.displayName) · \(viewModel.settings.fps.rawValue) FPS",
                tone: .neutral,
                fontSize: 10.5
            )
            StatusPill(
                text: viewModel.settings.codec.displayName,
                tone: .neutral,
                fontSize: 10.5
            )
            Spacer()
            if let cap = viewModel.settings.shareCap.capBytes {
                StatusPill(
                    text: "Discord <= \(cap / 1_000_000)M",
                    tone: .emerald,
                    fontSize: 10.5
                )
            } else {
                StatusPill(text: "Share Off", tone: .neutral, fontSize: 10.5)
            }
        }
    }

    private func toastRow(_ toast: ToastBanner) -> some View {
        let toneColor: Color = {
            switch toast.tone {
            case .success: return Theme.emerald
            case .info: return Theme.amber
            case .warning: return Theme.amber
            case .error: return Theme.crimson
            }
        }()
        return HStack(spacing: 6) {
            Image(systemName: toast.tone == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(toneColor)
            Text(toast.message)
                .font(Theme.mono(11, weight: .medium))
                .foregroundColor(toneColor)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .graphiteCard(background: Theme.surfaceSubtle, cornerRadius: 7, borderColor: toneColor.opacity(0.3))
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button {
                if let onOpenLibrary {
                    onOpenLibrary()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "library")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 11.5))
                    Text("Open Library")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

            Button {
                if let onOpenSettings {
                    onOpenSettings()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11.5))
                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    private var statusDotColor: Color {
        switch viewModel.effectiveCaptureState {
        case .buffering: return Theme.crimson
        case .paused: return Theme.amber
        case .permissionDenied, .error: return Theme.crimson
        case .idle: return Theme.textMuted
        }
    }

    private var bufferBarColor: Color {
        switch viewModel.effectiveCaptureState {
        case .buffering: return Theme.amber
        case .paused: return Theme.textMuted
        case .permissionDenied, .error: return Theme.crimson
        case .idle: return Theme.surfaceHover
        }
    }

    private var statusHeadline: String {
        switch viewModel.effectiveCaptureState {
        case .buffering(let secondsBuffered, _):
            let rounded = Int(secondsBuffered.rounded())
            if rounded > 0 {
                return "Buffering \(rounded)s / \(viewModel.settings.bufferDuration.rawValue)s"
            }
            return "Buffering Last \(viewModel.settings.bufferDuration.rawValue)s"
        case .paused:
            return "Buffering Paused"
        case .permissionDenied:
            return "Permission Needed"
        case .error:
            return "Capture Error"
        case .idle:
            return "Ready to Buffer"
        }
    }

    private var toggleButtonTitle: String {
        switch viewModel.effectiveCaptureState {
        case .paused: return "Resume"
        case .buffering: return "Pause"
        default: return "Start"
        }
    }
}
