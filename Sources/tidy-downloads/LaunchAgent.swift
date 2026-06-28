import Foundation
import Darwin

private func trim(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Installs/removes the per-user LaunchAgent so the daemon runs at login and
/// restarts if it dies.
enum LaunchAgent {
    static let label = "jp.m-ohashi.tidy-downloads"

    static func install() throws {
        AppPaths.ensureSupportDir()
        try FileManager.default.createDirectory(
            at: AppPaths.launchAgentsDir, withIntermediateDirectories: true)

        let binary = executablePath()
        let plist = plistContent(binary: binary)
        try Data(plist.utf8).write(to: AppPaths.plistFile)

        let uid = getuid()
        // Reload cleanly if a previous instance is registered (ok if it wasn't).
        _ = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        let boot = shell("/bin/launchctl", ["bootstrap", "gui/\(uid)", AppPaths.plistFile.path])
        if boot.code != 0 {
            let load = shell("/bin/launchctl", ["load", "-w", AppPaths.plistFile.path])
            if load.code != 0 {
                throw TidyError.launchctlFailed(
                    "bootstrap failed (\(boot.code)): \(trim(boot.out)); "
                    + "load fallback failed (\(load.code)): \(trim(load.out))")
            }
        }
        _ = shell("/bin/launchctl", ["enable", "gui/\(uid)/\(label)"])
        guard isRunning() else {
            throw TidyError.launchctlFailed("the agent did not start; see \(AppPaths.stderrLog.path)")
        }

        print("Installed and running: \(label)")
        print("Binary:     \(binary)")
        print("Watching:   \(Config.loadOrCreate().watchedDirectory)")
        print("Daemon log: \(AppPaths.stdoutLog.path)")
    }

    static func uninstall() throws {
        let uid = getuid()
        let boot = shell("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        try? FileManager.default.removeItem(at: AppPaths.plistFile)
        // bootout returns nonzero when it wasn't loaded — only a real error if it's still running.
        if boot.code != 0 && isRunning() {
            throw TidyError.launchctlFailed("bootout failed (\(boot.code)): \(trim(boot.out))")
        }
        print("Removed: \(label)")
    }

    static func isRunning() -> Bool {
        let uid = getuid()
        return shell("/bin/launchctl", ["print", "gui/\(uid)/\(label)"]).code == 0
    }

    /// The true path of the currently-running executable.
    private static func executablePath() -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        _ = _NSGetExecutablePath(&buf, &size)
        let path = String(cString: buf)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func plistContent(binary: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(AppPaths.stdoutLog.path)</string>
            <key>StandardErrorPath</key><string>\(AppPaths.stderrLog.path)</string>
        </dict>
        </plist>
        """
    }
}

/// Run a subprocess, capturing combined stdout+stderr.
@discardableResult
func shell(_ launchPath: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
