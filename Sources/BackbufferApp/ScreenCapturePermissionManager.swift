import AppKit
import BackbufferCore
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class ScreenCapturePermissionManager {
    let launchExecutableHash: String?

    init() {
        if let executableURL = Bundle.main.executableURL {
            self.launchExecutableHash = ScreenCaptureDiagnostics.computeExecutableSHA256(at: executableURL)
        } else {
            self.launchExecutableHash = nil
        }
    }

    func currentInstallIssue() -> AppInstallLocationIssue {
        ScreenCaptureDiagnostics.classifyInstallLocation(
            bundlePath: Bundle.main.bundleURL.path,
            applicationsBundleExists: FileManager.default.fileExists(
                atPath: ScreenCaptureDiagnostics.applicationsBundlePath
            ),
            homeDirectoryPath: NSHomeDirectory()
        )
    }

    func hasOnDiskBundleChangedSinceLaunch() -> Bool {
        guard let launchExecutableHash,
              let executableURL = Bundle.main.executableURL,
              let currentHash = ScreenCaptureDiagnostics.computeExecutableSHA256(at: executableURL) else {
            return false
        }
        return currentHash != launchExecutableHash
    }

    @discardableResult
    func runTCCReset() -> Bool {
        let result = runSynchronousProcess(
            executablePath: "/usr/bin/tccutil",
            arguments: ["reset", "ScreenCapture", ScreenCaptureDiagnostics.bundleIdentifier]
        )
        return result.status == 0
    }

    @discardableResult
    func runMicrophoneTCCReset() -> Bool {
        let result = runSynchronousProcess(
            executablePath: "/usr/bin/tccutil",
            arguments: ["reset", "Microphone", ScreenCaptureDiagnostics.bundleIdentifier]
        )
        return result.status == 0
    }

    func openSystemSettingsScreenCapture(triggerPrompt: Bool) {
        if triggerPrompt {
            _ = CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunchApplication(at targetBundleURL: URL? = nil) {
        let target = targetBundleURL ?? Bundle.main.bundleURL
        let pidString = String(ProcessInfo.processInfo.processIdentifier)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
            "--",
            pidString,
            target.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()

        NSApp?.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Darwin.exit(0)
        }
    }

    func installToApplicationsAndRelaunch(resetTCC: Bool = true) throws {
        let sourceBundleURL = Bundle.main.bundleURL
        guard sourceBundleURL.pathExtension == "app" else {
            throw NSError(
                domain: "io.malachiteore.backbuffer.install",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Backbuffer must be running from an application bundle to install to /Applications."
                ]
            )
        }

        let destinationURL = URL(fileURLWithPath: ScreenCaptureDiagnostics.applicationsBundlePath)
        let fileManager = FileManager.default

        if sourceBundleURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let otherInstances = NSRunningApplication.runningApplications(
                withBundleIdentifier: ScreenCaptureDiagnostics.bundleIdentifier
            ).filter { $0.processIdentifier != currentPID }

            for running in otherInstances {
                if !running.terminate() {
                    running.forceTerminate()
                }
            }
            if !otherInstances.isEmpty {
                let deadline = Date().addingTimeInterval(1.0)
                while otherInstances.contains(where: { !$0.isTerminated }), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                do {
                    try fileManager.removeItem(at: destinationURL)
                } catch {
                    throw NSError(
                        domain: "io.malachiteore.backbuffer.install",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: "Unable to replace existing \(destinationURL.path): \(error.localizedDescription)"
                        ]
                    )
                }
            }

            let dittoResult = runSynchronousProcess(
                executablePath: "/usr/bin/ditto",
                arguments: [sourceBundleURL.path, destinationURL.path]
            )
            if dittoResult.status != 0 {
                let detail = dittoResult.stderr.isEmpty ? "ditto exited with status \(dittoResult.status)." : dittoResult.stderr
                throw NSError(
                    domain: "io.malachiteore.backbuffer.install",
                    code: Int(dittoResult.status),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to copy Backbuffer to /Applications: \(detail)"]
                )
            }
        }

        let xattrResult = runSynchronousProcess(
            executablePath: "/usr/bin/xattr",
            arguments: ["-cr", destinationURL.path]
        )
        if xattrResult.status != 0 {
            let detail = xattrResult.stderr.isEmpty ? "xattr exited with status \(xattrResult.status)." : xattrResult.stderr
            throw NSError(
                domain: "io.malachiteore.backbuffer.install",
                code: Int(xattrResult.status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to clear Gatekeeper attributes: \(detail)"]
            )
        }

        if resetTCC {
            _ = runTCCReset()
            _ = runMicrophoneTCCReset()
        }

        relaunchApplication(at: destinationURL)
    }

    private func runSynchronousProcess(
        executablePath: String,
        arguments: [String]
    ) -> (status: Int32, stderr: String) {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            let errorData = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let stderrText = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (process.terminationStatus, stderrText)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
