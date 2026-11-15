import AppKit
import BackbufferCore
import SwiftUI

private struct MainThreadEventBox: @unchecked Sendable {
    let event: NSEvent
}

private func runRecorderSyncOnMainActor<T: Sendable>(_ operation: @MainActor () -> T) -> T {
    if #available(macOS 14.0, *) {
        return MainActor.assumeIsolated(operation)
    } else {
        precondition(Thread.isMainThread)
        typealias YesActor = @MainActor () -> T
        typealias NoActor = () -> T
        return withoutActuallyEscaping(operation) { (_ fn: @escaping YesActor) -> T in
            let rawFn = unsafeBitCast(fn, to: NoActor.self)
            return rawFn()
        }
    }
}

private final class HotKeyRecorderResourceBox: @unchecked Sendable {
    var localMonitor: AnyObject?
    var windowObserver: AnyObject?
    var isRecording: Bool = false

    deinit {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if isRecording {
            Task { @MainActor in
                HotKeyManager.shared.setRecordingPaused(false)
            }
        }
    }
}

@MainActor
final class HotKeyRecordSession: ObservableObject {
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var validationMessage: String?

    private let resources = HotKeyRecorderResourceBox()
    private var allowClear: Bool = true
    private var onRecordingChanged: ((Bool) -> Void)?
    private var onApply: ((HotKeyShortcut?) -> Void)?

    var localMonitor: AnyObject? {
        resources.localMonitor
    }

    var windowObserver: AnyObject? {
        resources.windowObserver
    }

    func toggleRecording(
        allowClear: Bool,
        onRecordingChanged: ((Bool) -> Void)?,
        onApply: @escaping (HotKeyShortcut?) -> Void
    ) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(
                allowClear: allowClear,
                onRecordingChanged: onRecordingChanged,
                onApply: onApply
            )
        }
    }

    func startRecording(
        allowClear: Bool,
        onRecordingChanged: ((Bool) -> Void)?,
        onApply: @escaping (HotKeyShortcut?) -> Void
    ) {
        stopRecording(notify: false)

        self.allowClear = allowClear
        self.onRecordingChanged = onRecordingChanged
        self.onApply = onApply
        self.validationMessage = nil
        self.isRecording = true
        resources.isRecording = true

        HotKeyManager.shared.setRecordingPaused(true)
        onRecordingChanged?(true)

        resources.windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopRecording()
            }
        } as AnyObject?

        resources.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Thread.isMainThread else { return event }
            let eventBox = MainThreadEventBox(event: event)
            let shouldConsume = runRecorderSyncOnMainActor {
                guard let self, self.isRecording else { return false }
                return self.handleKeyDown(eventBox.event)
            }
            return shouldConsume ? nil : event
        } as AnyObject?
    }

    func stopRecording(notify: Bool = true) {
        if let monitor = resources.localMonitor {
            NSEvent.removeMonitor(monitor)
            resources.localMonitor = nil
        }
        if let observer = resources.windowObserver {
            NotificationCenter.default.removeObserver(observer)
            resources.windowObserver = nil
        }

        let wasRecording = isRecording
        isRecording = false
        resources.isRecording = false
        validationMessage = nil

        if wasRecording {
            HotKeyManager.shared.setRecordingPaused(false)
            if notify {
                onRecordingChanged?(false)
            }
        }
        if notify {
            onRecordingChanged = nil
            onApply = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }
        if event.isARepeat {
            return true
        }

        let keyCode = UInt32(event.keyCode)
        let relevantFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let carbonMods = HotKeyShortcut.carbonModifiers(from: relevantFlags)

        // Escape cancels recording without changing the current shortcut.
        if keyCode == 53 {
            stopRecording()
            return true
        }

        // Delete clears optional shortcuts when pressed without modifiers.
        if keyCode == 51 && carbonMods == 0 && allowClear {
            let apply = onApply
            stopRecording()
            apply?(nil)
            return true
        }

        if let message = HotKeyShortcut.validationMessage(keyCode: keyCode, carbonModifiers: carbonMods) {
            validationMessage = message
            NSSound.beep()
            return true
        }

        guard let shortcut = HotKeyShortcut(event: event) else {
            validationMessage = "Unsupported key combination."
            NSSound.beep()
            return true
        }

        let apply = onApply
        stopRecording()
        apply?(shortcut)
        return true
    }
}

struct HotKeyRecorderControl: View {
    private let title: String
    private let shortcut: HotKeyShortcut?
    private let allowClear: Bool
    private let compact: Bool
    private let onRecordingChanged: ((Bool) -> Void)?
    private let onChange: (HotKeyShortcut?) -> Void

    @StateObject private var session = HotKeyRecordSession()

    private static let recorderSurface = Color(red: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x26 / 255.0)
    private static let recorderBorder = Color(red: 0x38 / 255.0, green: 0x38 / 255.0, blue: 0x3C / 255.0)
    private static let recorderActiveAmber = Color(red: 0xF5 / 255.0, green: 0x9E / 255.0, blue: 0x0B / 255.0)

    init(
        title: String,
        shortcut: HotKeyShortcut?,
        allowClear: Bool = true,
        compact: Bool = false,
        onRecordingChanged: ((Bool) -> Void)? = nil,
        onChange: @escaping (HotKeyShortcut?) -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.allowClear = allowClear
        self.compact = compact
        self.onRecordingChanged = onRecordingChanged
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: compact ? 5 : 6) {
                Button {
                    session.toggleRecording(
                        allowClear: allowClear,
                        onRecordingChanged: onRecordingChanged,
                        onApply: onChange
                    )
                } label: {
                    recorderPillContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))

                if allowClear && shortcut != nil && !session.isRecording {
                    Button {
                        onChange(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: compact ? 9 : 10, weight: .bold))
                            .foregroundColor(Theme.textSecondary)
                            .frame(width: compact ? 20 : 24, height: compact ? 24 : 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Self.recorderSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Self.recorderBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Clear \(title)")
                    .accessibilityLabel(Text("Clear \(title)"))
                }
            }

            if let message = session.validationMessage {
                Text(verbatim: message)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Theme.crimson)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .onDisappear {
            if session.isRecording {
                session.stopRecording()
            }
        }
    }

    @ViewBuilder
    private var recorderPillContent: some View {
        HStack(spacing: compact ? 4 : 5) {
            if session.isRecording {
                Circle()
                    .fill(Self.recorderActiveAmber)
                    .frame(width: 6, height: 6)

                Text("Press Keys…")
                    .font(Theme.mono(compact ? 11 : 12, weight: .semibold))
                    .foregroundColor(Self.recorderActiveAmber)

                if !compact {
                    Text("Esc")
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.black.opacity(0.28))
                        )
                }
            } else if let shortcut {
                keycapsView(for: shortcut)
            } else {
                Text(compact ? "Not Set" : "Click to Record")
                    .font(Theme.mono(compact ? 11 : 12, weight: .medium))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: compact ? 24 : 28)
        .frame(minWidth: compact ? 86 : 124)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Self.recorderSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    session.isRecording ? Self.recorderActiveAmber : Self.recorderBorder,
                    lineWidth: session.isRecording ? 2 : 1
                )
        )
    }

    @ViewBuilder
    private func keycapsView(for shortcut: HotKeyShortcut) -> some View {
        let tokens = keycapTokens(for: shortcut)
        HStack(spacing: compact ? 3 : 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(verbatim: token)
                    .font(Theme.mono(compact ? 11 : 12, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, compact ? 4.5 : 6)
                    .padding(.vertical, compact ? 1.5 : 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Self.recorderBorder, lineWidth: 0.75)
                    )
            }
        }
    }

    private func keycapTokens(for shortcut: HotKeyShortcut) -> [String] {
        var tokens: [String] = []
        if (shortcut.carbonModifiers & HotKeyShortcut.carbonControlKey) != 0 { tokens.append("⌃") }
        if (shortcut.carbonModifiers & HotKeyShortcut.carbonOptionKey) != 0 { tokens.append("⌥") }
        if (shortcut.carbonModifiers & HotKeyShortcut.carbonShiftKey) != 0 { tokens.append("⇧") }
        if (shortcut.carbonModifiers & HotKeyShortcut.carbonCmdKey) != 0 { tokens.append("⌘") }
        tokens.append(HotKeyShortcut.keyName(for: shortcut.keyCode))
        return tokens
    }
}
