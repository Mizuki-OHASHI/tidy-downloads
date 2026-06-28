import Foundation

/// Outcome of processing one candidate file.
enum ActionResult {
    case none       // not a collision we act on
    case versioned  // archived the old top, promoted the new file
    case deduped    // identical re-download; old top moved to Trash
}

/// The core logic: decide what to do with a single candidate file.
final class CollisionResolver {
    private let config: Config
    private let ledger: Ledger
    private let dryRun: Bool
    private let fm = FileManager.default
    private let patterns: [NSRegularExpression]

    init(config: Config, ledger: Ledger, dryRun: Bool = false) {
        self.config = config
        self.ledger = ledger
        self.dryRun = dryRun
        self.patterns = config.collisionPatterns.compactMap {
            try? NSRegularExpression(pattern: $0)
        }
    }

    /// If `stem` looks like a browser dedup name, return the base name; else nil.
    func baseStem(for stem: String) -> String? {
        for re in patterns {
            let range = NSRange(stem.startIndex..., in: stem)
            if let m = re.firstMatch(in: stem, options: [], range: range),
               m.numberOfRanges >= 2,
               let r = Range(m.range(at: 1), in: stem) {
                let base = String(stem[r])
                if !base.isEmpty { return base }
            }
        }
        return nil
    }

    /// Process one settled file. No-op unless it matches a collision pattern AND
    /// the corresponding base file actually exists in the same directory.
    @discardableResult
    func process(_ fileURL: URL) -> ActionResult {
        let ext = fileURL.pathExtension.lowercased()
        guard config.extensions.contains(ext) else { return .none }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        guard let base = baseStem(for: stem) else { return .none }

        let dir = fileURL.deletingLastPathComponent()
        let topURL = dir.appendingPathComponent("\(base).\(ext)")
        guard topURL.path != fileURL.path else { return .none }

        // Safety: only treat this as a collision when the base file is really
        // there. Otherwise "report-2.pdf" might just be a legitimate filename.
        guard fm.fileExists(atPath: topURL.path) else { return .none }

        do {
            let incomingHash = try FileHasher.sha256(of: fileURL)
            let topHash = try FileHasher.sha256(of: topURL)

            if incomingHash == topHash {
                // Same content as the current top -> redundant re-download.
                if dryRun {
                    print(Present.action(dedup: true, top: topURL, incoming: fileURL, dryRun: true))
                    return .deduped
                }
                let trashed = try Trash.move(topURL)
                do {
                    try fm.moveItem(at: fileURL, to: topURL)
                } catch {
                    // Roll back: restore the trashed top so a partial failure loses nothing.
                    if let trashed = trashed { try? fm.moveItem(at: trashed, to: topURL) }
                    throw error
                }
                // Record only after both filesystem steps succeed (keeps the ledger consistent).
                ledger.record(action: "dedup-trash", from: topURL, to: trashed,
                              hash: topHash, trashPath: trashed)
                ledger.record(action: "promote", from: fileURL, to: topURL, hash: incomingHash)
                print(Present.action(dedup: true, top: topURL, incoming: fileURL, dryRun: false))
                return .deduped
            } else {
                // New version: archive the current top, promote the incoming file.
                let folder = dir.appendingPathComponent(base, isDirectory: true)
                let n = nextIndex(in: folder, base: base, ext: ext)
                let archived = folder.appendingPathComponent("\(base)_\(n).\(ext)")
                if dryRun {
                    print(Present.action(dedup: false, top: topURL, incoming: fileURL, dryRun: true))
                    return .versioned
                }
                try ensureFolder(folder)
                try fm.moveItem(at: topURL, to: archived)
                do {
                    try fm.moveItem(at: fileURL, to: topURL)
                } catch {
                    // Roll back the archive so a partial failure leaves the original state intact.
                    try? fm.moveItem(at: archived, to: topURL)
                    throw error
                }
                // Record only after both filesystem steps succeed (keeps the ledger consistent).
                ledger.record(action: "archive", from: topURL, to: archived, hash: topHash)
                ledger.record(action: "promote", from: fileURL, to: topURL, hash: incomingHash)
                print(Present.action(dedup: false, top: topURL, incoming: fileURL, dryRun: false))
                return .versioned
            }
        } catch {
            logError("error processing \(fileURL.lastPathComponent): \(error)")
            return .none
        }
    }

    private func ensureFolder(_ url: URL) throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue { throw TidyError.folderNameConflict(url.path) }
            return
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Append-only numbering: next index is one past the highest existing one.
    /// (Reads the folder if present; if it doesn't exist yet, starts at 1.)
    private func nextIndex(in folder: URL, base: String, ext: String) -> Int {
        let prefix = "\(base)_"
        let suffix = ".\(ext)"
        let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var maxN = 0
        for name in contents where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            let mid = name.dropFirst(prefix.count).dropLast(suffix.count)
            if let n = Int(mid) { maxN = max(maxN, n) }
        }
        return maxN + 1
    }
}
