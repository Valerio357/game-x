import Foundation

/// Configurazione effettiva di Game-X, risolta da env + file + default.
public struct Config: Sendable {
    public var prefixRoot: String
    public var gamesRoot: String
    public var logsRoot: String
    public var cacheRoot: String
    public var gptkApp: String
    public var wineBinary: String
    public var winetricks: String
    public var arch: String
    public var defaultSteamPrefix: String
    public var webhelperWrapper: String   // auto | on | off
    public var esync: Bool
    public var msync: Bool
    public var logLevel: String
    /// Runtime dxmf: host Wine (default `~/wine-d3dmetal`).
    public var dxmfWineRoot: String
    /// Stage dxmf (`WINEDLLPATH_PREPEND`); vuoto = scoperta di default.
    public var dxmfStage: String
    public var dxmfLockDir: String
    public var dxmfGateLockWait: Int
    public var dxmfLogCapMB: Int

    public init(
        prefixRoot: String = DefaultPaths.prefixRoot,
        gamesRoot: String = DefaultPaths.gamesRoot,
        logsRoot: String = DefaultPaths.logsRoot,
        cacheRoot: String = DefaultPaths.cacheRoot,
        gptkApp: String = DefaultPaths.gptkApp,
        wineBinary: String = "",
        winetricks: String = DefaultPaths.winetricks,
        arch: String = "win64",
        defaultSteamPrefix: String = "Steam",
        webhelperWrapper: String = "auto",
        esync: Bool = true,
        msync: Bool = false,
        logLevel: String = "info",
        dxmfWineRoot: String = "~/wine-d3dmetal",
        dxmfStage: String = "",
        dxmfLockDir: String = "",
        dxmfGateLockWait: Int = 0,
        dxmfLogCapMB: Int = 512
    ) {
        self.prefixRoot = prefixRoot
        self.gamesRoot = gamesRoot
        self.logsRoot = logsRoot
        self.cacheRoot = cacheRoot
        self.gptkApp = gptkApp
        self.wineBinary = wineBinary
        self.winetricks = winetricks
        self.arch = arch
        self.defaultSteamPrefix = defaultSteamPrefix
        self.webhelperWrapper = webhelperWrapper
        self.esync = esync
        self.msync = msync
        self.logLevel = logLevel
        self.dxmfWineRoot = dxmfWineRoot
        self.dxmfStage = dxmfStage
        self.dxmfLockDir = dxmfLockDir
        self.dxmfGateLockWait = dxmfGateLockWait
        self.dxmfLogCapMB = dxmfLogCapMB
    }

    /// Risolve la configurazione: default → file → ambiente.
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL = DefaultPaths.configFile
    ) -> Config {
        var config = Config()

        // 1) file (se presente)
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            applyTOML(text, to: &config)
        }

        // 2) ambiente (precedenza massima)
        if let v = environment["GX_PREFIX_ROOT"] { config.prefixRoot = v }
        if let v = environment["GX_GAMES_ROOT"] { config.gamesRoot = v }
        if let v = environment["GX_LOGS_ROOT"] { config.logsRoot = v }
        if let v = environment["GX_CACHE_ROOT"] { config.cacheRoot = v }
        if let v = environment["GX_GPTK_APP"] { config.gptkApp = v }
        if let v = environment["GX_WINE"] { config.wineBinary = v }
        if let v = environment["GX_WINETRICKS"] { config.winetricks = v }
        if let v = environment["GX_ARCH"] { config.arch = v }
        if let v = environment["GX_STEAM_PREFIX"] { config.defaultSteamPrefix = v }
        if let v = environment["GX_LOG_LEVEL"] { config.logLevel = v }
        if let v = environment["GX_DXMF_WINE_ROOT"] { config.dxmfWineRoot = v }
        if let v = environment["GX_DXMF_STAGE"] { config.dxmfStage = v }
        if let v = environment["GX_DXMF_LOCK_DIR"] { config.dxmfLockDir = v }
        if let v = environment["GX_DXMF_GATE_LOCK_WAIT"], let n = Int(v) {
            config.dxmfGateLockWait = n
        }
        if let v = environment["GX_DXMF_LOG_CAP_MB"], let n = Int(v) {
            config.dxmfLogCapMB = n
        }

        return config
    }

    public func resolvedPaths() -> Paths {
        Paths(
            prefixRoot: Paths.url(prefixRoot),
            gamesRoot: Paths.url(gamesRoot),
            logsRoot: Paths.url(logsRoot),
            cacheRoot: Paths.url(cacheRoot),
            gptkApp: Paths.url(gptkApp),
            wineBinaryOverride: wineBinary.isEmpty ? nil : wineBinary,
            winetricks: winetricks,
            shimExecutable: nil
        )
    }
}

// MARK: - Parser TOML minimale

/// Supporta: `[sezione]`, `chiave = "stringa"`, `chiave = true|false`, commenti `#`.
/// Non è un parser TOML completo: sufficiente per il file di configurazione.
public enum TOMLParser {
    public struct Entry: Sendable {
        public var section: String
        public var key: String
        public var value: String
    }

    public static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            entries.append(Entry(section: section, key: key, value: value))
        }
        return entries
    }

    private static func stripComment(_ line: String) -> String {
        var result = ""
        var inString = false
        for ch in line {
            if ch == "\"" { inString.toggle() }
            if ch == "#" && !inString { break }
            result.append(ch)
        }
        return result
    }
}

private func applyTOML(_ text: String, to config: inout Config) {
    for entry in TOMLParser.parse(text) {
        let full = entry.section.isEmpty ? entry.key : "\(entry.section).\(entry.key)"
        switch full {
        case "paths.prefix_root": config.prefixRoot = entry.value
        case "paths.games_root": config.gamesRoot = entry.value
        case "paths.logs_root": config.logsRoot = entry.value
        case "paths.cache_root": config.cacheRoot = entry.value
        case "runtime.gptk_app": config.gptkApp = entry.value
        case "runtime.wine_binary": config.wineBinary = entry.value
        case "runtime.winetricks": config.winetricks = entry.value
        case "runtime.arch": config.arch = entry.value
        case "steam.default_prefix": config.defaultSteamPrefix = entry.value
        case "steam.webhelper_wrapper": config.webhelperWrapper = entry.value
        case "launch.esync": config.esync = (entry.value == "true")
        case "launch.msync": config.msync = (entry.value == "true")
        case "dxmf.wine_root": config.dxmfWineRoot = entry.value
        case "dxmf.stage": config.dxmfStage = entry.value
        case "dxmf.lock_dir": config.dxmfLockDir = entry.value
        case "dxmf.gate_lock_wait": if let n = Int(entry.value) { config.dxmfGateLockWait = n }
        case "dxmf.log_cap_mb": if let n = Int(entry.value) { config.dxmfLogCapMB = n }
        default: break
        }
    }
}
