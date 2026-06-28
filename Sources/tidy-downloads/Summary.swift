import Foundation
import Rainbow

/// One file in a version group.
struct VersionFile {
    let url: URL
    let size: Int
    let mtime: Date
}

/// A base name with a `name/` archive folder: the latest top file (if present)
/// plus its archived older versions.
struct VersionGroup {
    let base: String
    let latest: VersionFile?          // name.ext at top level (nil if user deleted it)
    let archives: [VersionFile]       // name/name_N.ext, newest first

    var allFiles: [VersionFile] { (latest.map { [$0] } ?? []) + archives }
    var totalSize: Int { allFiles.reduce(0) { $0 + $1.size } }
    var versionCount: Int { allFiles.count }
    var sortKey: Date { latest?.mtime ?? archives.first?.mtime ?? .distantPast }
}

/// `summary`: a grouped overview of every version group in the watched directory.
/// Source of truth is the filesystem (the folders ARE the versions); `log` covers
/// the operation history.
enum SummaryView {
    static func render() {
        let config = Config.loadOrCreate()
        let groups = collect(config: config).sorted { $0.sortKey > $1.sortKey }

        guard !groups.isEmpty else {
            print("\n" + "no version groups in \(abbreviateHome(config.watchedDirectory))".dim + "\n")
            return
        }

        let allFiles = groups.flatMap { $0.allFiles }
        let nameW = min(44, allFiles.map { displayWidth($0.url.lastPathComponent) }.max() ?? 0)
        let sizeW = allFiles.map { humanSize($0.size).count }.max() ?? 0
        let titleW = min(40, groups.map { displayWidth($0.base) }.max() ?? 0)

        print("")
        var totalArchives = 0, grandTotal = 0
        for g in groups {
            totalArchives += g.archives.count
            grandTotal += g.totalSize

            let titlePlain = truncateTo(g.base, titleW)
            let titleCell = padTo(titlePlain, titleW).replacingOccurrences(of: titlePlain, with: titlePlain.cyan.bold)
            let unit = g.versionCount == 1 ? "version" : "versions"
            let meta = "\(g.versionCount) \(unit) · \(humanSize(g.totalSize))".dim
            print("\(titleCell)  \(meta)")

            if let latest = g.latest {
                print(fileLine(latest, nameW: nameW, sizeW: sizeW, latest: true))
            } else {
                print("  " + "✗ latest missing".red)
            }
            for a in g.archives {
                print(fileLine(a, nameW: nameW, sizeW: sizeW, latest: false))
            }
            print("")
        }

        let gUnit = groups.count == 1 ? "group" : "groups"
        print("\(groups.count) \(gUnit) · \(totalArchives) archived · \(humanSize(grandTotal))".dim)
    }

    private static func fileLine(_ f: VersionFile, nameW: Int, sizeW: Int, latest: Bool) -> String {
        let prefix = latest ? "  \("●".green) " : "    "
        let namePlain = truncateTo(f.url.lastPathComponent, nameW)
        let nameCellPlain = padTo(namePlain, nameW)
        let nameCell = latest
            ? nameCellPlain.replacingOccurrences(of: namePlain, with: namePlain.bold)
            : nameCellPlain
        let sizeStr = humanSize(f.size)
        let sizeCell = String(repeating: " ", count: max(0, sizeW - sizeStr.count)) + sizeStr
        let tag = latest ? "  " + "latest".green : ""
        return prefix + nameCell + "  " + (sizeCell + "  " + dateStr(f.mtime)).dim + tag
    }

    // MARK: - Collection

    private static func collect(config: Config) -> [VersionGroup] {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: config.watchedDirectory)
        let exts = Set(config.extensions.map { $0.lowercased() })
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        var groups: [VersionGroup] = []
        for base in entries {
            let folder = dir.appendingPathComponent(base, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let inner = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }

            // Collect only "base_N.<ext>" files; ignore anything else in the folder.
            var archivesByExt: [String: [(n: Int, vf: VersionFile)]] = [:]
            let prefix = "\(base)_"
            for entry in inner {
                let url = folder.appendingPathComponent(entry)
                let ext = url.pathExtension.lowercased()
                guard exts.contains(ext) else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                guard stem.hasPrefix(prefix), let n = Int(stem.dropFirst(prefix.count)), n >= 1 else { continue }
                guard let vf = makeFile(url, fm: fm) else { continue }
                archivesByExt[ext, default: []].append((n, vf))
            }

            for (ext, list) in archivesByExt where !list.isEmpty {
                let archives = list.sorted { $0.n > $1.n }.map { $0.vf }   // newest N first
                let topURL = dir.appendingPathComponent("\(base).\(ext)")
                let latest = makeFile(topURL, fm: fm)
                groups.append(VersionGroup(base: base, latest: latest, archives: archives))
            }
        }
        return groups
    }

    private static func makeFile(_ url: URL, fm: FileManager) -> VersionFile? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? Int) ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        return VersionFile(url: url, size: size, mtime: mtime)
    }

    // MARK: - Formatting

    private static func humanSize(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        let kb = b / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func dateStr(_ d: Date) -> String { dateFormatter.string(from: d) }
}
