import AppKit
import AVFoundation
import BackbufferCore
import Combine
import Foundation
import SwiftUI

struct CaptureTargetOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let isDisplay: Bool
    let systemImageName: String
    let target: CaptureTarget?

    init(target: CaptureTarget) {
        self.id = target.id
        self.title = target.title
        self.subtitle = target.subtitle
        self.isDisplay = target.isDisplay
        self.systemImageName = target.systemImageName
        self.target = target
    }

    init(id: String, title: String, subtitle: String, isDisplay: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isDisplay = isDisplay
        self.systemImageName = isDisplay ? "display" : "macwindow"
        self.target = nil
    }
}

struct ToastBanner: Equatable {
    enum Tone {
        case success
        case info
        case warning
        case error
    }

    let id: UUID
    let tone: Tone
    let message: String

    init(tone: Tone, message: String) {
        self.id = UUID()
        self.tone = tone
        self.message = message
    }
}

private final class ViewModelCleanupBag: @unchecked Sendable {
    let player: AVPlayer
    var playerEndObserver: NSObjectProtocol?
    var didBecomeActiveObserver: NSObjectProtocol?
    var timeObserverToken: Any?
    var toastDismissTask: Task<Void, Never>?

    init(player: AVPlayer) {
        self.player = player
    }

    deinit {
        toastDismissTask?.cancel()
        if let observer = playerEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let activeObserver = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case privacy
    case shortcutsAndMic
    case videoAndStorage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privacy: return "Allowed Apps"
        case .shortcutsAndMic: return "Shortcuts & Mic"
        case .videoAndStorage: return "Video & Storage"
        }
    }

    var systemImageName: String {
        switch self {
        case .privacy: return "lock.shield.fill"
        case .shortcutsAndMic: return "keyboard"
        case .videoAndStorage: return "slider.horizontal.3"
        }
    }
}

enum AppListFilter: String, CaseIterable, Identifiable {
    case all
    case allowed
    case running

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .allowed: return "Allowed"
        case .running: return "Open Now"
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var settings: CaptureSettings
    @Published private(set) var estimate: CaptureSizeEstimate
    @Published private(set) var clips: [ClipPairRecord] = []
    @Published var selectedClipID: String?
    @Published var trimRange: TrimRange = TrimRange(startSeconds: 0, endSeconds: 30)
    @Published var playheadSeconds: Double = 0
    @Published var isPlaying: Bool = false

    @Published private(set) var thumbnailsByClipID: [String: NSImage] = [:]
    @Published private(set) var filmstripByClipID: [String: [NSImage]] = [:]
    @Published private(set) var compressingClipIDs: Set<String> = []
    @Published private(set) var isExportingTrim: Bool = false
    @Published private(set) var isLoadingLibrary: Bool = false
    @Published var toast: ToastBanner?

    @Published private(set) var targetOptions: [CaptureTargetOption] = []
    @Published var selectedTargetID: String?
    @Published var previewCaptureStateOverride: CaptureState?
    @Published var previewCaptureSummaryOverride: String?
    @Published var previewInstallIssueOverride: AppInstallLocationIssue? = nil
    @Published var previewBundleReplacedOverride: Bool? = nil
    @Published var librarySearchText: String = ""

    // v1.1.0 Studio Console, Privacy & Microphone state
    @Published var selectedSettingsTab: SettingsTab = .privacy
    @Published var appSearchQuery: String = ""
    @Published var appListFilter: AppListFilter = .all
    @Published var includeHelperApps: Bool = false
    @Published private(set) var discoveredApps: [RunningAppCandidate] = []

    let captureCoordinator: CaptureCoordinator
    let hotKeyManager: HotKeyManager
    let player: AVPlayer
    var onRequestOpenSettingsWindow: (() -> Void)?

    private let settingsStore: SettingsStore
    private let hadPriorSettingsAtLaunch: Bool
    private var libraryStore: ClipLibraryStore?
    private let launchServicesEnabled: Bool
    private var coordinatorCancellable: AnyCancellable?
    private var microphoneCancellable: AnyCancellable?
    private let cleanupBag: ViewModelCleanupBag
    private var hasBootstrapped = false
    private var lastActiveRecheckUptime: TimeInterval = 0

    init(
        settingsStore: SettingsStore = SettingsStore(),
        launchServices: Bool = true
    ) {
        self.settingsStore = settingsStore
        self.hadPriorSettingsAtLaunch = settingsStore.hasPersistedSettings
        self.launchServicesEnabled = launchServices
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        self.estimate = SettingsStore.estimate(for: loadedSettings)
        self.captureCoordinator = CaptureCoordinator()
        self.hotKeyManager = HotKeyManager.shared
        let avPlayer = AVPlayer()
        self.player = avPlayer
        self.cleanupBag = ViewModelCleanupBag(player: avPlayer)

        if launchServices {
            self.libraryStore = try? ClipLibraryStore(settings: loadedSettings)
            self.coordinatorCancellable = captureCoordinator.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            self.microphoneCancellable = captureCoordinator.microphoneEngine.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            self.cleanupBag.didBecomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleApplicationDidBecomeActive()
                }
            }
            setupPlayerObservers()
            hotKeyManager.setHandler(for: .saveClip) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.saveClipNow()
                }
            }
            hotKeyManager.setHandler(for: .togglePause) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.toggleRecordingPause()
                }
            }
        }
    }

    // MARK: - Computed Properties

    var effectiveCaptureState: CaptureState {
        previewCaptureStateOverride ?? captureCoordinator.state
    }

    var effectiveCaptureSummary: String {
        previewCaptureSummaryOverride ?? captureCoordinator.activeCaptureSummary
    }

    var effectiveInstallIssue: AppInstallLocationIssue {
        previewInstallIssueOverride ?? captureCoordinator.installLocationIssue
    }

    var effectiveBundleReplacedOnDisk: Bool {
        previewBundleReplacedOverride ?? captureCoordinator.bundleReplacedOnDisk
    }

    var filteredApps: [RunningAppCandidate] {
        AppPrivacyCatalog.filterApps(
            discoveredApps,
            searchQuery: appSearchQuery,
            onlyAllowed: appListFilter == .allowed,
            onlyRunning: appListFilter == .running,
            settings: settings
        )
    }

    var allowedAppCount: Int {
        switch settings.privacyMode {
        case .strictAllowlist:
            return settings.allowedAppBundleIDs.count
        case .allowAllExceptBlocked:
            return discoveredApps.filter { settings.isApplicationAllowed(bundleIdentifier: $0.bundleIdentifier) }.count
        }
    }

    var openAllowedAppCount: Int {
        discoveredApps.filter { $0.isRunning && settings.isApplicationAllowed(bundleIdentifier: $0.bundleIdentifier) }.count
    }

    var availableMicDevices: [MicrophoneDeviceOption] {
        captureCoordinator.microphoneEngine.availableDevices
    }

    var micInputLevel: Double {
        captureCoordinator.microphoneEngine.inputLevel
    }

    var micPermissionState: MicrophonePermissionState {
        captureCoordinator.microphoneEngine.permissionState
    }

    var isPrivacyLocked: Bool {
        if case .awaitingAllowedApps = effectiveCaptureState {
            return true
        }
        return false
    }

    var selectedClip: ClipPairRecord? {
        if let selectedClipID, let match = clips.first(where: { $0.id == selectedClipID }) {
            return match
        }
        return clips.first
    }

    var filteredClips: [ClipPairRecord] {
        let query = librarySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return clips }
        return clips.filter { clip in
            clip.displayTitle.lowercased().contains(query)
            || clip.codecName.lowercased().contains(query)
            || clip.resolutionLabel.lowercased().contains(query)
        }
    }

    var selectedTargetOption: CaptureTargetOption? {
        if let selectedTargetID, let match = targetOptions.first(where: { $0.id == selectedTargetID }) {
            return match
        }
        return targetOptions.first
    }

    func effectiveShareStatus(for record: ClipPairRecord) -> ShareStatus {
        if compressingClipIDs.contains(record.id) {
            return .compressing
        }
        return record.shareStatus
    }

    var activePixelSizeHint: CGSize? {
        if let dims = captureCoordinator.activePixelDimensions {
            return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        }
        if let target = selectedTargetOption?.target {
            let logical = target.logicalSize
            let dims = CaptureDimensionCalculator.computeTargetDimensions(
                logicalWidth: logical.width,
                logicalHeight: logical.height,
                pointPixelScale: 2.0,
                cap: settings.resolutionCap
            )
            return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        }
        return nil
    }

    // MARK: - Bootstrap & Live Capture

    func bootstrapIfNeeded() async {
        guard launchServicesEnabled, !hasBootstrapped else { return }
        hasBootstrapped = true

        if !hotKeyManager.register(shortcut: settings.saveHotKey, for: .saveClip) {
            showToast(.warning, "Hotkey \(settings.saveHotKey.displayString) conflict — pick another in Shortcuts & Mic.")
        }
        if let pauseHotKey = settings.togglePauseHotKey {
            if !hotKeyManager.register(shortcut: pauseHotKey, for: .togglePause) {
                showToast(.warning, "Pause hotkey \(pauseHotKey.displayString) conflict — pick another in Shortcuts & Mic.")
            }
        } else {
            hotKeyManager.unregister(slot: .togglePause)
        }

        captureCoordinator.refreshBundleDiagnostics()
        refreshDiscoveredApps()
        refreshMicrophoneDevices()
        await captureCoordinator.applyMicrophoneSettings(settings)
        await reloadClips()
        await refreshTargetsAndAutoStart()
    }

    func openSettings(tab: SettingsTab) {
        selectedSettingsTab = tab
        if tab == .privacy {
            refreshDiscoveredApps()
        } else if tab == .shortcutsAndMic {
            refreshMicrophoneDevices()
        }
        guard launchServicesEnabled else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: {
            $0.isVisible && ($0.title == "Backbuffer Settings" || $0.identifier?.rawValue == "settings")
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            onRequestOpenSettingsWindow?()
        }
    }

    func refreshTargetsAndAutoStart() async {
        guard launchServicesEnabled else { return }
        captureCoordinator.refreshBundleDiagnostics()
        refreshDiscoveredApps()

        do {
            let result = try await captureCoordinator.availableTargets()
            settingsStore.setLastAuthorizedExecutableHash(captureCoordinator.permissionManager.launchExecutableHash)

            var options: [CaptureTargetOption] = result.displays.map {
                CaptureTargetOption(target: .display($0))
            }
            options.append(contentsOf: result.windows.map {
                CaptureTargetOption(target: .window($0))
            })
            targetOptions = options

            if selectedTargetID == nil || !options.contains(where: { $0.id == selectedTargetID }) {
                selectedTargetID = options.first?.id
            }

            if !captureCoordinator.state.isActivelyBuffering,
               !captureCoordinator.isPaused,
               let chosen = selectedTargetOption?.target {
                try await captureCoordinator.startCapture(target: chosen, settings: settings)
                settingsStore.setLastAuthorizedExecutableHash(captureCoordinator.permissionManager.launchExecutableHash)
            }
        } catch BackbufferError.screenRecordingPermissionDenied {
            let didReset = await captureCoordinator.attemptOneTimeStalePermissionRecovery(
                settingsStore: settingsStore,
                hasExistingClips: hadPriorSettingsAtLaunch || !clips.isEmpty
            )
            if didReset {
                showToast(
                    .warning,
                    "Reset outdated Screen Recording signature after update — click Allow or Check & Relaunch once."
                )
            }
        } catch BackbufferError.noAllowedAppsSelected {
            // SCShareableContent already succeeded before entering Privacy Lock.
            settingsStore.setLastAuthorizedExecutableHash(captureCoordinator.permissionManager.launchExecutableHash)
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func selectCaptureTarget(_ option: CaptureTargetOption) async {
        selectedTargetID = option.id
        guard launchServicesEnabled, let target = option.target else { return }
        do {
            try await captureCoordinator.startCapture(target: target, settings: settings)
            settingsStore.setLastAuthorizedExecutableHash(captureCoordinator.permissionManager.launchExecutableHash)
            estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)
            showToast(.info, "Capturing \(option.title)")
        } catch BackbufferError.noAllowedAppsSelected {
            // SCShareableContent succeeded before Privacy Lock paused buffering.
            settingsStore.setLastAuthorizedExecutableHash(captureCoordinator.permissionManager.launchExecutableHash)
        } catch BackbufferError.screenRecordingPermissionDenied {
            // Permission recovery banner surfaces controls cleanly without duplicate error toast.
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    // MARK: - Screen Recording Permission & Install Recovery

    func openScreenCaptureSettings() {
        captureCoordinator.permissionManager.openSystemSettingsScreenCapture(triggerPrompt: true)
    }

    func checkOrRelaunchAfterPermissionGrant() async {
        guard launchServicesEnabled else {
            showToast(.info, "Rechecked Screen Recording status")
            return
        }
        await refreshTargetsAndAutoStart()
        if captureCoordinator.state != .permissionDenied {
            showToast(.success, "Screen Recording active — replay buffering ready")
        } else {
            showToast(.info, "Relaunching Backbuffer so macOS applies Screen Recording permission...")
            captureCoordinator.permissionManager.relaunchApplication()
        }
    }

    func resetStuckScreenPermissionAndRelaunch() {
        guard launchServicesEnabled else {
            showToast(.info, "Reset Screen Recording signature & relaunch")
            return
        }
        if let hash = captureCoordinator.permissionManager.launchExecutableHash {
            settingsStore.setLastAutoResetExecutableHash(hash)
        }
        captureCoordinator.permissionManager.runTCCReset()
        captureCoordinator.permissionManager.openSystemSettingsScreenCapture(triggerPrompt: true)
        captureCoordinator.permissionManager.relaunchApplication()
    }

    func installToApplicationsAndRelaunch() {
        guard launchServicesEnabled else {
            showToast(.info, "Install to /Applications & relaunch")
            return
        }
        do {
            try captureCoordinator.permissionManager.installToApplicationsAndRelaunch(resetTCC: true)
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func relaunchApplicationNow() {
        guard launchServicesEnabled else {
            showToast(.info, "Relaunching Backbuffer...")
            return
        }
        captureCoordinator.permissionManager.relaunchApplication()
    }

    private func handleApplicationDidBecomeActive() async {
        guard launchServicesEnabled, hasBootstrapped else { return }
        captureCoordinator.refreshBundleDiagnostics()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastActiveRecheckUptime >= 1.5 else { return }
        lastActiveRecheckUptime = now

        if captureCoordinator.state == .permissionDenied {
            await refreshTargetsAndAutoStart()
        }
    }

    func toggleRecordingPause() async {
        if captureCoordinator.isPaused {
            captureCoordinator.resumeBuffering()
        } else if captureCoordinator.state.isActivelyBuffering {
            captureCoordinator.pauseBuffering()
        } else {
            await refreshTargetsAndAutoStart()
        }
    }

    func saveClipNow() async {
        guard launchServicesEnabled else { return }
        do {
            let store = try ensureLibraryStore()
            let savedURL = try await captureCoordinator.saveCurrentBuffer(
                libraryStore: store,
                activeCap: settings.shareCap,
                audioBitrateBps: estimate.audioBitrateBps
            )
            playSaveCueSound(success: true)
            showToast(.success, "Saved Master: \(savedURL.lastPathComponent)")
            await reloadClips(selectingMasterURL: savedURL)

            if settings.shareCap != .off,
               let savedRecord = clips.first(where: { $0.masterURL.standardizedFileURL == savedURL.standardizedFileURL }),
               case .overNewCap = savedRecord.shareStatus {
                scheduleBackgroundShareCompression(for: savedRecord)
            }
        } catch {
            playSaveCueSound(success: false)
            showToast(.error, error.localizedDescription)
        }
    }

    // MARK: - Settings Mutations

    func updateFPS(_ fps: CaptureFPS) {
        guard settings.fps != fps else { return }
        settings.fps = fps
        persistAndApplyCaptureChange(requiresStreamRestart: true)
    }

    func updateResolutionCap(_ cap: ResolutionCap) {
        guard settings.resolutionCap != cap else { return }
        settings.resolutionCap = cap
        persistAndApplyCaptureChange(requiresStreamRestart: true)
    }

    func updateQuality(_ quality: QualityPreset) {
        guard settings.quality != quality else { return }
        settings.quality = quality
        persistAndApplyCaptureChange(requiresStreamRestart: true)
    }

    func updateCodec(_ codec: VideoCodecChoice) {
        guard settings.codec != codec else { return }
        settings.codec = codec
        persistAndApplyCaptureChange(requiresStreamRestart: true)
    }

    func updateBufferDuration(_ duration: BufferDurationOption) {
        guard settings.bufferDuration != duration else { return }
        settings.bufferDuration = duration
        persistAndApplyCaptureChange(requiresStreamRestart: false)
        if launchServicesEnabled {
            captureCoordinator.updateBufferDurationIfActive(duration)
        }
    }

    func updateShareCap(_ cap: ShareCapOption) {
        guard settings.shareCap != cap else { return }
        settings.shareCap = cap
        settingsStore.save(settings)
        estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)

        // Q7 = A: NEVER trigger background batch re-encoding when Share Cap changes.
        // Only recompute ShareStatus badges lazily so Copy Share Clip resolves on demand.
        if launchServicesEnabled {
            Task { [weak self] in
                await self?.reloadClips()
            }
        }
    }

    func updateSaveHotKey(_ shortcut: HotKeyShortcut?) {
        guard let shortcut else { return }
        settings.saveHotKey = shortcut
        settingsStore.save(settings)
        guard launchServicesEnabled else { return }
        if !hotKeyManager.register(shortcut: shortcut, for: .saveClip) {
            showToast(.error, "Could not register \(shortcut.displayString) — reserved by macOS or another app.")
        } else if HotKeyManager.isSystemSymbolicConflict(shortcut) {
            showToast(.warning, "Save hotkey \(shortcut.displayString) active, but overlaps a macOS system shortcut.")
        } else {
            showToast(.success, "Save hotkey updated to \(shortcut.displayString)")
        }
    }

    func updateTogglePauseHotKey(_ shortcut: HotKeyShortcut?) {
        settings.togglePauseHotKey = shortcut
        settingsStore.save(settings)
        guard launchServicesEnabled else { return }
        if let shortcut {
            if !hotKeyManager.register(shortcut: shortcut, for: .togglePause) {
                showToast(.error, "Could not register pause hotkey \(shortcut.displayString).")
            } else if HotKeyManager.isSystemSymbolicConflict(shortcut) {
                showToast(.warning, "Pause hotkey \(shortcut.displayString) overlaps a macOS system shortcut.")
            } else {
                showToast(.success, "Pause/Resume hotkey updated to \(shortcut.displayString)")
            }
        } else {
            hotKeyManager.unregister(slot: .togglePause)
            showToast(.info, "Pause/Resume hotkey cleared")
        }
    }

    func updatePlaySoundOnSave(_ enabled: Bool) {
        guard settings.playSoundOnSave != enabled else { return }
        settings.playSoundOnSave = enabled
        settingsStore.save(settings)
    }

    // MARK: - Microphone Controls

    func toggleMicrophone() {
        let nextEnabled = !settings.recordMicrophone
        settings.recordMicrophone = nextEnabled
        settingsStore.save(settings)
        estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)

        guard launchServicesEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            if nextEnabled {
                let perm = self.captureCoordinator.microphoneEngine.currentPermissionState()
                if perm == .notDetermined {
                    let granted = await self.captureCoordinator.microphoneEngine.requestPermissionIfNeeded()
                    self.captureCoordinator.microphoneEngine.refreshDevices()
                    if !granted {
                        self.settings.recordMicrophone = false
                        self.settingsStore.save(self.settings)
                        self.estimate = SettingsStore.estimate(for: self.settings, targetPixelSize: self.activePixelSizeHint)
                        self.showToast(.warning, "Microphone permission was declined.")
                        return
                    }
                } else if perm == .denied || perm == .restricted {
                    self.settings.recordMicrophone = false
                    self.settingsStore.save(self.settings)
                    self.estimate = SettingsStore.estimate(for: self.settings, targetPixelSize: self.activePixelSizeHint)
                    self.openMicrophonePrivacySettings()
                    self.showToast(.warning, "Enable Microphone permission for Backbuffer in System Settings.")
                    return
                }
            }
            await self.captureCoordinator.applyMicrophoneSettings(self.settings)
        }
    }

    func toggleMicrophoneMute() {
        settings.isMicrophoneMuted.toggle()
        settingsStore.save(settings)
        guard launchServicesEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.captureCoordinator.applyMicrophoneSettings(self.settings)
        }
    }

    func setMicrophoneGain(_ gain: Double) {
        let clamped = min(max(gain, 0.0), 2.0)
        guard abs(settings.microphoneGain - clamped) > 0.001 else { return }
        settings.microphoneGain = clamped
        settingsStore.save(settings)
        guard launchServicesEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.captureCoordinator.applyMicrophoneSettings(self.settings)
        }
    }

    func selectMicrophone(id: String?) {
        let normalized: String? = (id == nil || id == MicrophoneDeviceOption.systemDefaultID) ? nil : id
        guard settings.selectedMicrophoneID != normalized else { return }
        settings.selectedMicrophoneID = normalized
        settingsStore.save(settings)
        guard launchServicesEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.captureCoordinator.applyMicrophoneSettings(self.settings)
        }
    }

    func setSeparateAudioTracks(_ enabled: Bool) {
        guard settings.separateAudioTracksInMaster != enabled else { return }
        settings.separateAudioTracksInMaster = enabled
        settingsStore.save(settings)
        estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)
    }

    func refreshMicrophoneDevices() {
        guard launchServicesEnabled else { return }
        captureCoordinator.microphoneEngine.refreshDevices()
    }

    func requestMicrophonePermission() {
        guard launchServicesEnabled else { return }
        let perm = captureCoordinator.microphoneEngine.currentPermissionState()
        if perm == .denied || perm == .restricted {
            openMicrophonePrivacySettings()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.captureCoordinator.microphoneEngine.requestPermissionIfNeeded()
            self.captureCoordinator.microphoneEngine.refreshDevices()
            if granted {
                if !self.settings.recordMicrophone {
                    self.settings.recordMicrophone = true
                    self.settingsStore.save(self.settings)
                    self.estimate = SettingsStore.estimate(for: self.settings, targetPixelSize: self.activePixelSizeHint)
                }
                await self.captureCoordinator.applyMicrophoneSettings(self.settings)
                self.showToast(.success, "Microphone ready for commentary recording")
            } else {
                self.showToast(.warning, "Microphone access is required to record voice commentary.")
            }
        }
    }

    // MARK: - App Privacy Allowlist / Blocklist

    func refreshDiscoveredApps() {
        guard launchServicesEnabled else { return }
        discoveredApps = AppPrivacyCatalog.discoverApps(
            settings: settings,
            includeHelpers: includeHelperApps
        )
    }

    func setIncludeHelperApps(_ include: Bool) {
        guard includeHelperApps != include else { return }
        includeHelperApps = include
        refreshDiscoveredApps()
    }

    func setPrivacyMode(_ mode: AppPrivacyMode) {
        guard settings.privacyMode != mode else { return }
        settings.privacyMode = mode
        persistAndApplyPrivacyChange()
    }

    func setApplicationAllowed(_ bundleIdentifier: String, displayName: String, allowed: Bool) {
        rememberApp(bundleIdentifier: bundleIdentifier, displayName: displayName)
        switch settings.privacyMode {
        case .strictAllowlist:
            if allowed {
                settings.allowedAppBundleIDs.insert(bundleIdentifier)
            } else {
                settings.allowedAppBundleIDs.remove(bundleIdentifier)
            }
        case .allowAllExceptBlocked:
            if allowed {
                settings.blockedAppBundleIDs.remove(bundleIdentifier)
            } else {
                settings.blockedAppBundleIDs.insert(bundleIdentifier)
            }
        }
        persistAndApplyPrivacyChange()
    }

    func allowAllRunningApps() {
        let running = discoveredApps.filter(\.isRunning)
        for app in running {
            rememberApp(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
        }
        switch settings.privacyMode {
        case .strictAllowlist:
            settings.allowedAppBundleIDs.formUnion(running.map(\.bundleIdentifier))
        case .allowAllExceptBlocked:
            settings.blockedAppBundleIDs.subtract(running.map(\.bundleIdentifier))
        }
        persistAndApplyPrivacyChange()
        showToast(.info, "Allowed \(running.count) running app(s)")
    }

    func clearAllowedApps() {
        switch settings.privacyMode {
        case .strictAllowlist:
            settings.allowedAppBundleIDs.removeAll()
        case .allowAllExceptBlocked:
            settings.blockedAppBundleIDs.formUnion(discoveredApps.map(\.bundleIdentifier))
        }
        persistAndApplyPrivacyChange()
        showToast(.info, settings.privacyMode == .strictAllowlist ? "Privacy Lock active — allowed apps cleared" : "All listed apps hidden")
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backbuffer Clip Folder"
        panel.message = "Backbuffer stores untouched originals in Masters/ and Discord copies in Shared/."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputRootURL

        if panel.runModal() == .OK, let chosenURL = panel.url {
            settings.outputRootPath = chosenURL.path
            settingsStore.save(settings)
            if launchServicesEnabled {
                do {
                    libraryStore = try ClipLibraryStore(settings: settings)
                    Task { [weak self] in
                        await self?.reloadClips()
                    }
                    showToast(.success, "Output folder set to \(chosenURL.lastPathComponent)")
                } catch {
                    showToast(.error, error.localizedDescription)
                }
            }
        }
    }

    func resetSettingsToDefault() {
        let previous = settings
        settings = settingsStore.reset()
        estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)

        guard launchServicesEnabled else { return }
        if previous.saveHotKey != settings.saveHotKey {
            _ = hotKeyManager.register(shortcut: settings.saveHotKey, for: .saveClip)
        }
        if let pauseKey = settings.togglePauseHotKey {
            _ = hotKeyManager.register(shortcut: pauseKey, for: .togglePause)
        } else {
            hotKeyManager.unregister(slot: .togglePause)
        }
        libraryStore = try? ClipLibraryStore(settings: settings)
        refreshDiscoveredApps()
        Task { [weak self] in
            guard let self else { return }
            await self.reloadClips()
            await self.captureCoordinator.applyMicrophoneSettings(self.settings)
            await self.captureCoordinator.applyPrivacySettings(self.settings)
            if self.captureCoordinator.state.isActivelyBuffering,
               let target = self.captureCoordinator.activeTarget {
                try? await self.captureCoordinator.startCapture(target: target, settings: self.settings)
            }
        }
        showToast(.info, "Settings reset to Balanced defaults")
    }

    // MARK: - Library & Trimmer Actions

    func reloadClips(selectingMasterURL: URL? = nil) async {
        guard launchServicesEnabled else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        do {
            let store = try ensureLibraryStore()
            let loaded = try await store.loadClips(activeCap: settings.shareCap)
            clips = loaded

            if let targetURL = selectingMasterURL?.standardizedFileURL,
               let match = loaded.first(where: { $0.masterURL.standardizedFileURL == targetURL }) {
                selectClip(match)
            } else if let currentID = selectedClipID,
                      let stillPresent = loaded.first(where: { $0.id == currentID }) {
                selectedClipID = stillPresent.id
            } else if let first = loaded.first {
                selectClip(first)
            } else {
                selectedClipID = nil
                pausePlayer()
                player.replaceCurrentItem(with: nil)
            }

            await loadThumbnailsIfNeeded(for: loaded, store: store)
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func selectClip(_ record: ClipPairRecord) {
        selectedClipID = record.id
        let safeDuration = max(0.5, record.durationSeconds)
        trimRange = TrimRange(startSeconds: 0, endSeconds: safeDuration)
        playheadSeconds = 0
        pausePlayer()

        guard launchServicesEnabled else { return }
        if FileManager.default.fileExists(atPath: record.masterURL.path) {
            let item = AVPlayerItem(url: record.masterURL)
            player.replaceCurrentItem(with: item)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        Task { [weak self] in
            await self?.loadFilmstripIfNeeded(for: record)
        }
    }

    func scrubPlayer(to seconds: Double) {
        playheadSeconds = seconds
        guard launchServicesEnabled, player.currentItem != nil else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayPause() {
        guard launchServicesEnabled else {
            isPlaying.toggle()
            return
        }
        if isPlaying {
            pausePlayer()
        } else {
            if playheadSeconds < trimRange.startSeconds || playheadSeconds >= trimRange.endSeconds - 0.05 {
                scrubPlayer(to: trimRange.startSeconds)
            }
            player.play()
            isPlaying = true
        }
    }

    func copyShareClip(_ record: ClipPairRecord) async {
        guard launchServicesEnabled else {
            showToast(.success, "Copied \(record.stem)_share.mp4 to clipboard")
            return
        }

        do {
            let store = try ensureLibraryStore()
            compressingClipIDs.insert(record.id)
            defer { compressingClipIDs.remove(record.id) }

            let shareURL = try await store.resolveShareClip(
                for: record,
                activeCap: settings.shareCap,
                codec: settings.codec
            )
            writeURLToPasteboard(shareURL)
            await reloadClips(selectingMasterURL: record.masterURL)

            let sizeText = (try? FileManager.default.attributesOfItem(atPath: shareURL.path)[.size] as? NSNumber)
                .map { Theme.formatMB($0.int64Value) } ?? ""
            let suffix = sizeText.isEmpty ? "" : " (\(sizeText))"
            showToast(.success, "Copied \(shareURL.lastPathComponent)\(suffix) — ready to paste in Discord")
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func revealMaster(_ record: ClipPairRecord) {
        guard launchServicesEnabled else {
            showToast(.info, "Revealed Masters/\(record.masterURL.lastPathComponent) in Finder")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([record.masterURL])
    }

    func saveMasterTrim() async {
        guard let clip = selectedClip else { return }
        guard launchServicesEnabled else {
            showToast(.success, "Saved lossless trim to Masters/")
            return
        }

        isExportingTrim = true
        defer { isExportingTrim = false }

        do {
            let store = try ensureLibraryStore()
            let outputURL = store.nextTrimMasterURL(from: clip.masterURL, range: trimRange)
            _ = try await ClipTrimmer.trimLossless(
                masterURL: clip.masterURL,
                range: trimRange,
                outputURL: outputURL
            )
            showToast(.success, "Saved lossless trim: \(outputURL.lastPathComponent)")
            await reloadClips(selectingMasterURL: outputURL)

            if settings.shareCap != .off,
               let newRecord = clips.first(where: { $0.masterURL.standardizedFileURL == outputURL.standardizedFileURL }),
               case .overNewCap = newRecord.shareStatus {
                scheduleBackgroundShareCompression(for: newRecord)
            }
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func copyCompressedTrim() async {
        guard let clip = selectedClip else { return }
        guard launchServicesEnabled else {
            showToast(.success, "Copied compressed trim to clipboard")
            return
        }

        isExportingTrim = true
        defer { isExportingTrim = false }

        do {
            let store = try ensureLibraryStore()
            let outputURL = store.shareURL(for: clip.masterURL, trimRange: trimRange)
            let resultURL = try await ClipTrimmer.trimCompressed(
                masterURL: clip.masterURL,
                range: trimRange,
                outputURL: outputURL,
                shareCap: settings.shareCap,
                codec: settings.codec
            )
            writeURLToPasteboard(resultURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: resultURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let mbLabel = bytes > 0 ? " (\(Theme.formatMB(bytes)))" : ""
            showToast(.success, "Copied Discord trim \(resultURL.lastPathComponent)\(mbLabel)")
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func deleteClip(_ record: ClipPairRecord, shareOnly: Bool = false) async {
        guard launchServicesEnabled else {
            if !shareOnly {
                clips.removeAll { $0.id == record.id }
            }
            return
        }

        do {
            let store = try ensureLibraryStore()
            try store.deleteClip(record, shareOnly: shareOnly)
            if shareOnly {
                showToast(.info, "Removed Shared/ copy for \(record.displayTitle)")
            } else {
                showToast(.info, "Deleted \(record.displayTitle)")
            }
            await reloadClips()
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func estimatedTrimMasterMB(for record: ClipPairRecord) -> Double {
        let safeSourceDur = max(0.25, record.durationSeconds)
        let ratio = min(1.0, max(0.0, trimRange.durationSeconds / safeSourceDur))
        return (Double(record.masterBytes) * ratio) / 1_000_000.0
    }

    // MARK: - Preview Harness Factory (Zero TCC / Zero Disk)

    static func makePreviewSample(
        settings: CaptureSettings = .default,
        clips: [ClipPairRecord],
        selectedClipID: String?,
        trimRange: TrimRange,
        playheadSeconds: Double,
        thumbnailsByClipID: [String: NSImage],
        filmstripByClipID: [String: [NSImage]],
        targetOptions: [CaptureTargetOption],
        selectedTargetID: String?,
        captureState: CaptureState,
        toast: ToastBanner? = nil,
        selectedSettingsTab: SettingsTab = .privacy,
        previewApps: [RunningAppCandidate] = [],
        previewMicDevices: [MicrophoneDeviceOption] = [],
        previewMicLevel: Double = 0.0,
        previewMicPermission: MicrophonePermissionState = .authorized,
        appSearchQuery: String = "",
        appListFilter: AppListFilter = .all,
        activeCaptureSummary: String? = nil,
        installIssueOverride: AppInstallLocationIssue? = nil,
        bundleReplacedOverride: Bool? = nil
    ) -> AppViewModel {
        let vm = AppViewModel(settingsStore: SettingsStore(userDefaults: UserDefaults(suiteName: "io.malachiteore.backbuffer.preview") ?? .standard), launchServices: false)
        vm.settings = settings
        vm.estimate = SettingsStore.estimate(
            for: settings,
            targetPixelSize: CGSize(width: 1920, height: 1080)
        )
        vm.clips = clips
        vm.selectedClipID = selectedClipID
        vm.trimRange = trimRange
        vm.playheadSeconds = playheadSeconds
        vm.thumbnailsByClipID = thumbnailsByClipID
        vm.filmstripByClipID = filmstripByClipID
        vm.targetOptions = targetOptions
        vm.selectedTargetID = selectedTargetID
        vm.previewCaptureStateOverride = captureState
        vm.previewCaptureSummaryOverride = activeCaptureSummary
        vm.previewInstallIssueOverride = installIssueOverride
        vm.previewBundleReplacedOverride = bundleReplacedOverride
        vm.toast = toast
        vm.selectedSettingsTab = selectedSettingsTab
        vm.discoveredApps = previewApps
        vm.appSearchQuery = appSearchQuery
        vm.appListFilter = appListFilter
        vm.captureCoordinator.microphoneEngine.setPreviewState(
            devices: previewMicDevices,
            level: previewMicLevel,
            permission: previewMicPermission
        )
        return vm
    }

    // MARK: - Private Helpers

    private func rememberApp(bundleIdentifier: String, displayName: String) {
        if let idx = settings.rememberedApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            if settings.rememberedApps[idx].displayName != displayName {
                settings.rememberedApps[idx] = RememberedAppInfo(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName
                )
            }
        } else {
            settings.rememberedApps.append(
                RememberedAppInfo(bundleIdentifier: bundleIdentifier, displayName: displayName)
            )
        }
    }

    private func persistAndApplyPrivacyChange() {
        settingsStore.save(settings)
        guard launchServicesEnabled else {
            // Re-trigger SwiftUI updates on static/offline view models if needed.
            discoveredApps = discoveredApps.map { $0 }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.captureCoordinator.applyPrivacySettings(self.settings)
            self.refreshDiscoveredApps()
        }
    }

    private func playSaveCueSound(success: Bool) {
        guard settings.playSoundOnSave else { return }
        let name = NSSound.Name(success ? "Tink" : "Basso")
        NSSound(named: name)?.play()
    }

    private func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func ensureLibraryStore() throws -> ClipLibraryStore {
        if let existing = libraryStore,
           existing.rootDirectory.standardizedFileURL == settings.outputRootURL.standardizedFileURL {
            return existing
        }
        let created = try ClipLibraryStore(settings: settings)
        libraryStore = created
        return created
    }

    private func persistAndApplyCaptureChange(requiresStreamRestart: Bool) {
        settingsStore.save(settings)
        estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)

        guard launchServicesEnabled, requiresStreamRestart else { return }
        if captureCoordinator.state.isActivelyBuffering,
           let activeTarget = captureCoordinator.activeTarget {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.captureCoordinator.startCapture(target: activeTarget, settings: self.settings)
                } catch {
                    self.showToast(.error, error.localizedDescription)
                }
            }
        }
    }

    private func scheduleBackgroundShareCompression(for record: ClipPairRecord) {
        compressingClipIDs.insert(record.id)
        let activeCap = settings.shareCap
        let activeCodec = settings.codec
        Task { [weak self] in
            guard let self else { return }
            defer { self.compressingClipIDs.remove(record.id) }
            do {
                let store = try self.ensureLibraryStore()
                _ = try await store.resolveShareClip(
                    for: record,
                    activeCap: activeCap,
                    codec: activeCodec
                )
                await self.reloadClips(selectingMasterURL: self.selectedClip?.masterURL)
            } catch {
                self.showToast(.warning, "Background Share compress deferred: \(error.localizedDescription)")
            }
        }
    }

    private func loadThumbnailsIfNeeded(for records: [ClipPairRecord], store: ClipLibraryStore) async {
        for record in records {
            if thumbnailsByClipID[record.id] != nil { continue }
            if let cgImage = try? await store.thumbnail(for: record.masterURL, atSeconds: min(0.5, max(0.0, record.durationSeconds * 0.2))) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                thumbnailsByClipID[record.id] = nsImage
            }
        }
    }

    private func loadFilmstripIfNeeded(for record: ClipPairRecord) async {
        if filmstripByClipID[record.id] != nil { return }
        guard let store = try? ensureLibraryStore() else { return }
        if let cgImages = try? await store.filmstripThumbnails(for: record.masterURL, count: 10) {
            let images = cgImages.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            filmstripByClipID[record.id] = images
        }
    }

    private func writeURLToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    private func pausePlayer() {
        player.pause()
        isPlaying = false
    }

    private func setupPlayerObservers() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        cleanupBag.timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
            let secs = CMTimeGetSeconds(cmTime)
            Task { @MainActor [weak self] in
                guard let self, secs.isFinite else { return }
                self.playheadSeconds = secs
                if self.isPlaying && secs >= self.trimRange.endSeconds {
                    self.pausePlayer()
                    self.scrubPlayer(to: self.trimRange.startSeconds)
                }
            }
        }

        cleanupBag.playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let objectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self,
                      let current = self.player.currentItem,
                      objectID == ObjectIdentifier(current) else {
                    return
                }
                self.pausePlayer()
                self.scrubPlayer(to: self.trimRange.startSeconds)
            }
        }
    }

    private func showToast(_ tone: ToastBanner.Tone, _ message: String) {
        cleanupBag.toastDismissTask?.cancel()
        let banner = ToastBanner(tone: tone, message: message)
        toast = banner
        let bannerID = banner.id
        cleanupBag.toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.toast?.id == bannerID else { return }
            self.toast = nil
        }
    }
}
