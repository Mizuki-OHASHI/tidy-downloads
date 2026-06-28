import Foundation
import Rainbow

// MARK: - Color control

/// Force colors on for display commands (so `... | less -R` stays colored),
/// unless the user opts out via `--no-color` or the NO_COLOR convention.
/// Setting `enabled` alone isn't enough: Rainbow also suppresses color when the
/// output target isn't a console (e.g. a pipe), so force the target too.
func configureColors(disabled: Bool) {
    if disabled {
        Rainbow.enabled = false
    } else {
        Rainbow.outputTarget = .console
        Rainbow.enabled = true
    }
}

// MARK: - Display width (CJK / emoji aware)

/// Visible terminal width of a string. Counts CJK/fullwidth/emoji as 2 cells,
/// combining marks as 0. Keeps box borders and columns aligned for Japanese
/// filenames. Computed on PLAIN text (apply color after padding).
func displayWidth(_ s: String) -> Int {
    var w = 0
    for scalar in s.unicodeScalars {
        let v = scalar.value
        if v == 0 { continue }
        if (0x0300...0x036F).contains(v) { continue } // combining marks
        w += isWide(v) ? 2 : 1
    }
    return w
}

private func isWide(_ v: UInt32) -> Bool {
    return (0x1100...0x115F).contains(v)   // Hangul Jamo
        || (0x2E80...0x303E).contains(v)   // CJK radicals, Kangxi, punctuation
        || (0x3041...0x33FF).contains(v)   // Kana .. CJK symbols
        || (0x3400...0x4DBF).contains(v)   // CJK Ext A
        || (0x4E00...0x9FFF).contains(v)   // CJK Unified
        || (0xA000...0xA4CF).contains(v)   // Yi
        || (0xAC00...0xD7A3).contains(v)   // Hangul syllables
        || (0xF900...0xFAFF).contains(v)   // CJK compat
        || (0xFE30...0xFE4F).contains(v)   // CJK compat forms
        || (0xFF00...0xFF60).contains(v)   // Fullwidth forms
        || (0xFFE0...0xFFE6).contains(v)
        || (0x1F300...0x1FAFF).contains(v) // emoji & symbols
        || (0x20000...0x3FFFD).contains(v) // CJK Ext B+
}

/// Right-pad a plain string to a visible width.
func padTo(_ s: String, _ width: Int) -> String {
    let pad = width - displayWidth(s)
    return pad > 0 ? s + String(repeating: " ", count: pad) : s
}

/// Truncate a plain string to a visible width, adding an ellipsis if cut.
func truncateTo(_ s: String, _ width: Int) -> String {
    if displayWidth(s) <= width { return s }
    var out = "", w = 0
    for ch in s {
        let cw = displayWidth(String(ch))
        if w + cw > width - 1 { out += "…"; break }
        out += String(ch); w += cw
    }
    return out
}

// MARK: - Terminal width

func terminalWidth(default def: Int = 100) -> Int {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
        return Int(ws.ws_col)
    }
    if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c), n > 0 {
        return n
    }
    return def
}

// MARK: - Ledger stats

struct LedgerStats {
    var total = 0
    var today = 0
    var versioned = 0   // archive events (= new versions kept)
    var dedup = 0       // dedup-trash events

    static func compute(from url: URL) -> LedgerStats {
        var s = LedgerStats()
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return s }
        let todayPrefix = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let dec = JSONDecoder()
        for line in content.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let ev = try? dec.decode(LedgerEvent.self, from: d) else { continue }
            s.total += 1
            if ev.ts.hasPrefix(todayPrefix) { s.today += 1 }
            if ev.action == "archive" { s.versioned += 1 }
            if ev.action == "dedup-trash" { s.dedup += 1 }
        }
        return s
    }
}

// MARK: - status dashboard

enum StatusView {
    static func render() {
        let config = Config.loadOrCreate()
        let running = LaunchAgent.isRunning()
        let stats = LedgerStats.compute(from: AppPaths.ledgerFile)

        let title = "tidy-downloads"
        var rows: [(label: String, plain: String, colored: String)] = []
        func row(_ label: String, _ value: String, _ colored: String) {
            rows.append((label, value, colored))
        }

        row("daemon", running ? "● running" : "○ stopped",
                       running ? "● running".green : "○ stopped".red)
        row("watching", abbreviateHome(config.watchedDirectory),
                         abbreviateHome(config.watchedDirectory))
        let types = config.extensions.map { ".\($0)" }.joined(separator: " ")
        row("types", types, types)
        let ledgerLine = "\(stats.total) ops · \(stats.today) today"
        row("ledger", ledgerLine, ledgerLine)
        if stats.total > 0 {
            let bd = "\(stats.versioned) versioned · \(stats.dedup) deduped"
            row("history", bd, bd)
        }

        let labelW = rows.map { displayWidth($0.label) }.max() ?? 0
        let bodyW = rows.map { labelW + 2 + displayWidth($0.plain) }.max() ?? 0
        let inner = max(displayWidth(title), bodyW)

        let bar = String(repeating: "─", count: inner + 2)
        print(("╭" + bar + "╮").cyan)
        printBox(plain: title, colored: title.bold, inner: inner)
        print(("├" + bar + "┤").cyan)
        for r in rows {
            let labelPlain = padTo(r.label, labelW)
            let plain = labelPlain + "  " + r.plain
            let colored = labelPlain.dim + "  " + r.colored
            printBox(plain: plain, colored: colored, inner: inner)
        }
        print(("╰" + bar + "╯").cyan)
    }

    private static func printBox(plain: String, colored: String, inner: Int) {
        let pad = max(0, inner - displayWidth(plain))
        print("│ ".cyan + colored + String(repeating: " ", count: pad) + " │".cyan)
    }
}

// MARK: - log table

enum LogView {
    static func render(limit: Int?) {
        guard let content = try? String(contentsOf: AppPaths.ledgerFile, encoding: .utf8),
              !content.isEmpty else {
            print("no activity yet — ledger is empty".dim)
            print("(\(AppPaths.ledgerFile.path))".dim)
            return
        }
        let dec = JSONDecoder()
        var events: [LedgerEvent] = []
        for line in content.split(separator: "\n") {
            if let d = line.data(using: .utf8), let ev = try? dec.decode(LedgerEvent.self, from: d) {
                events.append(ev)
            }
        }
        guard !events.isEmpty else { print("no activity yet".dim); return }

        var shown = Array(events.reversed())            // newest first
        if let limit = limit { shown = Array(shown.prefix(max(0, limit))) }

        let timeW = 11      // "MM-dd HH:mm"
        let actionW = 7     // promote / archive / dedup
        let term = terminalWidth()
        let fileW = max(20, term - (timeW + 1 + actionW + 1))

        // header
        let header = padTo("TIME", timeW) + " " + padTo("ACTION", actionW) + " " + "FILE"
        print(header.dim)
        print(String(repeating: "─", count: min(term, timeW + 1 + actionW + 1 + fileW)).dim)

        for ev in shown {
            let t = formatTime(ev.ts)
            let (aPlain, aColored) = actionCell(ev.action)
            let detail = truncateTo(detailText(ev), fileW)
            let line = padTo(t, timeW).dim
                + " " + padTo(aPlain, actionW).replacingOccurrences(of: aPlain, with: aColored)
                + " " + detail
            print(line)
        }

        let scope = limit == nil ? "all" : "last \(min(limit!, events.count))"
        print(String(repeating: "─", count: min(term, timeW + 1 + actionW + 1 + fileW)).dim)
        print("\(scope) of \(events.count) ops · \(AppPaths.ledgerFile.path)".dim)
    }

    private static func actionCell(_ a: String) -> (plain: String, colored: String) {
        switch a {
        case "promote":     return ("promote", "promote".green)
        case "archive":     return ("archive", "archive".blue)
        case "dedup-trash": return ("dedup",   "dedup".red)
        default:            return (a, a)
        }
    }

    private static func detailText(_ ev: LedgerEvent) -> String {
        switch ev.action {
        case "promote":
            return lastComponent(ev.to)
        case "archive":
            return lastTwo(ev.to)
        case "dedup-trash":
            return lastComponent(ev.from) + " → Trash"
        default:
            return ev.to ?? ev.from ?? ""
        }
    }

    private static let parser: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    private static func formatTime(_ iso: String) -> String {
        if let d = parser.date(from: iso) { return local.string(from: d) }
        return String(iso.prefix(16))
    }
}

// MARK: - small path helpers

func lastComponent(_ path: String?) -> String {
    guard let p = path else { return "" }
    return URL(fileURLWithPath: p).lastPathComponent
}

func lastTwo(_ path: String?) -> String {
    guard let p = path else { return "" }
    let u = URL(fileURLWithPath: p)
    let last = u.lastPathComponent
    let parent = u.deletingLastPathComponent().lastPathComponent
    return parent.isEmpty ? last : "\(parent)/\(last)"
}

func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
