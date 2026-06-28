import Foundation

let rawArgs = Array(CommandLine.arguments.dropFirst())
let command = rawArgs.first(where: { !$0.hasPrefix("-") }) ?? "run"
let flags = Set(rawArgs.filter { $0.hasPrefix("-") })
let dryRun = flags.contains("--dry-run") || flags.contains("-n")

switch command {
case "run":
    runDaemon(dryRun: dryRun)

case "organize", "scan-once":
    organizeOnce(dryRun: dryRun)

case "install":
    do { try LaunchAgent.install() } catch { fail(error) }

case "uninstall":
    do { try LaunchAgent.uninstall() } catch { fail(error) }

case "status":
    configureColors(disabled: noColorRequested(flags))
    StatusView.render()

case "log":
    configureColors(disabled: noColorRequested(flags))
    let limit = flags.contains("--all") ? nil : (rawArgs.compactMap { Int($0) }.filter { $0 > 0 }.first ?? 50)
    LogView.render(limit: limit)

case "config":
    _ = Config.loadOrCreate()   // create the default if missing, then print its path
    print(AppPaths.configFile.path)

case "help", "-h", "--help":
    printUsage()

default:
    logError("unknown command: \(command)")
    printUsage()
    exit(2)
}

// MARK: - One-shot

/// Process whatever already exists in the watched directory, then exit.
func organizeOnce(dryRun: Bool) {
    let config = Config.loadOrCreate()
    let ledger = Ledger(url: AppPaths.ledgerFile)
    let resolver = CollisionResolver(config: config, ledger: ledger, dryRun: dryRun)
    log("\(dryRun ? "dry-run: " : "")organizing \(config.watchedDirectory)\(dryRun ? " — no files will be changed" : "")")
    DirectoryScanner.scan(config: config, resolver: resolver, verbose: true)
}

// MARK: - Daemon

/// Holds the watcher alive for the lifetime of the process.
final class Daemon {
    private let dryRun: Bool
    private var watcher: Watcher?

    init(dryRun: Bool) { self.dryRun = dryRun }

    func start() {
        let config = Config.loadOrCreate()
        let ledger = Ledger(url: AppPaths.ledgerFile)
        let resolver = CollisionResolver(config: config, ledger: ledger, dryRun: dryRun)
        let dir = URL(fileURLWithPath: config.watchedDirectory)

        log("watching \(dir.path) for [\(config.extensions.joined(separator: ", "))]\(dryRun ? " (dry-run)" : "")")

        let watcher = Watcher(dir: dir, debounce: config.debounceSeconds) {
            DirectoryScanner.scan(config: config, resolver: resolver, verbose: false)
        }
        do {
            try watcher.start()
        } catch {
            fail(error)
        }
        self.watcher = watcher
    }
}

func runDaemon(dryRun: Bool) {
    let daemon = Daemon(dryRun: dryRun)
    daemon.start()
    dispatchMain() // never returns
}

func fail(_ error: Error) -> Never {
    logError("\(error)")
    exit(1)
}

func noColorRequested(_ flags: Set<String>) -> Bool {
    flags.contains("--no-color") || ProcessInfo.processInfo.environment["NO_COLOR"] != nil
}

func printUsage() {
    print("""
    tidy-downloads — keep duplicate downloads tidy

    USAGE:
      tidy-downloads <command> [--dry-run]

    COMMANDS:
      run         Watch the configured directory (foreground). Also sweeps
                  existing files once at startup.
      organize    Process files already in the directory once, then exit.
      install     Install & start the background LaunchAgent (run at login).
      uninstall   Stop & remove the LaunchAgent.
      status      Show a status dashboard (daemon, watched dir, history).
      log [N]     Show recent activity (default 50; use --all for everything).
      config      Print the path to the config file.
      help        Show this help.

    FLAGS:
      --dry-run, -n   Show what would happen without changing any files.
                      Works with `run` and `organize`.
      --all           Show every ledger entry (with `log`).
      --no-color      Disable colored output (also honors NO_COLOR).

    Config & logs live in:
      \(AppPaths.supportDir.path)
    """)
}
