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
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
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
    @Published var librarySearchText: String = ""

    let captureCoordinator: CaptureCoordinator
    let hotKeyManager: HotKeyManager
    let player: AVPlayer

    private let settingsStore: SettingsStore
    private var libraryStore: ClipLibraryStore?
    private let launchServicesEnabled: Bool
    private var coordinatorCancellable: AnyCancellable?
    private let cleanupBag: ViewModelCleanupBag
    private var hasBootstrapped = false

    init(
        settingsStore: SettingsStore = SettingsStore(),
        launchServices: Bool = true
    ) {
        self.settingsStore = settingsStore
        self.launchServicesEnabled = launchServices
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        self.estimate = SettingsStore.estimate(for: loadedSettings)
        self.captureCoordinator = CaptureCoordinator()
        self.hotKeyManager = HotKeyManager()
        let avPlayer = AVPlayer()
        self.player = avPlayer
        self.cleanupBag = ViewModelCleanupBag(player: avPlayer)

        if launchServices {
            self.libraryStore = try? ClipLibraryStore(settings: loadedSettings)
            self.coordinatorCancellable = captureCoordinator.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            setupPlayerObservers()
            hotKeyManager.setHandler { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.saveClipNow()
                }
            }
        }
    }

    // MARK: - Computed Properties

    var effectiveCaptureState: CaptureState {
        previewCaptureStateOverride ?? captureCoordinator.state
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

        do {
            try hotKeyManager.register(shortcut: settings.saveHotKey)
        } catch {
            showToast(.warning, "Hotkey \(settings.saveHotKey.displayString) conflict: \(error.localizedDescription)")
        }

        await reloadClips()
        await refreshTargetsAndAutoStart()
    }

    func refreshTargetsAndAutoStart() async {
        guard launchServicesEnabled else { return }

        do {
            let result = try await captureCoordinator.availableTargets()
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
            }
        } catch BackbufferError.screenRecordingPermissionDenied {
            // Permission screen is surfaced cleanly inside MenuBarPopoverView.
        } catch {
            showToast(.error, error.localizedDescription)
        }
    }

    func selectCaptureTarget(_ option: CaptureTargetOption) async {
        selectedTargetID = option.id
        guard launchServicesEnabled, let target = option.target else { return }
        do {
            try await captureCoordinator.startCapture(target: target, settings: settings)
            estimate = SettingsStore.estimate(for: settings, targetPixelSize: activePixelSizeHint)
            showToast(.info, "Capturing \(option.title)")
        } catch {
            showToast(.error, error.localizedDescription)
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
            showToast(.success, "Saved Master: \(savedURL.lastPathComponent)")
            await reloadClips(selectingMasterURL: savedURL)

            if settings.shareCap != .off,
               let savedRecord = clips.first(where: { $0.masterURL.standardizedFileURL == savedURL.standardizedFileURL }),
               case .overNewCap = savedRecord.shareStatus {
                scheduleBackgroundShareCompression(for: savedRecord)
            }
        } catch {
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

    func updateSaveHotKey(_ shortcut: HotKeyShortcut) {
        settings.saveHotKey = shortcut
        settingsStore.save(settings)
        guard launchServicesEnabled else { return }
        do {
            try hotKeyManager.register(shortcut: shortcut)
            showToast(.success, "Save hotkey updated to \(shortcut.displayString)")
        } catch {
            showToast(.error, error.localizedDescription)
        }
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
            try? hotKeyManager.register(shortcut: settings.saveHotKey)
        }
        libraryStore = try? ClipLibraryStore(settings: settings)
        Task { [weak self] in
            guard let self else { return }
            await self.reloadClips()
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
        toast: ToastBanner? = nil
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
        vm.toast = toast
        return vm
    }

    // MARK: - Private Helpers

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
