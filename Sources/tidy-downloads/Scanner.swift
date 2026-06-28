import Foundation

/// Rescans the watched directory and hands each settled candidate to the
/// resolver. Idempotent: the resolver ignores anything that isn't an
/// actionable collision, so repeated scans converge to a stable state.
/// Returns how many files were versioned vs deduped.
enum DirectoryScanner {
    @discardableResult
    static func scan(config: Config, resolver: CollisionResolver) -> (versioned: Int, deduped: Int) {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: config.watchedDirectory)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return (0, 0) }
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
        var versioned = 0, deduped = 0
        for item in candidates.sorted(by: { $0.mtime < $1.mtime }) {
            switch resolver.process(item.url) {
            case .versioned: versioned += 1
            case .deduped:   deduped += 1
            case .none:      break
            }
        }
        return (versioned, deduped)
    }
}
