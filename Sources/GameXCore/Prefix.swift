import Foundation

/// Un Wine prefix gestito da Game-X.
public struct PrefixRecord: Sendable, Identifiable {
    public let name: String
    public let url: URL

    public var id: String { name }

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    public var driveC: URL { url.appendingPathComponent("drive_c") }
    public var metaURL: URL { url.appendingPathComponent(".gx.meta.json") }

    public var steamExe: URL {
        driveC.appendingPathComponent("Program Files (x86)/Steam/Steam.exe")
    }
    public var hasSteam: Bool { FileManager.default.fileExists(atPath: steamExe.path) }

    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: driveC.path)
    }

    public func loadMeta() -> PrefixMeta? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(PrefixMeta.self, from: data)
    }

    /// Dimensione su disco in byte (best effort).
    public func sizeBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

/// Metadati di un prefix (`.gx.meta.json`).
public struct PrefixMeta: Codable, Sendable {
    public var name: String
    public var kind: String            // prefix | steam
    public var runtimeKind: String
    public var runtimeVersion: String
    public var wineBinary: String?
    public var createdAt: String
    public var updatedAt: String?

    public init(name: String, kind: String, runtimeKind: String,
                runtimeVersion: String, wineBinary: String? = nil,
                createdAt: String, updatedAt: String? = nil) {
        self.name = name
        self.kind = kind
        self.runtimeKind = runtimeKind
        self.runtimeVersion = runtimeVersion
        self.wineBinary = wineBinary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PrefixError: Error, CustomStringConvertible {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case winebootFailed(String, Int32)

    public var description: String {
        switch self {
        case .invalidName(let n):
            return "invalid box name: '\(n)' (use letters, digits, '-', '_')"
        case .alreadyExists(let n):
            return "box '\(n)' already exists"
        case .notFound(let n):
            return "box '\(n)' not found"
        case .winebootFailed(let b, let code):
            return "wineboot failed (\(b)) with exit \(code)"
        }
    }
}

/// Gestione dei prefix Wine (M1).
public enum Prefix {

    // MARK: - Discovery

    public static func list(paths: Paths) -> [PrefixRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.prefixRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> PrefixRecord? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir,
                  fm.fileExists(atPath: url.appendingPathComponent("drive_c").path) else { return nil }
            return PrefixRecord(name: url.lastPathComponent, url: url)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func find(_ name: String, paths: Paths) -> PrefixRecord? {
        let url = paths.prefixRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("drive_c").path) else {
            return nil
        }
        return PrefixRecord(name: name, url: url)
    }

    // MARK: - Validazione

    /// Consente lettere, numeri, `-`, `_`, `.`; niente slash o `..`.
    public static func validateName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Creazione

    /// Crea (o aggiorna, idempotente) un prefix eseguendo `wineboot -u`.
    @discardableResult
    public static func create(
        _ name: String,
        config: Config,
        runtime: ResolvedRuntime,
        force: Bool = false
    ) throws -> PrefixRecord {
        guard validateName(name) else { throw PrefixError.invalidName(name) }

        let paths = config.resolvedPaths()
        try FileManager.default.createDirectory(at: paths.prefixRoot, withIntermediateDirectories: true)
        let recordURL = paths.prefixRoot.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: recordURL.appendingPathComponent("drive_c").path), !force {
            throw PrefixError.alreadyExists(name)
        }

        let record = PrefixRecord(name: name, url: recordURL)
        try FileManager.default.createDirectory(at: record.url, withIntermediateDirectories: true)

        var env = baseEnvironment(config: config, prefix: record.url, runtime: runtime)
        env["WINEARCH"] = config.arch

        Log.shared.info("wineboot -u (WINEARCH=\(config.arch)) in \(record.url.path)")
        let result = try ProcessRunner.run(runtime.wineBinary, ["wineboot", "-u"], environment: env)
        guard result.success else {
            throw PrefixError.winebootFailed(runtime.wineBinary, result.exitCode)
        }

        writeMeta(record, runtime: runtime, kind: .prefix)
        disableCrashDialogs(in: record, config: config, runtime: runtime)
        return record
    }

    // MARK: - Esecuzione

    /// Esegue un comando Windows dentro il prefix.
    @discardableResult
    public static func exec(
        _ record: PrefixRecord,
        command: [String],
        config: Config,
        runtime: ResolvedRuntime,
        extraEnv: [String: String] = [:]
    ) throws -> ProcessResult {
        killStaleDebuggers()
        var env = baseEnvironment(config: config, prefix: record.url, runtime: runtime)
        // Runtime GPTK *di sistema* (wine 7.7 + D3DMetal nella box): le DLL sono
        // native → serve "n,b". Per i nostri runtime Wine+D3DMetal (builtin,
        // vedi D3DMetal.environment) invece gli override sono già impostati.
        if runtime.kind == .gptkWine, runtime.hasD3DMetal, runtime.d3dmetal == nil {
            env["WINEDLLOVERRIDES"] = "d3d12,d3d11,dxgi=n,b"
        }
        if config.esync { env["WINEESYNC"] = "1" }
        if config.msync { env["WINEMSYNC"] = "1" }
        env.merge(extraEnv) { _, new in new }   // override per-gioco vincono
        Log.shared.debug("exec: \(runtime.wineBinary) \(command.joined(separator: " "))")
        return try ProcessRunner.run(runtime.wineBinary, command, environment: env)
    }

    /// Uccide i processi Wine del prefix (tramite `wineserver -k`).
    public static func kill(_ record: PrefixRecord, runtime: ResolvedRuntime) {
        let wineserver = URL(fileURLWithPath: runtime.wineBinary)
            .deletingLastPathComponent().appendingPathComponent("wineserver").path
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = record.url.path
        _ = try? ProcessRunner.run(wineserver, ["-k"], environment: env)
    }

    /// Uccide i `winedbg` rimasti in attesa da crash precedenti.
    ///
    /// Ogni crash non gestito di un processo Windows lascia un debugger vivo che
    /// aspetta input: con molti crash (es. il CEF di Steam quando un renderer non
    /// inizializza) se ne accumulano centinaia, fino a esaurire i processi del
    /// sistema (`fork: Resource temporarily unavailable`). Chiamarlo prima di
    /// avviare Steam o un gioco evita l'accumulo.
    public static func killStaleDebuggers() {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = nil
        _ = try? ProcessRunner.run("/usr/bin/pkill", ["-f", "winedbg"], environment: env)
    }

    /// Disattiva il dialog **"Program Error"** di Wine e il debugger per i crash.
    ///
    /// Per un'eccezione non gestita Wine esegue il comando in
    /// `HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug\Debugger`
    /// e **aspetta all'infinito** che si agganci (`WaitForMultipleObjects(...INFINITE)`).
    /// Con `winedbg` ogni crash lascia un processo + un dialog modale: con molti
    /// crash (es. il CEF di Steam) se ne accumulano centinaia fino a esaurire i
    /// processi del sistema, e la UI resta bloccata dietro al dialog.
    /// Con `cmd /c exit` il "debugger" termina subito: Wine chiude il processo
    /// che è andato in crash e non mostra nulla.
    public static func disableCrashDialogs(in record: PrefixRecord, config: Config, runtime: ResolvedRuntime) {
        let key = "HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"
        let env = baseEnvironment(config: config, prefix: record.url, runtime: runtime)
        _ = try? ProcessRunner.run(runtime.wineBinary,
                                   ["reg", "add", key, "/v", "Debugger", "/t", "REG_SZ",
                                    "/d", "cmd /c exit", "/f"], environment: env)
        _ = try? ProcessRunner.run(runtime.wineBinary,
                                   ["reg", "add", key, "/v", "Auto", "/t", "REG_SZ",
                                    "/d", "1", "/f"], environment: env)
    }

    // MARK: - Rimozione

    /// Rimuove un prefix in modo **recuperabile**: lo sposta in `<prefix_root>/.trash/`.
    /// Non cancella mai i save silenziosamente.
    @discardableResult
    public static func remove(_ record: PrefixRecord, paths: Paths) throws -> URL {
        let trash = paths.prefixRoot.appendingPathComponent(".trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destination = trash.appendingPathComponent("\(record.name)-\(stamp)")
        try FileManager.default.moveItem(at: record.url, to: destination)
        return destination
    }

    /// Elimina definitivamente un prefix già spostato nel cestino interno.
    public static func purge(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Ambiente

    /// Ambiente di base per un'operazione su prefix.
    ///
    /// Se il runtime è un **Game-X Wine+DXMT**, aggiunge le variabili che
    /// servono a Wine per caricare DXMT (`WINEDLLPATH_PREPEND`,
    /// `WINEDLLOVERRIDES`, `DYLD_LIBRARY_PATH`) e crea i symlink di
    /// `ntdll.so`/`winemac.so` accanto a `winemetal.so`.
    public static func baseEnvironment(
        config: Config, prefix: URL, runtime: ResolvedRuntime? = nil
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all"
        // wine-mono: se è installato lo lasciamo attivo (serve a Steam/CEF),
        // altrimenti disabilitiamo mscoree per evitare il dialog di download.
        env["WINEDLLOVERRIDES"] = DXMT.monoInstalled(in: prefix) ? "mshtml=" : "mscoree,mshtml="

        if let info = runtime?.dxmt {
            try? DXMT.ensureUnixLinks(info)
            var dxmtEnv = DXMT.environment(for: info)
            if let overrides = dxmtEnv.removeValue(forKey: "WINEDLLOVERRIDES") {
                env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"] ?? "") + ";" + overrides
            }
            env.merge(dxmtEnv) { _, new in new }
        }

        if let info = runtime?.d3dmetal {
            var d3dmEnv = D3DMetal.environment(for: info)
            if let overrides = d3dmEnv.removeValue(forKey: "WINEDLLOVERRIDES") {
                let base = env["WINEDLLOVERRIDES"] ?? ""
                env["WINEDLLOVERRIDES"] = base.isEmpty ? overrides : base + ";" + overrides
            }
            env.merge(d3dmEnv) { _, new in new }
        }
        return env
    }

    // MARK: - Metadata

    public enum MetaKind: String { case prefix, steam }

    static func writeMeta(_ record: PrefixRecord, runtime: ResolvedRuntime, kind: MetaKind) {
        let meta = PrefixMeta(
            name: record.name,
            kind: kind.rawValue,
            runtimeKind: runtime.kind.rawValue,
            runtimeVersion: runtime.version,
            wineBinary: runtime.wineBinary,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: record.metaURL)
        }
    }

    /// Aggiorna il kind del meta (es. dopo installazione Steam) mantenendo il resto.
    public static func updateMetaKind(_ record: PrefixRecord, kind: MetaKind, runtime: ResolvedRuntime) {
        let created = record.loadMeta()?.createdAt ?? ISO8601DateFormatter().string(from: Date())
        let meta = PrefixMeta(
            name: record.name, kind: kind.rawValue,
            runtimeKind: runtime.kind.rawValue, runtimeVersion: runtime.version,
            wineBinary: runtime.wineBinary,
            createdAt: created, updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        if let data = try? JSONEncoder().encode(meta) { try? data.write(to: record.metaURL) }
    }
}

/// Formattazione leggibile delle dimensioni.
public enum ByteFormat {
    public static func human(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", value, units[index])
    }
}
