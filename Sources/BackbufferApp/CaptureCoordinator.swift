import AppKit
import BackbufferCore
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
@preconcurrency import ScreenCaptureKit

// MARK: - Capture Target & State

enum CaptureTarget: Identifiable, Hashable, @unchecked Sendable {
    case display(SCDisplay)
    case window(SCWindow)

    var id: String {
        switch self {
        case .display(let display):
            return "display-\(display.displayID)"
        case .window(let window):
            return "window-\(window.windowID)"
        }
    }

    var isDisplay: Bool {
        if case .display = self { return true }
        return false
    }

    var systemImageName: String {
        switch self {
        case .display: return "display"
        case .window: return "macwindow"
        }
    }

    var title: String {
        switch self {
        case .display(let display):
            if display.displayID == CGMainDisplayID() {
                return "Main Display"
            }
            return "Display \(display.displayID)"
        case .window(let window):
            let appName = window.owningApplication?.applicationName ?? "App"
            let rawTitle = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if rawTitle.isEmpty || rawTitle == appName {
                return appName
            }
            return "\(appName) — \(rawTitle)"
        }
    }

    var subtitle: String {
        switch self {
        case .display(let display):
            return "\(display.width)×\(display.height) pts"
        case .window(let window):
            let w = Int(window.frame.width.rounded())
            let h = Int(window.frame.height.rounded())
            return "\(window.owningApplication?.applicationName ?? "Window") · \(w)×\(h)"
        }
    }

    var logicalSize: CGSize {
        switch self {
        case .display(let display):
            return CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        case .window(let window):
            return window.frame.size
        }
    }

    static func == (lhs: CaptureTarget, rhs: CaptureTarget) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum CaptureState: Equatable, Sendable {
    case idle
    case buffering(secondsBuffered: Double, estimatedRAMBytes: Int64)
    case paused
    case awaitingAllowedApps(allowedCount: Int)
    case permissionDenied
    case error(String)

    var isActivelyBuffering: Bool {
        if case .buffering = self { return true }
        return false
    }
}

// MARK: - Non-Isolated Stream Callback Relay

private final class StreamPipelineRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let ringBuffer: ReplayRingBuffer
    let encoder: VideoEncoder

    private let pauseLock = NSLock()
    private var _isPaused: Bool = false
    private weak var activeStream: SCStream?
    private let onStreamStopped: @Sendable (SCStream, Error?) -> Void

    init(
        ringBuffer: ReplayRingBuffer,
        encoder: VideoEncoder,
        onStreamStopped: @escaping @Sendable (SCStream, Error?) -> Void
    ) {
        self.ringBuffer = ringBuffer
        self.encoder = encoder
        self.onStreamStopped = onStreamStopped
        super.init()
    }

    func setActiveStream(_ stream: SCStream?) {
        pauseLock.lock()
        activeStream = stream
        pauseLock.unlock()
    }

    func setPaused(_ paused: Bool) {
        pauseLock.lock()
        _isPaused = paused
        pauseLock.unlock()
        encoder.setKeepalivePaused(paused)
    }

    private func shouldProcessSample(from sourceStream: SCStream) -> Bool {
        pauseLock.lock()
        let allowed = !_isPaused && (activeStream == nil || activeStream === sourceStream)
        pauseLock.unlock()
        return allowed
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard shouldProcessSample(from: stream) else { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        if type == .screen {
            handleVideoSample(sampleBuffer)
        } else if type == .audio {
            handleAudioSample(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamStopped(stream, error)
    }

    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [NSDictionary],
              let first = attachments.first,
              let rawStatus = first[SCStreamFrameInfo.status.rawValue] as? Int,
              let frameStatus = SCFrameStatus(rawValue: rawStatus),
              frameStatus == .complete else {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        try? encoder.ingestLivePixelBuffer(pixelBuffer, presentationTimeStamp: pts)
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard let extracted = AudioSampleExtractor.extractStereoInt16(from: sampleBuffer) else {
            return
        }
        ringBuffer.appendAudio(extracted.chunk)
    }
}

private final class CoordinatorTaskBag: @unchecked Sendable {
    var statsTask: Task<Void, Never>?
    var privacyRefreshTask: Task<Void, Never>?
    var launchObserver: AnyObject?
    var terminateObserver: AnyObject?
    weak var workspaceNotificationCenter: NotificationCenter?

    deinit {
        statsTask?.cancel()
        privacyRefreshTask?.cancel()
        if let center = workspaceNotificationCenter {
            if let launchObserver {
                center.removeObserver(launchObserver)
            }
            if let terminateObserver {
                center.removeObserver(terminateObserver)
            }
        }
    }
}

// MARK: - CaptureCoordinator

@MainActor
final class CaptureCoordinator: ObservableObject {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var availableDisplays: [SCDisplay] = []
    @Published private(set) var availableWindows: [SCWindow] = []
    @Published private(set) var activeTarget: CaptureTarget?
    @Published private(set) var activePixelDimensions: (width: Int, height: Int)?
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isSaving: Bool = false
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var activeCaptureSummary: String = ""
    @Published private(set) var installLocationIssue: AppInstallLocationIssue = .none
    @Published private(set) var bundleReplacedOnDisk: Bool = false
    @Published private(set) var didPerformStaleTCCAutoReset: Bool = false

    private static let audioLogger = Logger(subsystem: "io.malachiteore.backbuffer", category: "AudioCapture")

    let microphoneEngine = MicrophoneCaptureEngine()
    let permissionManager = ScreenCapturePermissionManager()
    private let audioRouteMonitor = SystemAudioRouteMonitor()

    private let videoQueue = DispatchQueue(label: "io.malachiteore.backbuffer.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "io.malachiteore.backbuffer.capture.audio", qos: .userInteractive)

    private var stream: SCStream?
    private var relay: StreamPipelineRelay?
    private let taskBag = CoordinatorTaskBag()
    private var currentSettings: CaptureSettings?
    private var lastRequestedTarget: CaptureTarget?
    private var isMicPreviewMonitoringActive: Bool = false
    private var isRefreshingAudioRoute: Bool = false
    private var pendingAudioRouteRefresh: OutputAudioRouteSnapshot?

    private enum PrivacyFilterResolution {
        case ready(filter: SCContentFilter, summary: String)
        case awaiting(allowedCount: Int, summary: String)
    }

    init() {
        refreshBundleDiagnostics()
    }

    func refreshBundleDiagnostics() {
        installLocationIssue = permissionManager.currentInstallIssue()
        bundleReplacedOnDisk = permissionManager.hasOnDiskBundleChangedSinceLaunch()
    }

    func attemptOneTimeStalePermissionRecovery(
        settingsStore: SettingsStore,
        hasExistingClips: Bool
    ) async -> Bool {
        refreshBundleDiagnostics()

        let currentHash = permissionManager.launchExecutableHash
        let decision = ScreenCaptureDiagnostics.evaluateStaleTCCAutoReset(
            installIssue: installLocationIssue,
            currentExecutableHash: currentHash,
            lastAuthorizedExecutableHash: settingsStore.lastAuthorizedExecutableHash(),
            lastAutoResetExecutableHash: settingsStore.lastAutoResetExecutableHash(),
            hasPriorUsageEvidence: hasExistingClips || settingsStore.hasPersistedSettings
        )

        guard decision == .autoResetOnce, let currentHash else {
            return false
        }

        // Persist the auto-reset marker before running tccutil so a repeated denial cannot loop.
        settingsStore.setLastAutoResetExecutableHash(currentHash)
        didPerformStaleTCCAutoReset = true
        _ = permissionManager.runTCCReset()
        _ = permissionManager.runMicrophoneTCCReset()
        _ = CGRequestScreenCaptureAccess()
        return true
    }

    func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        permissionManager.openSystemSettingsScreenCapture(triggerPrompt: true)
    }

    @discardableResult
    func availableTargets() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        refreshBundleDiagnostics()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()
            let filteredWindows = content.windows.filter { window in
                guard window.windowLayer == 0 else { return false }
                guard window.frame.width >= 200, window.frame.height >= 150 else { return false }
                guard let app = window.owningApplication else { return false }
                if app.processID == ownPID { return false }
                let lowerBundle = app.bundleIdentifier.lowercased()
                if let ownBundleID, lowerBundle == ownBundleID {
                    return false
                }
                if lowerBundle == "com.apple.dock"
                    || lowerBundle == "com.apple.windowmanager"
                    || lowerBundle == "com.apple.controlcenter"
                    || lowerBundle == "com.apple.windowserver"
                    || lowerBundle == "com.apple.wallpaper.agent" {
                    return false
                }
                return true
            }
            availableDisplays = content.displays
            availableWindows = filteredWindows
            if state == .permissionDenied {
                state = .idle
            }
            didPerformStaleTCCAutoReset = false
            return (content.displays, filteredWindows)
        } catch {
            if Self.isPermissionError(error) {
                state = .permissionDenied
                throw BackbufferError.screenRecordingPermissionDenied
            }
            throw BackbufferError.captureStartFailed(error.localizedDescription)
        }
    }

    func startCapture(target: CaptureTarget, settings: CaptureSettings) async throws {
        refreshBundleDiagnostics()
        ensureWorkspaceObserversInstalled()
        await tearDownActivePipeline(clearLastTarget: false, preserveAwaitingState: false)

        lastRequestedTarget = target
        currentSettings = settings

        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            availableDisplays = shareable.displays
        } catch {
            if Self.isPermissionError(error) {
                state = .permissionDenied
                activeCaptureSummary = ""
                throw BackbufferError.screenRecordingPermissionDenied
            }
            state = .error(error.localizedDescription)
            activeCaptureSummary = ""
            throw BackbufferError.captureStartFailed(error.localizedDescription)
        }

        let filter: SCContentFilter
        let summary: String
        switch resolvePrivacyFilter(for: target, settings: settings, shareable: shareable) {
        case .ready(let resolvedFilter, let resolvedSummary):
            filter = resolvedFilter
            summary = resolvedSummary
        case .awaiting(let allowedCount, let awaitingSummary):
            activeTarget = target
            activePixelDimensions = nil
            isPaused = false
            activeCaptureSummary = awaitingSummary
            state = .awaitingAllowedApps(allowedCount: allowedCount)
            if !microphoneEngine.isPreviewMeterOnly {
                microphoneEngine.stop()
            }
            throw BackbufferError.noAllowedAppsSelected
        }

        let scale = resolvePointPixelScale(for: target, filter: filter)
        let logical = target.logicalSize
        let dims = CaptureDimensionCalculator.computeTargetDimensions(
            logicalWidth: logical.width,
            logicalHeight: logical.height,
            pointPixelScale: scale,
            cap: settings.resolutionCap
        )

        let pixelSize = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        let bitrates = SettingsStore.bitratePair(
            for: settings.quality,
            resolutionCap: settings.resolutionCap,
            fps: settings.fps,
            targetPixelSize: pixelSize
        )

        let ringBuffer = ReplayRingBuffer(
            maxBufferSeconds: settings.bufferDuration.seconds,
            headroomSeconds: 2.0
        )

        let encoder = try VideoEncoder(
            width: dims.width,
            height: dims.height,
            codec: settings.codec,
            bitrateBps: bitrates.videoBps,
            fps: settings.fps.rawValue,
            maxKeyframeIntervalSeconds: 1.0,
            enableCFRKeepalive: true,
            onPacket: { packet in
                ringBuffer.appendVideo(packet)
            },
            onError: { [weak self] encoderError in
                Task { @MainActor [weak self] in
                    self?.state = .error(encoderError.localizedDescription)
                }
            }
        )

        let newRelay = StreamPipelineRelay(
            ringBuffer: ringBuffer,
            encoder: encoder,
            onStreamStopped: { [weak self] stoppedStream, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.handleUnexpectedStreamStop(stream: stoppedStream, error: error)
                }
            }
        )

        let config = Self.makeStreamConfiguration(dimensions: dims, fps: settings.fps)

        let newStream = SCStream(filter: filter, configuration: config, delegate: newRelay)
        newRelay.setActiveStream(newStream)

        do {
            try newStream.addStreamOutput(newRelay, type: .screen, sampleHandlerQueue: videoQueue)
            try newStream.addStreamOutput(newRelay, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()
        } catch {
            newRelay.setActiveStream(nil)
            encoder.invalidate()
            if Self.isPermissionError(error) {
                state = .permissionDenied
                activeCaptureSummary = ""
                throw BackbufferError.screenRecordingPermissionDenied
            }
            state = .error(error.localizedDescription)
            activeCaptureSummary = ""
            throw BackbufferError.captureStartFailed(error.localizedDescription)
        }

        self.stream = newStream
        self.relay = newRelay
        self.activeTarget = target
        self.activePixelDimensions = dims
        self.currentSettings = settings
        self.isPaused = false
        self.didPerformStaleTCCAutoReset = false
        self.activeCaptureSummary = summary
        self.state = .buffering(secondsBuffered: 0, estimatedRAMBytes: 0)

        startStatsPolling()
        audioRouteMonitor.start { [weak self] route in
            Task { @MainActor [weak self] in
                await self?.refreshStreamForAudioRouteChange(route)
            }
        }
        await applyMicrophoneSettings(settings)
    }

    func stopCapture() async {
        await tearDownActivePipeline(clearLastTarget: true, preserveAwaitingState: false)
    }

    func pauseBuffering() {
        guard let relay, !isPaused else { return }
        isPaused = true
        relay.setPaused(true)
        state = .paused
        syncMicrophonePreviewStateWhenInactive()
    }

    func resumeBuffering() {
        guard let relay, isPaused else { return }
        isPaused = false
        relay.setPaused(false)
        let stats = relay.ringBuffer.currentStats()
        state = .buffering(
            secondsBuffered: stats.bufferedSeconds,
            estimatedRAMBytes: Int64(stats.estimatedBytes)
        )
        if let settings = currentSettings {
            Task { @MainActor [weak self] in
                await self?.applyMicrophoneSettings(settings)
            }
        }
    }

    func updateBufferDurationIfActive(_ duration: BufferDurationOption) {
        relay?.ringBuffer.updateMaxBufferSeconds(duration.seconds)
        currentSettings?.bufferDuration = duration
    }

    func applyPrivacySettings(_ settings: CaptureSettings) async {
        ensureWorkspaceObserversInstalled()
        currentSettings = settings
        await refreshActivePrivacyFilter()
    }

    func setMicrophonePreviewMonitoring(_ active: Bool, settings: CaptureSettings) async {
        isMicPreviewMonitoringActive = active
        await applyMicrophoneSettings(settings)
    }

    func applyMicrophoneSettings(_ settings: CaptureSettings) async {
        currentSettings = settings

        guard settings.recordMicrophone else {
            microphoneEngine.stop()
            return
        }

        let hasActiveBuffer = (!isPaused && relay != nil)
        guard hasActiveBuffer || isMicPreviewMonitoringActive else {
            microphoneEngine.stop()
            return
        }

        let wantPreviewOnly = !hasActiveBuffer
        let targetRingBuffer: ReplayRingBuffer? = hasActiveBuffer ? relay?.ringBuffer : nil

        let normalizedDeviceID: String? = (
            settings.selectedMicrophoneID == nil
            || settings.selectedMicrophoneID == MicrophoneDeviceOption.systemDefaultID
            || settings.selectedMicrophoneID?.isEmpty == true
        ) ? nil : settings.selectedMicrophoneID

        if microphoneEngine.isRunning,
           microphoneEngine.activeDeviceID == normalizedDeviceID {
            microphoneEngine.updateOutputTarget(
                ringBuffer: targetRingBuffer,
                enablePreviewMeterOnly: wantPreviewOnly,
                isMuted: settings.isMicrophoneMuted
            )
            return
        }

        do {
            try await microphoneEngine.start(
                deviceID: normalizedDeviceID,
                isMuted: settings.isMicrophoneMuted,
                ringBuffer: targetRingBuffer,
                enablePreviewMeterOnly: wantPreviewOnly
            )
        } catch {
            // Preserve microphoneEngine.lastErrorMessage for Settings & Menu Bar recovery banners.
        }
    }

    func saveCurrentBuffer(
        libraryStore: ClipLibraryStore,
        activeCap: ShareCapOption,
        audioBitrateBps: Int = 160_000
    ) async throws -> URL {
        _ = activeCap
        guard let relay else {
            throw BackbufferError.emptyBuffer
        }

        isSaving = true
        defer { isSaving = false }

        let snapshot = relay.ringBuffer.snapshotWithMic(includeOverlappingAudio: true)
        let sortedVideo = snapshot.video
            .filter { $0.pts.isNumeric }
            .sorted { CMTimeCompare($0.pts, $1.pts) < 0 }

        guard let firstKeyframeIdx = sortedVideo.firstIndex(where: { $0.isKeyframe }),
              let lastVideo = sortedVideo.last else {
            throw BackbufferError.emptyBuffer
        }

        let originPTS = sortedVideo[firstKeyframeIdx].pts
        let endPTS: CMTime
        if lastVideo.duration.isNumeric && CMTimeCompare(lastVideo.duration, .zero) > 0 {
            endPTS = CMTimeAdd(lastVideo.pts, lastVideo.duration)
        } else {
            endPTS = lastVideo.pts
        }

        let activeSettings = currentSettings ?? .default
        let audioTracks = try AudioPCMTrackMixer.buildAudioTracks(
            systemChunks: snapshot.systemAudio,
            micChunks: snapshot.micAudio,
            originPTS: originPTS,
            endPTS: endPTS,
            micGain: activeSettings.clampedMicrophoneGain(),
            aacBitrateBps: audioBitrateBps,
            includeSeparateStems: activeSettings.separateAudioTracksInMaster
        )

        try libraryStore.ensureDirectoriesExist()
        let outputURL = libraryStore.nextMasterURL(for: Date())

        try await ClipMuxer.writeMP4(
            videoPackets: snapshot.video,
            audioTracks: audioTracks,
            to: outputURL
        )

        lastSavedURL = outputURL
        return outputURL
    }

    // MARK: - Helpers

    private func tearDownActivePipeline(clearLastTarget: Bool, preserveAwaitingState: Bool) async {
        audioRouteMonitor.stop()
        pendingAudioRouteRefresh = nil
        taskBag.statsTask?.cancel()
        taskBag.statsTask = nil
        if clearLastTarget {
            taskBag.privacyRefreshTask?.cancel()
            taskBag.privacyRefreshTask = nil
            lastRequestedTarget = nil
        }

        let oldStream = stream
        let oldRelay = relay
        stream = nil
        relay = nil
        oldRelay?.setActiveStream(nil)
        activePixelDimensions = nil
        isPaused = false

        syncMicrophonePreviewStateWhenInactive()

        if let oldStream {
            try? await oldStream.stopCapture()
        }
        oldRelay?.encoder.invalidate()
        oldRelay?.ringBuffer.clear()

        if clearLastTarget {
            activeTarget = nil
            activeCaptureSummary = ""
        }

        if !preserveAwaitingState && state != .permissionDenied {
            state = .idle
        }
    }

    private func ensureWorkspaceObserversInstalled() {
        guard taskBag.launchObserver == nil, taskBag.terminateObserver == nil else { return }

        let center = NSWorkspace.shared.notificationCenter
        taskBag.workspaceNotificationCenter = center

        taskBag.launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePrivacyRefresh(followUpRetry: true)
            }
        } as AnyObject?

        taskBag.terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePrivacyRefresh(followUpRetry: false)
            }
        } as AnyObject?
    }

    private func schedulePrivacyRefresh(followUpRetry: Bool) {
        guard currentSettings != nil else { return }
        guard stream != nil || isAwaitingAllowedApps else { return }

        taskBag.privacyRefreshTask?.cancel()
        taskBag.privacyRefreshTask = Task { [weak self] in
            // Allow newly launched apps time to register their PID/windows with ScreenCaptureKit.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.refreshActivePrivacyFilter()

            if followUpRetry, !Task.isCancelled, self.isAwaitingAllowedApps {
                try? await Task.sleep(nanoseconds: 650_000_000)
                guard !Task.isCancelled else { return }
                await self.refreshActivePrivacyFilter()
            }
        }
    }

    private var isAwaitingAllowedApps: Bool {
        if case .awaitingAllowedApps = state { return true }
        return false
    }

    private func refreshActivePrivacyFilter() async {
        guard let settings = currentSettings else { return }
        guard let target = activeTarget ?? lastRequestedTarget else { return }
        guard stream != nil || isAwaitingAllowedApps else { return }

        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            availableDisplays = shareable.displays
        } catch {
            if Self.isPermissionError(error) {
                state = .permissionDenied
                activeCaptureSummary = ""
            }
            return
        }

        switch resolvePrivacyFilter(for: target, settings: settings, shareable: shareable) {
        case .ready(let filter, let summary):
            activeCaptureSummary = summary
            if let activeStream = stream {
                do {
                    try await activeStream.updateContentFilter(filter)
                } catch {
                    if let refreshedTarget = resolveLiveTarget(target, in: shareable) {
                        try? await startCapture(target: refreshedTarget, settings: settings)
                    }
                }
            } else if isAwaitingAllowedApps, let refreshedTarget = resolveLiveTarget(target, in: shareable) {
                try? await startCapture(target: refreshedTarget, settings: settings)
            }

        case .awaiting(let allowedCount, let summary):
            activeCaptureSummary = summary
            if stream != nil {
                await tearDownActivePipeline(clearLastTarget: false, preserveAwaitingState: true)
            }
            state = .awaitingAllowedApps(allowedCount: allowedCount)
        }
    }

    private func resolveLiveTarget(_ target: CaptureTarget, in shareable: SCShareableContent) -> CaptureTarget? {
        switch target {
        case .display(let display):
            if let matched = shareable.displays.first(where: { $0.displayID == display.displayID }) ?? shareable.displays.first {
                return .display(matched)
            }
            return target
        case .window(let window):
            if let matched = shareable.windows.first(where: { $0.windowID == window.windowID }) {
                return .window(matched)
            }
            return nil
        }
    }

    private func resolvePrivacyFilter(
        for target: CaptureTarget,
        settings: CaptureSettings,
        shareable: SCShareableContent
    ) -> PrivacyFilterResolution {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()

        let selfWindows = shareable.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            if app.processID == ownPID { return true }
            if let ownBundleID, app.bundleIdentifier.lowercased() == ownBundleID {
                return true
            }
            return false
        }

        let externalApps = shareable.applications.filter { app in
            if app.processID == ownPID { return false }
            if let ownBundleID, app.bundleIdentifier.lowercased() == ownBundleID {
                return false
            }
            return true
        }

        switch target {
        case .window(let window):
            let liveWindow = shareable.windows.first(where: { $0.windowID == window.windowID }) ?? window
            let ownerApp = liveWindow.owningApplication
            let runningOwner = ownerApp.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
            guard settings.isApplicationAllowed(
                bundleIdentifier: ownerApp?.bundleIdentifier,
                applicationName: runningOwner?.localizedName ?? ownerApp?.applicationName,
                executableName: runningOwner?.executableURL?.lastPathComponent,
                executablePath: runningOwner?.executableURL?.path
            ) else {
                let allowedCount = settings.allowedAppBundleIDs.count
                let summary: String
                if settings.privacyMode == .strictAllowlist {
                    summary = allowedCount == 0
                        ? "Privacy Lock · Select an allowed app to begin capture"
                        : "Privacy Lock · Window app not in allowlist"
                } else {
                    summary = "Privacy Lock · Target window app is blocked"
                }
                return .awaiting(allowedCount: allowedCount, summary: summary)
            }

            let filter = SCContentFilter(desktopIndependentWindow: liveWindow)
            let appName = liveWindow.owningApplication?.applicationName ?? "Allowed Window"
            let summary = settings.privacyMode == .strictAllowlist
                ? "Privacy Lock · Capturing \(appName)"
                : "Capturing \(appName)"
            return .ready(filter: filter, summary: summary)

        case .display(let display):
            let liveDisplay = shareable.displays.first(where: { $0.displayID == display.displayID }) ?? display

            switch settings.privacyMode {
            case .strictAllowlist:
                let includedApps = externalApps.filter {
                    Self.isSCRunningAppAllowed($0, settings: settings)
                }
                guard !includedApps.isEmpty else {
                    let allowedCount = settings.allowedAppBundleIDs.count
                    let summary = allowedCount == 0
                        ? "Privacy Lock · No allowed apps selected"
                        : "Privacy Lock · Waiting for \(allowedCount == 1 ? "allowed app" : "\(allowedCount) allowed apps") to open"
                    return .awaiting(allowedCount: allowedCount, summary: summary)
                }

                let filter = SCContentFilter(
                    display: liveDisplay,
                    including: includedApps,
                    exceptingWindows: selfWindows
                )
                let summary: String
                if includedApps.count == 1 {
                    summary = "Privacy Lock · Capturing \(includedApps[0].applicationName)"
                } else {
                    summary = "Privacy Lock · Capturing \(includedApps.count) allowed apps"
                }
                return .ready(filter: filter, summary: summary)

            case .allowAllExceptBlocked:
                let excludedApps = externalApps.filter {
                    !Self.isSCRunningAppAllowed($0, settings: settings)
                }
                let filter = SCContentFilter(
                    display: liveDisplay,
                    excludingApplications: excludedApps,
                    exceptingWindows: selfWindows
                )
                let summary: String
                if excludedApps.isEmpty {
                    summary = "Capturing \(target.title)"
                } else {
                    summary = "Capturing \(target.title) · \(excludedApps.count) hidden"
                }
                return .ready(filter: filter, summary: summary)
            }
        }
    }

    private func startStatsPolling() {
        taskBag.statsTask?.cancel()
        taskBag.statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { break }
                guard let relay = self.relay else { continue }
                if !self.isPaused {
                    let stats = relay.ringBuffer.currentStats()
                    self.state = .buffering(
                        secondsBuffered: stats.bufferedSeconds,
                        estimatedRAMBytes: Int64(stats.estimatedBytes)
                    )
                }
            }
        }
    }

    private func handleUnexpectedStreamStop(stream stoppedStream: SCStream, error: Error?) async {
        guard self.stream === stoppedStream else { return }

        audioRouteMonitor.stop()
        pendingAudioRouteRefresh = nil
        taskBag.statsTask?.cancel()
        taskBag.statsTask = nil
        let oldRelay = relay
        stream = nil
        relay = nil
        oldRelay?.setActiveStream(nil)
        isPaused = false
        syncMicrophonePreviewStateWhenInactive()
        oldRelay?.encoder.invalidate()
        oldRelay?.ringBuffer.clear()

        if let error {
            if Self.isPermissionError(error) {
                state = .permissionDenied
                activeCaptureSummary = ""
            } else {
                state = .error("Capture target closed or interrupted: \(error.localizedDescription)")
            }
        } else {
            state = .idle
            activeCaptureSummary = ""
        }
    }

    private func refreshStreamForAudioRouteChange(_ route: OutputAudioRouteSnapshot) async {
        guard !isPaused,
              state.isActivelyBuffering,
              let oldStream = stream,
              let existingRelay = relay,
              let target = activeTarget ?? lastRequestedTarget,
              let settings = currentSettings,
              !isSaving else {
            return
        }

        if isRefreshingAudioRoute {
            pendingAudioRouteRefresh = route
            return
        }

        isRefreshingAudioRoute = true
        defer {
            isRefreshingAudioRoute = false
            if let queuedRoute = pendingAudioRouteRefresh {
                pendingAudioRouteRefresh = nil
                Task { @MainActor [weak self] in
                    await self?.refreshStreamForAudioRouteChange(queuedRoute)
                }
            }
        }

        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            availableDisplays = shareable.displays
        } catch {
            return
        }

        guard self.stream === oldStream,
              self.relay === existingRelay,
              !isPaused,
              state.isActivelyBuffering,
              !isSaving else {
            return
        }

        let liveTarget = resolveLiveTarget(target, in: shareable) ?? target
        let filter: SCContentFilter
        let summary: String
        switch resolvePrivacyFilter(for: liveTarget, settings: settings, shareable: shareable) {
        case .ready(let resolvedFilter, let resolvedSummary):
            filter = resolvedFilter
            summary = resolvedSummary
        case .awaiting(let allowedCount, let awaitingSummary):
            activeCaptureSummary = awaitingSummary
            await tearDownActivePipeline(clearLastTarget: false, preserveAwaitingState: true)
            state = .awaitingAllowedApps(allowedCount: allowedCount)
            return
        }

        let dims: (width: Int, height: Int)
        if let activePixelDimensions {
            dims = activePixelDimensions
        } else {
            let scale = resolvePointPixelScale(for: liveTarget, filter: filter)
            let logical = liveTarget.logicalSize
            dims = CaptureDimensionCalculator.computeTargetDimensions(
                logicalWidth: logical.width,
                logicalHeight: logical.height,
                pointPixelScale: scale,
                cap: settings.resolutionCap
            )
        }

        let config = Self.makeStreamConfiguration(dimensions: dims, fps: settings.fps)
        let newStream = SCStream(filter: filter, configuration: config, delegate: existingRelay)
        existingRelay.setActiveStream(newStream)

        do {
            try newStream.addStreamOutput(existingRelay, type: .screen, sampleHandlerQueue: videoQueue)
            try newStream.addStreamOutput(existingRelay, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()
        } catch {
            existingRelay.setActiveStream(oldStream)
            return
        }

        // Guard against capture being stopped, paused, or replaced while awaiting newStream.startCapture().
        guard self.stream === oldStream,
              self.relay === existingRelay,
              !isPaused,
              state.isActivelyBuffering else {
            existingRelay.setActiveStream(self.stream)
            try? await newStream.stopCapture()
            return
        }

        self.stream = newStream
        self.activeTarget = liveTarget
        self.activeCaptureSummary = summary
        try? await oldStream.stopCapture()

        Self.audioLogger.info(
            "Refreshed SCStream for audio route change: deviceID=\(route.deviceID, privacy: .public) sampleRate=\(route.nominalSampleRate, privacy: .public) bufferFrameSize=\(route.bufferFrameSize, privacy: .public)"
        )
    }

    private static func makeStreamConfiguration(
        dimensions: (width: Int, height: Int),
        fps: CaptureFPS
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = dimensions.width
        config.height = dimensions.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps.rawValue))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        return config
    }

    private func resolvePointPixelScale(for target: CaptureTarget, filter: SCContentFilter) -> CGFloat {
        if #available(macOS 14.0, *) {
            let scale = CGFloat(filter.pointPixelScale)
            if scale > 0 {
                return scale
            }
        }

        switch target {
        case .display(let display):
            if let screen = Self.screen(forDisplayID: display.displayID) {
                return screen.backingScaleFactor
            }
        case .window(let window):
            if let bestDisplay = availableDisplays.max(by: { lhs, rhs in
                let areaL = Self.intersectionArea(lhs.frame, window.frame)
                let areaR = Self.intersectionArea(rhs.frame, window.frame)
                return areaL < areaR
            }), Self.intersectionArea(bestDisplay.frame, window.frame) > 0,
               let screen = Self.screen(forDisplayID: bestDisplay.displayID) {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        return inter.width * inter.height
    }

    private func syncMicrophonePreviewStateWhenInactive() {
        if isMicPreviewMonitoringActive && (currentSettings?.recordMicrophone == true) {
            microphoneEngine.updateOutputTarget(
                ringBuffer: nil,
                enablePreviewMeterOnly: true,
                isMuted: currentSettings?.isMicrophoneMuted ?? false
            )
        } else {
            microphoneEngine.stop()
        }
    }

    private static func isSCRunningAppAllowed(
        _ app: SCRunningApplication,
        settings: CaptureSettings
    ) -> Bool {
        let runningApp = NSRunningApplication(processIdentifier: app.processID)
        return settings.isApplicationAllowed(
            bundleIdentifier: app.bundleIdentifier,
            applicationName: runningApp?.localizedName ?? app.applicationName,
            executableName: runningApp?.executableURL?.lastPathComponent,
            executablePath: runningApp?.executableURL?.path
        )
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        if let scError = error as? SCStreamError, scError.code == .userDeclined {
            return true
        }
        let nsError = error as NSError
        return ScreenCaptureDiagnostics.isScreenCapturePermissionError(
            domain: nsError.domain,
            code: nsError.code,
            localizedDescription: error.localizedDescription
        )
    }
}
