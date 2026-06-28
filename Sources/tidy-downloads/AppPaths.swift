import Foundation

/// Filesystem locations the daemon uses.
///
/// Set the `TIDY_DOWNLOADS_HOME` environment variable to relocate the support
/// directory (config + ledger + daemon logs). This is mainly for testing so a
/// run can be isolated from the real `~/Library/Application Support` data.
enum AppPaths {
    static var supportDir: URL {
        if let override = ProcessInfo.processInfo.environment["TIDY_DOWNLOADS_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tidy-downloads", isDirectory: true)
    }

    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var ledgerFile: URL { supportDir.appendingPathComponent("log.jsonl") }
    static var stdoutLog: URL { supportDir.appendingPathComponent("daemon.out.log") }
    static var stderrLog: URL { supportDir.appendingPathComponent("daemon.err.log") }

    static var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    static var plistFile: URL {
        launchAgentsDir.appendingPathComponent("\(LaunchAgent.label).plist")
    }

    static func ensureSupportDir() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }
}
