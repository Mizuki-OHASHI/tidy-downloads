import Foundation

/// One recorded operation. Serialized as a single JSON object per line (JSONL).
struct LedgerEvent: Codable {
    let ts: String
    let action: String      // "archive" | "promote" | "dedup-trash"
    let from: String?
    let to: String?
    let hash: String?
    let trashPath: String?
}

/// Append-only operation log. Every rename/move/trash is recorded so the
/// history is auditable (and undoable later) — the files themselves are the
/// versions; this is purely the record of what moved where.
///
/// The file is created lazily on the first `record`, so dry-runs never touch it.
final class Ledger {
    private let url: URL
    private let queue = DispatchQueue(label: "jp.m-ohashi.tidy-downloads.ledger")
    private let iso = ISO8601DateFormatter()

    init(url: URL) {
        self.url = url
    }

    func record(action: String,
                from: URL? = nil,
                to: URL? = nil,
                hash: String? = nil,
                trashPath: URL? = nil) {
        let event = LedgerEvent(
            ts: iso.string(from: Date()),
            action: action,
            from: from?.path,
            to: to?.path,
            hash: hash,
            trashPath: trashPath?.path
        )
        queue.sync {
            do {
                AppPaths.ensureSupportDir()
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                var data = try JSONEncoder().encode(event)
                data.append(0x0A) // newline
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try? FileHandle.standardOutput.write(contentsOf: data) // echo to daemon log
            } catch {
                // Fail loudly: don't abort the (already-completed) file op, but make the loss visible.
                logError("ledger write failed for \(event.action): \(error)")
            }
        }
    }

    static func printTail(lines: Int) {
        guard let content = try? String(contentsOf: AppPaths.ledgerFile, encoding: .utf8) else {
            print("(no log yet at \(AppPaths.ledgerFile.path))")
            return
        }
        let all = content.split(separator: "\n", omittingEmptySubsequences: true)
        for line in all.suffix(lines) { print(line) }
    }
}
