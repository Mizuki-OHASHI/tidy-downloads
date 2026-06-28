import Foundation

/// User-editable configuration, persisted as JSON in the support directory.
struct Config: Codable {
    /// Directory to watch (non-recursive).
    var watchedDirectory: String
    /// Extensions to act on, lowercase, without the leading dot.
    var extensions: [String]
    /// Regexes applied to the filename *stem* (name without extension).
    /// Capture group 1 must be the base name (the name without the dedup suffix).
    var collisionPatterns: [String]
    /// Quiet period after the last directory change before rescanning.
    var debounceSeconds: Double

    /// Defaults, verified against real downloads:
    ///   - Chromium (Chrome, Dia, Edge, Brave): "name (1)"  -> space + parenthesized number
    ///   - Safari & Firefox:                     "name-1"    -> hyphen + number
    /// The hyphen form is broad, so a match is acted on only when the base file
    /// actually exists (see CollisionResolver), which avoids mangling names like
    /// "covid-19.pdf".
    static let defaultPatterns = [
        #"^(.+) \((\d+)\)$"#,   // Chromium (Chrome, Dia, Edge, Brave)
        #"^(.+)-(\d+)$"#,       // Safari & Firefox
    ]

    static func makeDefault() -> Config {
        Config(
            watchedDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads").path,
            extensions: ["pdf"],
            collisionPatterns: defaultPatterns,
            debounceSeconds: 1.0
        )
    }

    /// Load the config, creating (and persisting) the default if none exists.
    static func loadOrCreate() -> Config {
        AppPaths.ensureSupportDir()
        let url = AppPaths.configFile
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = makeDefault()
        if let data = try? JSONEncoder.pretty.encode(cfg) {
            try? data.write(to: url)
        }
        return cfg
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
