import AppKit
import BackbufferCore
import SwiftUI

struct SettingsWindowView: View {
    @ObservedObject var viewModel: AppViewModel
    var isStaticPreview: Bool = false

    private var bitrateSummary: String {
        let vMbps = Double(viewModel.estimate.videoBitrateBps) / 1_000_000.0
        let aKbps = viewModel.estimate.audioBitrateBps / 1_000
        return String(format: "%.1f Mbps video + %dk AAC", vMbps, aKbps)
    }

    var body: some View {
        VStack(spacing: 0) {
            consoleHeader

            Rectangle()
                .fill(Theme.borderStrong)
                .frame(height: 1)

            Group {
                switch viewModel.selectedSettingsTab {
                case .privacy:
                    privacyTabBody
                case .shortcutsAndMic:
                    shortcutsAndMicTabBody
                case .videoAndStorage:
                    videoAndStorageTabBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let toast = viewModel.toast {
                settingsToastBar(toast)
            }

            stickyEstimatorFooter
        }
        .frame(minWidth: 740, minHeight: 560)
        .background(Theme.background)
        .foregroundColor(Theme.textPrimary)
        .onAppear {
            viewModel.refreshDiscoveredApps()
            viewModel.refreshMicrophoneDevices()
        }
    }

    // MARK: - Top Studio Console Header

    private var consoleHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Backbuffer Settings")
                        .font(.system(size: 16.5, weight: .bold))
                        .foregroundColor(Theme.textPrimary)
                    StatusPill(text: "macOS 13+ Hardware", tone: .amber, fontSize: 10)
                }

                Spacer()

                Button("Reset Defaults") {
                    viewModel.resetSettingsToDefault()
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
            }

            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = viewModel.selectedSettingsTab == tab
                    Button {
                        viewModel.selectedSettingsTab = tab
                        if tab == .privacy {
                            viewModel.refreshDiscoveredApps()
                        } else if tab == .shortcutsAndMic {
                            viewModel.refreshMicrophoneDevices()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.systemImageName)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            if tab == .privacy && viewModel.settings.privacyMode == .strictAllowlist {
                                Text(verbatim: "\(viewModel.allowedAppCount)")
                                    .font(Theme.mono(10, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Theme.amberInk.opacity(0.18) : Theme.surfaceElevated)
                                    )
                            }
                        }
                        .foregroundColor(isSelected ? Theme.amberInk : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Theme.amber : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.surfaceSubtle)
    }

    // MARK: - Tab 1: Allowed Apps Privacy

    @ViewBuilder
    private var privacyTabBody: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            privacyModeCard
            appFilterControlsRow
            appDiscoveryListContainer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if isStaticPreview {
            VStack(alignment: .leading, spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                content
            }
        }
    }

    private var privacyModeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Privacy Mode")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                privacyStatusBadge
            }

            HStack(spacing: 8) {
                ForEach(AppPrivacyMode.allCases) { mode in
                    let isSelected = viewModel.settings.privacyMode == mode
                    Button {
                        viewModel.setPrivacyMode(mode)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode == .strictAllowlist ? "lock.shield.fill" : "eye.slash.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(mode.title)
                                .font(Theme.tabular(12, weight: isSelected ? .semibold : .medium))
                        }
                    }
                    .buttonStyle(PillChoiceButtonStyle(isSelected: isSelected))
                }
            }

            Text(viewModel.settings.privacyMode.summary)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)
    }

    private var privacyStatusBadge: StatusPill {
        switch viewModel.settings.privacyMode {
        case .strictAllowlist:
            if viewModel.settings.allowedAppBundleIDs.isEmpty {
                return StatusPill(
                    text: "Privacy Lock · Select Apps",
                    icon: "lock.fill",
                    tone: .amber,
                    fontSize: 10.5
                )
            }
            return StatusPill(
                text: "\(viewModel.allowedAppCount) Allowed · \(viewModel.openAllowedAppCount) Open",
                icon: "checkmark.shield.fill",
                tone: viewModel.openAllowedAppCount > 0 ? .emerald : .neutral,
                fontSize: 10.5
            )
        case .allowAllExceptBlocked:
            let hidden = viewModel.settings.blockedAppBundleIDs.count
            return StatusPill(
                text: hidden == 0 ? "All Apps Visible" : "\(hidden) Hidden",
                icon: hidden == 0 ? "eye.fill" : "eye.slash.fill",
                tone: hidden == 0 ? .neutral : .amber,
                fontSize: 10.5
            )
        }
    }

    private var appFilterControlsRow: some View {
        HStack(spacing: 8) {
            // Live Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textMuted)
                if isStaticPreview {
                    Text(
                        viewModel.appSearchQuery.isEmpty
                            ? "Search opened or saved apps..."
                            : viewModel.appSearchQuery
                    )
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.appSearchQuery.isEmpty ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("Search opened or saved apps...", text: $viewModel.appSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textPrimary)
                }
                if !viewModel.appSearchQuery.isEmpty {
                    Button {
                        viewModel.appSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )

            // Filter Segmented Pills
            HStack(spacing: 2) {
                ForEach(AppListFilter.allCases) { filter in
                    let isSelected = viewModel.appListFilter == filter
                    Button {
                        viewModel.appListFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? Theme.amberInk : Theme.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isSelected ? Theme.amber : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )

            // Show Helpers Toggle
            Button {
                viewModel.setIncludeHelperApps(!viewModel.includeHelperApps)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.includeHelperApps ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(viewModel.includeHelperApps ? Theme.amber : Theme.textMuted)
                    Text("Helpers")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(viewModel.includeHelperApps ? Theme.textPrimary : Theme.textSecondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.surfaceCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            viewModel.includeHelperApps ? Theme.amber.opacity(0.45) : Theme.border,
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var appDiscoveryListContainer: some View {
        VStack(spacing: 0) {
            // List Header + Bulk Actions
            HStack(spacing: 8) {
                Text(verbatim: "APPLICATIONS (\(viewModel.filteredApps.count))")
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundColor(Theme.textMuted)

                Spacer()

                Button("Allow Running") {
                    viewModel.allowAllRunningApps()
                }
                .buttonStyle(GraphiteActionLinkStyle(tone: .amber))

                Button("Clear All") {
                    viewModel.clearAllowedApps()
                }
                .buttonStyle(GraphiteActionLinkStyle(tone: .neutral))

                Button {
                    viewModel.refreshDiscoveredApps()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Refresh")
                    }
                }
                .buttonStyle(GraphiteActionLinkStyle(tone: .neutral))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surfaceSubtle)

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)

            if viewModel.filteredApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 24, weight: .light))
                        .foregroundColor(Theme.textMuted)
                    Text("No Applications Match")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Launch your game or clear search filters to allow an app.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.textSecondary)
                    if !viewModel.appSearchQuery.isEmpty || viewModel.appListFilter != .all {
                        Button("Reset Filters") {
                            viewModel.appSearchQuery = ""
                            viewModel.appListFilter = .all
                        }
                        .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 38)
            } else {
                let displayedApps = isStaticPreview ? Array(viewModel.filteredApps.prefix(5)) : viewModel.filteredApps
                VStack(spacing: 0) {
                    ForEach(Array(displayedApps.enumerated()), id: \.element.id) { idx, app in
                        let isAllowed = viewModel.settings.isApplicationAllowed(bundleIdentifier: app.bundleIdentifier)
                        appPrivacyRow(app: app, isAllowed: isAllowed)
                        if idx < displayedApps.count - 1 {
                            Rectangle()
                                .fill(Theme.border)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(Theme.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func appPrivacyRow(app: RunningAppCandidate, isAllowed: Bool) -> some View {
        HStack(spacing: 10) {
            appIconBadge(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(verbatim: app.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: app.bundleIdentifier)
                    .font(Theme.mono(10.5, weight: .regular))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if app.windowCount > 0 {
                Text(verbatim: app.windowCount == 1 ? "1 window" : "\(app.windowCount) windows")
                    .font(Theme.mono(10.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }

            StatusPill(
                text: app.isRunning ? "Open" : "Closed",
                tone: app.isRunning ? .emerald : .neutral,
                fontSize: 10
            )

            BackbufferSwitchToggle(isOn: isAllowed) {
                viewModel.setApplicationAllowed(
                    app.bundleIdentifier,
                    displayName: app.displayName,
                    allowed: !isAllowed
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func appIconBadge(bundleIdentifier: String, displayName: String) -> some View {
        if let icon = isStaticPreview ? nil : AppPrivacyCatalog.appIcon(for: bundleIdentifier) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            let initial = String(displayName.prefix(1)).uppercased()
            let tint = monogramTint(for: bundleIdentifier)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.20))
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1)
                Text(verbatim: initial.isEmpty ? "A" : initial)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(tint)
            }
            .frame(width: 26, height: 26)
        }
    }

    private func monogramTint(for bundleID: String) -> Color {
        let lower = bundleID.lowercased()
        if lower.contains("valorant") || lower.contains("riot") { return Theme.crimson }
        if lower.contains("minecraft") || lower.contains("mojang") { return Theme.emerald }
        if lower.contains("steam") || lower.contains("rocket") { return Color(red: 0.35, green: 0.65, blue: 0.98) }
        if lower.contains("discord") { return Color(red: 0.45, green: 0.50, blue: 0.98) }
        return Theme.amber
    }

    // MARK: - Tab 2: Shortcuts & Microphone

    @ViewBuilder
    private var shortcutsAndMicTabBody: some View {
        let content = VStack(alignment: .leading, spacing: 11) {
            hotkeysConsoleCard
            microphoneConsoleCard
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if isStaticPreview {
            VStack(alignment: .leading, spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                content
            }
        }
    }

    private var hotkeysConsoleCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Global Replay Hotkeys")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text("Carbon · Zero Accessibility TCC")
                    .font(Theme.mono(10.5, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }

            // Save Clip Row
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Save Replay Clip")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                        if !isStaticPreview && HotKeyManager.isSystemSymbolicConflict(viewModel.settings.saveHotKey) {
                            StatusPill(
                                text: "System Conflict",
                                icon: "exclamationmark.triangle.fill",
                                tone: .amber,
                                fontSize: 9.5
                            )
                        }
                    }
                    Text(verbatim: "Writes last \(viewModel.settings.bufferDuration.rawValue)s untouched into Masters/")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()

                HStack(spacing: 5) {
                    presetKeyButton(label: "F8", preset: .f8Preset)
                    presetKeyButton(label: "F9", preset: .f9Preset)
                    presetKeyButton(label: "⌃⇧S", preset: .defaultSaveClip)
                }

                HotKeyRecorderControl(
                    title: "Save Replay",
                    shortcut: viewModel.settings.saveHotKey,
                    allowClear: false,
                    compact: true,
                    onRecordingChanged: nil
                ) { newShortcut in
                    viewModel.updateSaveHotKey(newShortcut)
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Pause / Resume Row
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pause / Resume Buffering")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                    Text("Optional hotkey to pause live RAM recording")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()

                HotKeyRecorderControl(
                    title: "Pause / Resume",
                    shortcut: viewModel.settings.togglePauseHotKey,
                    allowClear: true,
                    compact: true,
                    onRecordingChanged: nil
                ) { newShortcut in
                    viewModel.updateTogglePauseHotKey(newShortcut)
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Sound Cues + Standalone F-key Hint
            HStack(spacing: 10) {
                BackbufferSwitchToggle(isOn: viewModel.settings.playSoundOnSave) {
                    viewModel.updatePlaySoundOnSave(!viewModel.settings.playSoundOnSave)
                }

                Text("Sound Cues on Save")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)

                Spacer()

                Text("Standalone F-keys (e.g. F8, F9) work directly over fullscreen games.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)
    }

    private func presetKeyButton(label: String, preset: HotKeyShortcut) -> some View {
        let isActive = viewModel.settings.saveHotKey == preset
        return Button {
            viewModel.updateSaveHotKey(preset)
        } label: {
            Text(verbatim: label)
                .font(Theme.mono(10.5, weight: isActive ? .bold : .semibold))
                .foregroundColor(isActive ? Theme.amberInk : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Theme.amber : Theme.surfaceElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isActive ? Theme.amber : Theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var microphoneConsoleCard: some View {
        let perm = viewModel.micPermissionState
        let activeMicName = selectedMicrophoneLabel

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                BackbufferSwitchToggle(isOn: viewModel.settings.recordMicrophone) {
                    viewModel.toggleMicrophone()
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Record Microphone Commentary")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("48 kHz synchronized host-clock capture")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()

                micPermissionBadge(perm)

                if perm != .authorized {
                    Button(perm == .notDetermined ? "Grant Mic Access" : "Open System Settings") {
                        viewModel.requestMicrophonePermission()
                    }
                    .buttonStyle(AmberCTAButtonStyle(compact: true))
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Input Device Picker
            HStack(spacing: 10) {
                Text("Input Device")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                Spacer()

                if isStaticPreview {
                    micDevicePickerLabel(title: activeMicName)
                } else {
                    Menu {
                        Button {
                            viewModel.selectMicrophone(id: nil)
                        } label: {
                            HStack {
                                Text("System Default")
                                if viewModel.settings.selectedMicrophoneID == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        let customDevices = viewModel.availableMicDevices.filter {
                            $0.id != MicrophoneDeviceOption.systemDefaultID
                        }
                        if !customDevices.isEmpty {
                            Divider()
                        }

                        ForEach(customDevices) { device in
                            Button {
                                viewModel.selectMicrophone(id: device.id)
                            } label: {
                                HStack {
                                    Text(verbatim: device.name)
                                    if viewModel.settings.selectedMicrophoneID == device.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        micDevicePickerLabel(title: activeMicName)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: true, vertical: false)
                }

                Button {
                    viewModel.refreshMicrophoneDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GraphiteSecondaryButtonStyle(compact: true))
                .help("Refresh microphone devices")
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Live VU Meter + Instant Mute + Gain Slider
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        viewModel.toggleMicrophoneMute()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: viewModel.settings.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                                .font(.system(size: 11, weight: .semibold))
                            Text(viewModel.settings.isMicrophoneMuted ? "Muted" : "Live")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundColor(viewModel.settings.isMicrophoneMuted ? Theme.crimson : Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.settings.isMicrophoneMuted ? Theme.crimsonSoft : Theme.surfaceElevated)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    viewModel.settings.isMicrophoneMuted ? Theme.crimson.opacity(0.45) : Theme.borderStrong,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    BackbufferVUMeter(
                        level: viewModel.micInputLevel,
                        isMuted: viewModel.settings.isMicrophoneMuted,
                        isActive: viewModel.settings.recordMicrophone
                    )
                }

                Spacer()

                HStack(spacing: 8) {
                    Text("Gain")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Theme.textSecondary)

                    BackbufferGainSlider(
                        value: viewModel.settings.clampedMicrophoneGain(),
                        onChange: { newGain in
                            viewModel.setMicrophoneGain(newGain)
                        }
                    )
                    .frame(width: 132, height: 18)

                    Text(verbatim: "\(Int((viewModel.settings.clampedMicrophoneGain() * 100.0).rounded()))%")
                        .font(Theme.mono(11.5, weight: .bold))
                        .foregroundColor(Theme.amber)
                        .frame(width: 42, alignment: .trailing)
                }
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            // Separate Game & Mic Tracks Option
            HStack(alignment: .top, spacing: 10) {
                BackbufferSwitchToggle(isOn: viewModel.settings.separateAudioTracksInMaster) {
                    viewModel.setSeparateAudioTracks(!viewModel.settings.separateAudioTracksInMaster)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Separate Game & Mic Tracks in Masters/")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Track 1 stores the mixed audio for Discord/QuickTime; Tracks 2–3 store isolated Game & Mic stems (disabled by default) for NLE editors.")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphiteCard(background: Theme.surfaceCard, cornerRadius: 10)
    }

    private var selectedMicrophoneLabel: String {
        guard let selectedID = viewModel.settings.selectedMicrophoneID,
              selectedID != MicrophoneDeviceOption.systemDefaultID else {
            if let def = viewModel.availableMicDevices.first(where: \.isDefault) {
                return "System Default (\(def.name))"
            }
            return "System Default"
        }
        if let match = viewModel.availableMicDevices.first(where: { $0.id == selectedID }) {
            return match.name
        }
        return "Selected Device"
    }

    private func micDevicePickerLabel(title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(.system(size: 10.5, weight: .semibold))
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
        .padding(.vertical, 5.5)
        .frame(minWidth: 210, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.borderStrong, lineWidth: 1)
        )
    }

    private func micPermissionBadge(_ state: MicrophonePermissionState) -> StatusPill {
        switch state {
        case .authorized:
            return StatusPill(text: "Authorized", icon: "checkmark.circle.fill", tone: .emerald, fontSize: 10)
        case .notDetermined:
            return StatusPill(text: "Not Asked", icon: "questionmark.circle", tone: .amber, fontSize: 10)
        case .denied:
            return StatusPill(text: "Denied", icon: "exclamationmark.triangle.fill", tone: .crimson, fontSize: 10)
        case .restricted:
            return StatusPill(text: "Restricted", icon: "lock.fill", tone: .crimson, fontSize: 10)
        }
    }

    // MARK: - Tab 3: Video & Storage

    @ViewBuilder
    private var videoAndStorageTabBody: some View {
        let content = VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                fpsCard
                resolutionCard
            }

            qualityCard

            HStack(alignment: .top, spacing: 10) {
                codecCard
                bufferDurationCard
            }

            shareCapCard
            outputFolderCard
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        if isStaticPreview {
            VStack(alignment: .leading, spacing: 0) {
                content
                Spacer(minLength: 0)
            }
        } else {
            ScrollView {
                content
            }
        }
    }

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
                        VStack(spacing: 1) {
                            Text(preset.displayName)
                                .font(Theme.tabular(11.5, weight: viewModel.settings.quality == preset ? .bold : .medium))
                            Text(qualityTagline(preset))
                                .font(Theme.mono(9.5, weight: .regular))
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(ShareCapOption.allCases) { option in
                        Button(option.displayName) {
                            viewModel.updateShareCap(option)
                        }
                        .buttonStyle(PillChoiceButtonStyle(isSelected: viewModel.settings.shareCap == option))
                    }
                }
                Text("Originals in Masters/ are never altered. Lowering the cap lazily re-compresses older clips on Copy Discord Clip.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
        }
    }

    private var outputFolderCard: some View {
        settingCard(title: "Clip Storage Folder", subtitle: "Masters/ + Shared/") {
            HStack(spacing: 8) {
                Text(verbatim: abbreviatedPath(viewModel.settings.outputRootPath))
                    .font(Theme.mono(11.5, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
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

    // MARK: - Toast & Sticky Live Estimator Footer

    private func settingsToastBar(_ toast: ToastBanner) -> some View {
        let toneColor: Color = {
            switch toast.tone {
            case .success: return Theme.emerald
            case .info, .warning: return Theme.amber
            case .error: return Theme.crimson
            }
        }()
        return HStack(spacing: 7) {
            Image(systemName: toast.tone == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11.5))
                .foregroundColor(toneColor)
            Text(verbatim: toast.message)
                .font(Theme.mono(11, weight: .medium))
                .foregroundColor(toneColor)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Theme.surfaceSubtle)
        .overlay(
            Rectangle().fill(toneColor.opacity(0.35)).frame(height: 1),
            alignment: .top
        )
    }

    private var stickyEstimatorFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.borderStrong)
                .frame(height: 1)

            HStack(spacing: 0) {
                estimatorMetric(
                    label: "Estimated Master (\(viewModel.settings.bufferDuration.rawValue)s)",
                    value: "~\(Theme.formatMB(viewModel.estimate.estimatedMasterMB))",
                    detail: viewModel.settings.separateAudioTracksInMaster ? "Includes +2 NLE stems" : "Untouched in Masters/",
                    valueColor: Theme.textPrimary
                )

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 38)

                estimatorMetric(
                    label: "RAM Ring Buffer",
                    value: "~\(Theme.formatMB(viewModel.estimate.estimatedRAMBufferMB))",
                    detail: viewModel.settings.recordMicrophone ? "Video + Sys + Mic PCM" : "+2s GOP headroom",
                    valueColor: Theme.textPrimary
                )

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 38)

                estimatorMetric(
                    label: "Share Auto-Compress",
                    value: shareEstimateHeadline,
                    detail: shareEstimateSubtitle,
                    valueColor: shareEstimateColor
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.surfaceSubtle)
        }
    }

    private func estimatorMetric(
        label: String,
        value: String,
        detail: String,
        valueColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(verbatim: label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(Theme.mono(14, weight: .bold))
                .foregroundColor(valueColor)
                .lineLimit(1)
            Text(verbatim: detail)
                .font(.system(size: 10.5))
                .foregroundColor(Theme.textMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }

    // MARK: - Layout Helpers

    private func settingCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Text(subtitle)
                    .font(Theme.mono(10.5, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
            content()
        }
        .padding(10)
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
            ? "Auto copy in Shared/"
            : "Under cap (no duplicate)"
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

// MARK: - Pure SwiftUI Studio Controls (Headless ImageRenderer Safe)

private struct BackbufferSwitchToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.amber : Theme.surfaceHover)
                    .overlay(
                        Capsule()
                            .strokeBorder(isOn ? Theme.amber : Theme.borderStrong, lineWidth: 1)
                    )
                Circle()
                    .fill(isOn ? Theme.amberInk : Theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .padding(2.5)
            }
            .frame(width: 34, height: 19)
        }
        .buttonStyle(.plain)
    }
}

private struct BackbufferVUMeter: View {
    let level: Double
    let isMuted: Bool
    let isActive: Bool

    private let segmentCount = 22

    var body: some View {
        let clamped = isActive && !isMuted ? min(1.0, max(0.0, level)) : 0.0
        let litCount = Int((clamped * Double(segmentCount)).rounded(.up))

        HStack(spacing: 2.5) {
            ForEach(0..<segmentCount, id: \.self) { index in
                let isLit = index < litCount
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(segmentColor(index: index, isLit: isLit))
                    .frame(width: 4, height: 14)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private func segmentColor(index: Int, isLit: Bool) -> Color {
        guard isLit else {
            return Theme.surfaceElevated
        }
        let fraction = Double(index) / Double(max(1, segmentCount - 1))
        if fraction >= 0.85 {
            return Theme.crimson
        }
        if fraction >= 0.62 {
            return Theme.amber
        }
        return Theme.emerald
    }
}

private struct BackbufferGainSlider: View {
    let value: Double // 0.0 ... 2.0
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(24, geo.size.width)
            let clamped = min(2.0, max(0.0, value))
            let fraction = CGFloat(clamped / 2.0)
            let thumbDiameter: CGFloat = 13
            let usable = max(1, width - thumbDiameter)
            let thumbX = usable * fraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.surfaceElevated)
                    .frame(height: 5)
                Capsule()
                    .fill(Theme.amber)
                    .frame(width: max(4, thumbX + thumbDiameter / 2), height: 5)
                Circle()
                    .fill(Theme.textPrimary)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .overlay(
                        Circle()
                            .strokeBorder(Theme.amber, lineWidth: 2)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 2, x: 0, y: 1)
                    .offset(x: thumbX)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let rel = min(1.0, max(0.0, (drag.location.x - thumbDiameter / 2) / usable))
                        let raw = Double(rel) * 2.0
                        let stepped = (raw / 0.05).rounded() * 0.05
                        onChange(min(2.0, max(0.0, stepped)))
                    }
            )
        }
    }
}

private struct GraphiteActionLinkStyle: ButtonStyle {
    enum Tone {
        case amber
        case neutral
    }

    let tone: Tone

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(tone == .amber ? Theme.amber : Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? Theme.surfaceHover
                            : (tone == .amber ? Theme.amberSoft : Theme.surfaceElevated)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(tone == .amber ? Theme.amber.opacity(0.35) : Theme.border, lineWidth: 1)
            )
    }
}
