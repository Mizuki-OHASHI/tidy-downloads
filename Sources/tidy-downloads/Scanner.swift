import Foundation

/// Rescans the watched directory and hands each settled candidate to the
/// resolver. Idempotent: the resolver ignores anything that isn't an
/// actionable collision, so repeated scans converge to a stable state.
enum DirectoryScanner {
    static func scan(config: Config, resolver: CollisionResolver, verbose: Bool) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: config.watchedDirectory)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let exts = Set(config.extensions.map { $0.lowercased() })

        var candidates: [(url: URL, mtime: Date)] = []
        for name in names {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard exts.contains(url.pathExtension.lowercased()) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            guard size > 0 else { continue } // skip empty / still-creating files
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            candidates.append((url, mtime))
        }

        // Process oldest first so that, if several dedup files are present, the
        // newest one ends up promoted to the top-level name.
        for item in candidates.sorted(by: { $0.mtime < $1.mtime }) {
            resolver.process(item.url)
        }

        if verbose { print("scanned \(candidates.count) candidate file(s) in \(dir.path)") }
    }
}
