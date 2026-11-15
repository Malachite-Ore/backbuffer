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
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        .defaultSize(width: 780, height: 720)
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
        case .permissionDenied, .error:
            return "exclamationmark.circle"
        case .idle:
            return "record.circle"
        }
    }
}
