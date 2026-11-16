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
        case .awaitingAllowedApps(let count):
            return count == 0 ? "0 Allowed" : "Standby"
        case .idle, .error:
            return "~\(Theme.formatMB(viewModel.estimate.estimatedRAMBufferMB)) est."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            headerSection
            savePrimarySection
            shortcutAndMicStrip
            targetSection
            presetSummaryRow

            if let toast = viewModel.toast {
                toastRow(toast)
            }

            Divider()
                .background(Theme.border)

            footerActions
        }
        .padding(12)
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
                    Text(verbatim: statusHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                }

                Spacer()

                if viewModel.effectiveInstallIssue.requiresMoveToApplications || viewModel.effectiveBundleReplacedOnDisk {
                    StatusPill(text: "RELAUNCH", tone: .amber, fontSize: 10)
                } else if case .buffering = viewModel.effectiveCaptureState {
                    StatusPill(text: "REC", tone: .crimson, fontSize: 10)
                } else if case .paused = viewModel.effectiveCaptureState {
                    StatusPill(text: "PAUSED", tone: .amber, fontSize: 10)
                } else if case .permissionDenied = viewModel.effectiveCaptureState {
                    StatusPill(text: "NO ACCESS", tone: .crimson, fontSize: 10)
                } else if case .awaitingAllowedApps = viewModel.effectiveCaptureState {
                    StatusPill(text: "PRIVACY LOCK", tone: .amber, fontSize: 10)
                }

                Text(verbatim: ramText)
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

            if viewModel.effectiveInstallIssue.requiresMoveToApplications {
                let issue = viewModel.effectiveInstallIssue
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: issue.userTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: issue.userExplanation)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Install to /Applications & Relaunch") {
                            viewModel.installToApplicationsAndRelaunch()
                        }
                        .buttonStyle(AmberCTAButtonStyle(compact: true))
                    }
                }
                .padding(8)
                .graphiteCard(background: Theme.amberSoft, cornerRadius: 7, borderColor: Theme.amber.opacity(0.35))
            } else if viewModel.effectiveBundleReplacedOnDisk {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backbuffer was updated while running — relaunch to match its new code signature.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Relaunch Updated App") {
                            viewModel.relaunchApplicationNow()
                        }
                        .buttonStyle(AmberCTAButtonStyle(compact: true))
                    }
                }
                .padding(8)
                .graphiteCard(background: Theme.amberSoft, cornerRadius: 7, borderColor: Theme.amber.opacity(0.35))
            } else if case .permissionDenied = viewModel.effectiveCaptureState {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Screen Recording needed. Already ON after updating? Check & Relaunch or Fix Update.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Button("Grant") {
                            viewModel.openScreenCaptureSettings()
                        }
                        .buttonStyle(AmberCTAButtonStyle(compact: true))

                        Button("Check & Relaunch") {
                            Task {
                                await viewModel.checkOrRelaunchAfterPermissionGrant()
                            }
                        }
                        .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))

                        Button("Fix Update") {
                            viewModel.resetStuckScreenPermissionAndRelaunch()
                        }
                        .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                    }
                }
                .padding(8)
                .graphiteCard(background: Theme.crimsonSoft, cornerRadius: 7, borderColor: Theme.crimson.opacity(0.35))
            } else if case .awaitingAllowedApps(let allowedCount) = viewModel.effectiveCaptureState {
                HStack(spacing: 8) {
                    Text(allowedCount == 0
                         ? "Select at least one game or app to begin buffering."
                         : "Open an allowed app or add more below.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Choose Apps...") {
                        openSettingsTab(.privacy)
                    }
                    .buttonStyle(AmberCTAButtonStyle(compact: true))
                }
                .padding(8)
                .graphiteCard(background: Theme.amberSoft, cornerRadius: 7, borderColor: Theme.amber.opacity(0.35))
            } else if case .error(let detail) = viewModel.effectiveCaptureState {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.crimson)
                    .lineLimit(2)
            }
        }
        .padding(9)
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
                Text(verbatim: viewModel.settings.saveHotKey.displayString)
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
        .disabled(
            viewModel.captureCoordinator.isSaving
                || viewModel.effectiveCaptureState == .permissionDenied
                || viewModel.isPrivacyLocked
        )
    }

    private var shortcutAndMicStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Theme.amber)
                    Text(verbatim: shortcutSummaryText)
                        .font(Theme.mono(10.5, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    openSettingsTab(.shortcutsAndMic)
                } label: {
                    Text("Change Shortcut...")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Theme.amber)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            HStack(spacing: 8) {
                let micEnabled = viewModel.settings.recordMicrophone
                let micMuted = viewModel.settings.isMicrophoneMuted
                let micLive = micEnabled && !micMuted

                Image(systemName: micLive ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(
                        !micEnabled
                            ? Theme.textMuted
                            : (micMuted ? Theme.amber : Theme.emerald)
                    )
                    .frame(width: 14)

                Text(verbatim: !micEnabled ? "Mic Off" : (micMuted ? "Mic Muted" : "Mic Live"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(micEnabled ? Theme.textPrimary : Theme.textSecondary)

                compactMicBars(level: micLive ? viewModel.micInputLevel : 0)

                Spacer()

                Button {
                    if !micEnabled {
                        viewModel.toggleMicrophone()
                    } else {
                        viewModel.toggleMicrophoneMute()
                    }
                } label: {
                    Text(!micEnabled ? "Enable" : (micMuted ? "Unmute" : "Mute"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Theme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                if micEnabled {
                    Button {
                        openSettingsTab(.shortcutsAndMic)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Configure Microphone & Gain")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
        }
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 8)
    }

    private func compactMicBars(level: Double) -> some View {
        let normalized = min(1.0, max(0.0, level))
        let count = 6
        return HStack(spacing: 2.5) {
            ForEach(0..<count, id: \.self) { index in
                let threshold = Double(index + 1) / Double(count)
                let lit = normalized >= threshold * 0.85 && normalized > 0.03
                let color: Color = index >= 4 ? Theme.amber : Theme.emerald
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(lit ? color : Theme.surfaceElevated)
                    .frame(width: 4, height: CGFloat(5 + index))
            }
        }
        .frame(height: 11, alignment: .bottom)
    }

    private var shortcutSummaryText: String {
        if let pause = viewModel.settings.togglePauseHotKey {
            return "Save \(viewModel.settings.saveHotKey.displayString) · Pause \(pause.displayString)"
        }
        return "Save \(viewModel.settings.saveHotKey.displayString)"
    }

    private func openSettingsTab(_ tab: SettingsTab) {
        viewModel.openSettings(tab: tab)
        if let onOpenSettings {
            onOpenSettings()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CAPTURE TARGET")
                    .font(Theme.mono(10, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button {
                    openSettingsTab(.privacy)
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Allowed Apps")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundColor(Theme.amber)
                }
                .buttonStyle(.plain)

                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)

                Button {
                    Task {
                        await viewModel.refreshTargetsAndAutoStart()
                    }
                } label: {
                    HStack(spacing: 3.5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 10.5, weight: .medium))
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
                VStack(spacing: 4) {
                    ForEach(Array(viewModel.targetOptions.prefix(3))) { option in
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
                                    Text(verbatim: option.title)
                                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                        .foregroundColor(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(verbatim: option.subtitle)
                                        .font(Theme.mono(10, weight: .regular))
                                        .foregroundColor(Theme.textSecondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.amber)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
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
        HStack(spacing: 5) {
            StatusPill(
                text: "\(viewModel.settings.resolutionCap.displayName) · \(viewModel.settings.fps.rawValue) FPS",
                tone: .neutral,
                fontSize: 10
            )
            StatusPill(
                text: viewModel.settings.codec.displayName,
                tone: .neutral,
                fontSize: 10
            )
            StatusPill(
                text: viewModel.settings.privacyMode == .strictAllowlist
                    ? "\(viewModel.allowedAppCount) Apps"
                    : "Allow All",
                tone: viewModel.settings.privacyMode == .strictAllowlist ? .neutral : .amber,
                fontSize: 10
            )
            Spacer()
            if let cap = viewModel.settings.shareCap.capBytes {
                StatusPill(
                    text: "<= \(cap / 1_000_000)M",
                    tone: .emerald,
                    fontSize: 10
                )
            } else {
                StatusPill(text: "Share Off", tone: .neutral, fontSize: 10)
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
                    if let existing = NSApp.windows.first(where: {
                        $0.isVisible && $0.canBecomeMain && !$0.title.localizedCaseInsensitiveContains("Settings")
                    }) {
                        existing.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "library")
                    }
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
        case .paused, .awaitingAllowedApps: return Theme.amber
        case .permissionDenied, .error: return Theme.crimson
        case .idle: return Theme.textMuted
        }
    }

    private var bufferBarColor: Color {
        switch viewModel.effectiveCaptureState {
        case .buffering: return Theme.amber
        case .paused, .awaitingAllowedApps: return Theme.amber.opacity(0.65)
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
        case .awaitingAllowedApps(let count):
            return count == 0 ? "Privacy Lock Active" : "Waiting for Allowed App"
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
