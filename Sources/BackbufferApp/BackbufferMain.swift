import AppKit
import BackbufferCore
import Foundation
import SwiftUI

@main
struct BackbufferMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let previewFlagIndex = args.firstIndex(of: "--render-previews") {
            let outputPath: String
            if previewFlagIndex + 1 < args.count {
                outputPath = args[previewFlagIndex + 1]
            } else {
                outputPath = "ci-output/previews"
            }

            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            do {
                try PreviewRenderer.renderAll(to: outputURL)
                Foundation.exit(0)
            } catch {
                fputs("Backbuffer preview render error: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        BackbufferGUIApp.main()
    }
}

@MainActor
final class BackbufferAppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = AppViewModel(launchServices: true)

    override init() {
        super.init()
    }

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            await self.viewModel.bootstrapIfNeeded()
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct BackbufferGUIApp: App {
    @NSApplicationDelegateAdaptor(BackbufferAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Backbuffer", id: "library") {
            LibraryTrimmerWindowView(viewModel: appDelegate.viewModel, initialMode: .hub)
        }
        .defaultSize(width: 1160, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CaptureMenuCommands(viewModel: appDelegate.viewModel)
        }

        MenuBarExtra {
            MenuBarPopoverView(viewModel: appDelegate.viewModel)
        } label: {
            MenuBarStatusLabel(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)

        Window("Backbuffer Settings", id: "settings") {
            SettingsWindowView(viewModel: appDelegate.viewModel)
        }
        .defaultSize(width: 780, height: 640)
    }
}

private struct CaptureMenuCommands: Commands {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Keep Capture menu items free of hardcoded .keyboardShortcut overrides so
        // HotKeyManager's user-configured shortcuts never collide with NSMenu shortcuts.
        CommandMenu("Capture") {
            Button("Save Replay Clip") {
                Task {
                    await viewModel.saveClipNow()
                }
            }
            .disabled(!viewModel.effectiveCaptureState.isActivelyBuffering || viewModel.captureCoordinator.isSaving)

            Button(viewModel.captureCoordinator.isPaused ? "Resume Buffering" : "Pause Buffering") {
                Task {
                    await viewModel.toggleRecordingPause()
                }
            }

            Divider()

            Button("Refresh Capture Targets") {
                Task {
                    await viewModel.refreshTargetsAndAutoStart()
                }
            }

            Divider()

            Button("Allowed Apps...") {
                viewModel.openSettings(tab: .privacy)
                openWindow(id: "settings")
            }

            Button("Shortcuts & Microphone...") {
                viewModel.openSettings(tab: .shortcutsAndMic)
                openWindow(id: "settings")
            }

            Button("Video & Storage Settings...") {
                viewModel.openSettings(tab: .videoAndStorage)
                openWindow(id: "settings")
            }
        }
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Label {
            Text("Backbuffer")
        } icon: {
            Image(systemName: systemImageName)
        }
    }

    private var systemImageName: String {
        switch viewModel.effectiveCaptureState {
        case .buffering:
            return "record.circle.fill"
        case .paused:
            return "pause.circle"
        case .awaitingAllowedApps:
            return "lock.shield"
        case .permissionDenied, .error:
            return "exclamationmark.circle"
        case .idle:
            return "record.circle"
        }
    }
}
