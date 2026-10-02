import Foundation

/// Automatic installation of missing components.
///
/// Turns diagnostics into action: `gx setup` installs what's missing
/// (Homebrew for winetricks/mingw/cabextract, casks for Wine Staging and GPTK).
public enum Setup {

    public enum Kind: String, Sendable {
        case formula
        case cask
        case command
        case manual
    }

    public struct ComponentStatus: Sendable, Identifiable {
        public let id: String
        public let title: String
        public let kind: Kind
        public let installed: Bool
        public let reason: String
        public let installCommand: [String]   // empty when manual
        public let manualURL: String?
        /// Opzionale: non compare tra i "mancanti" (es. Wine Staging/GPTK di sistema).
        public var optional: Bool = false

        public var installable: Bool { kind != .manual && !installCommand.isEmpty }
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Status of every manageable component.
    public static func status(config: Config) -> [ComponentStatus] {
        let gpu = GPUInfo.detect()
        let macOSMajor = gpu.macOSMajor ?? 26
        let rec = GPTK.recommended(for: macOSMajor)

        let gptkInstalls = GPTK.discover(config: config)
        let gptkOK = gptkInstalls.contains { ($0.major ?? 0) >= rec }
        let gptkURL = "https://developer.apple.com/games/game-porting-toolkit/"

        var items: [ComponentStatus] = []

        // Il pezzo che conta: un runtime Game-X **auto-consistente** (Wine + renderer
        // + dipendenze dentro la cartella del runtime). Il default supportato è
        // `wine-gptk` (Wine dai sorgenti CodeWeavers + D3DMetal di Apple).
        let selfContained = !Runtime.dxmtRuntimes(config: config).isEmpty
            || !Runtime.d3dmetalRuntimes(config: config).isEmpty
        let gptkRuntime = !Runtime.d3dmetalRuntimes(config: config).isEmpty
        items.append(.init(
            id: "runtime", title: "Runtime Game-X wine-gptk (Wine+D3DMetal)", kind: .manual,
            installed: gptkRuntime,
            reason: "the standard engine: CodeWeavers Wine + D3DMetal (Apple)",
            installCommand: [],
            manualURL: gptkRuntime ? nil : "gx runtime build-gptk (downloads the Wine base; uses Apple's GPTK 4 DMG for D3DMetal)"))

        items.append(.init(
            id: "rosetta", title: "Rosetta 2", kind: .command,
            installed: Runtime.rosettaAvailable(),
            reason: "needed to run x86_64 Wine on Apple Silicon",
            installCommand: ["/usr/sbin/softwareupdate", "--install-rosetta", "--agree-to-license"],
            manualURL: nil))

        // Xcode Command Line Tools: servono per compilare Wine (wine-cx) e lo shim.
        let cltOK: Bool = {
            guard let r = try? ProcessRunner.run("/usr/bin/xcode-select", ["-p"]) else { return false }
            return r.success
        }()
        items.append(.init(
            id: "xcode-clt", title: "Xcode Command Line Tools", kind: .command,
            installed: cltOK,
            reason: "builds Wine (wine-cx) and the Steam shim",
            installCommand: ["/usr/bin/xcode-select", "--install"],
            manualURL: nil))

        // Homebrew: fonte di winetricks / mingw-w64 / cabextract.
        items.append(.init(
            id: "homebrew", title: "Homebrew", kind: .manual,
            installed: brewPath != nil,
            reason: "provides winetricks, mingw-w64, cabextract",
            installCommand: [],
            manualURL: brewPath == nil ? "https://brew.sh" : nil))

        items.append(.init(
            id: "winetricks", title: "winetricks", kind: brewPath == nil ? .manual : .formula,
            installed: FileManager.default.isExecutableFile(atPath: config.winetricks),
            reason: "installs Windows dependencies (VC++, .NET, fonts)",
            installCommand: brewPath.map { [$0, "install", "winetricks"] } ?? [],
            manualURL: "https://formulae.brew.sh/formula/winetricks"))

        let mingw = "/opt/homebrew/bin/x86_64-w64-mingw32-gcc"
        items.append(.init(
            id: "mingw", title: "mingw-w64", kind: .formula,
            installed: FileManager.default.isExecutableFile(atPath: mingw),
            reason: "needed to build the steamwebhelper shim (gx steam repair)",
            installCommand: brewPath.map { [$0, "install", "mingw-w64"] } ?? [],
            manualURL: "https://formulae.brew.sh/formula/mingw-w64"))

        let cabextract = "/opt/homebrew/bin/cabextract"
        items.append(.init(
            id: "cabextract", title: "cabextract", kind: .formula,
            installed: FileManager.default.isExecutableFile(atPath: cabextract),
            reason: "required by winetricks",
            installCommand: brewPath.map { [$0, "install", "cabextract"] } ?? [],
            manualURL: "https://formulae.brew.sh/formula/cabextract"))

        let stagingWine = "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"
        items.append(.init(
            id: "wine-staging", title: "Wine Staging (WineHQ)", kind: .cask,
            installed: FileManager.default.isExecutableFile(atPath: stagingWine),
            reason: selfContained ? "optional: the Game-X runtime already ships a modern Wine"
                                  : "modern runtime for the Steam UI (needs Wine >= 8)",
            installCommand: brewPath.map { [$0, "install", "--cask", "wine@staging"] } ?? [],
            manualURL: "https://formulae.brew.sh/cask/wine@staging",
            optional: true))

        let gptkCommand: [String]
        let gptkKind: Kind
        if gptkOK {
            gptkCommand = []
            gptkKind = .cask
        } else if rec <= 3, let brew = brewPath {
            gptkCommand = [brew, "install", "--cask", "game-porting-toolkit"]
            gptkKind = .cask
        } else {
            gptkCommand = []
            gptkKind = .manual
        }
        items.append(.init(
            id: "gptk", title: "Game Porting Toolkit \(rec)", kind: gptkKind,
            installed: gptkOK,
            reason: selfContained ? "optional: D3DMetal is already in the Game-X runtime (wine-gptk)"
                                  : "recommended runtime for macOS \(macOSMajor) (D3DMetal)",
            installCommand: gptkCommand,
            manualURL: gptkCommand.isEmpty ? gptkURL : nil,
            optional: true))

        // Permessi TCC: senza questi tastiera e controller non arrivano al gioco.
        let axOK = Permissions.accessibility().isGranted
        let imOK = Permissions.inputMonitoring().isGranted
        items.append(.init(
            id: "tcc", title: "macOS permissions (Accessibility + Input Monitoring)", kind: .manual,
            installed: axOK && imOK,
            reason: "keyboard and controller input in-game (Privacy & Security)",
            installCommand: [],
            manualURL: (axOK && imOK) ? nil : "System Settings → Privacy & Security → Accessibility + Input Monitoring (add GameX.app and the wine binary)"))

        return items
    }

    /// Installs a component (streamed to stdout + log). Returns the exit code.
    @discardableResult
    public static func install(
        _ component: ComponentStatus,
        config: Config,
        dryRun: Bool = false
    ) throws -> Int32 {
        guard component.installable else {
            Log.shared.warn("component '\(component.id)' requires manual install: \(component.manualURL ?? "-")")
            return 1
        }
        let cmd = component.installCommand
        Log.shared.info("setup: \(cmd.joined(separator: " "))")
        if dryRun { return 0 }

        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ANALYTICS"] = "1"

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = config.resolvedPaths().logsRoot.appendingPathComponent("setup/\(component.id)-\(stamp).log")

        return try ProcessRunner.runStreaming(cmd[0], Array(cmd.dropFirst()),
                                              environment: env, logFile: logFile)
    }

    /// Installs all missing, installable components. Returns the count of successes.
    @discardableResult
    public static func installMissing(config: Config, dryRun: Bool = false, log: (String) -> Void = { _ in }) -> Int {
        var success = 0
        for component in status(config: config) where !component.installed {
            if !component.installable {
                log("MANUAL   \(component.title): \(component.manualURL ?? "-")")
                continue
            }
            log("INSTALL  \(component.title)…")
            do {
                let code = try install(component, config: config, dryRun: dryRun)
                if code == 0 { success += 1; log("OK       \(component.title)") }
                else { log("ERROR    \(component.title) (exit \(code))") }
            } catch {
                log("ERROR    \(component.title): \(error)")
            }
        }
        return success
    }
}
