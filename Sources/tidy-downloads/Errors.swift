import Foundation

enum TidyError: Error, CustomStringConvertible {
    case cannotOpenDirectory(String)
    case folderNameConflict(String)
    case launchctlFailed(String)

    var description: String {
        switch self {
        case .cannotOpenDirectory(let p):
            return "cannot open directory for watching: \(p)"
        case .folderNameConflict(let p):
            return "a non-directory already exists where a version folder is needed: \(p)"
        case .launchctlFailed(let m):
            return "launchctl error: \(m)"
        }
    }
}

/// Write a line to stdout (captured to the daemon log under launchd).
func log(_ message: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data("tidy-downloads: \(message)\n".utf8))
}

/// Write a line to stderr.
func logError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("tidy-downloads: \(message)\n".utf8))
}
