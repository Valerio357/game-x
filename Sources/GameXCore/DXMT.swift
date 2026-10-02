import Foundation
import CryptoKit

/// Runtime **Game-X Wine + DXMT**: la nostra build di Wine 11.x (x86_64) con
/// patch CodeWeavers (CW HACK 22435) + modulo `winemetal`, più il renderer
/// **DXMT** (Direct3D 10/11 → Metal).
///
/// Layout auto-consistente (tutto dentro la cartella del runtime, così può
/// essere copiata su un'altra macchina senza dipendenze esterne):
///
///     <root>/bin/wine                     (oppure <root>/wine/bin/wine)
///     <root>/lib/wine/…                   (installazione Wine)
///     <root>/share/wine/mono/wine-mono-*.msi
///     <root>/renderers/dxmt/wine/x86_64-windows/{d3d11,dxgi,…}.dll
///     <root>/renderers/dxmt/wine/x86_64-unix/{winemetal.so,ntdll.so,winemac.so}
///     <root>/x64deps/*.dylib              (freetype, gnutls, MoltenVK…)
///     <root>/manifest.json
///
/// Vedi DESIGN-DXMT.md per la ricetta completa e le misure.
public enum DXMT {

    // MARK: - Manifest

    public struct Manifest: Codable, Sendable, Equatable {
        public var name: String
        public var wineVersion: String
        public var dxmtVersion: String
        public var monoVersion: String?
        public var builtAt: String?
        public var files: [String: String]?   // path relativo → sha256

        public init(name: String, wineVersion: String, dxmtVersion: String,
                    monoVersion: String? = nil, builtAt: String? = nil,
                    files: [String: String]? = nil) {
            self.name = name
            self.wineVersion = wineVersion
            self.dxmtVersion = dxmtVersion
            self.monoVersion = monoVersion
            self.builtAt = builtAt
            self.files = files
        }
    }

    // MARK: - Info

    public struct Info: Sendable, Equatable {
        public let root: URL
        public let name: String
        public let wineBinary: String
        public let wineRoot: URL          // installazione Wine (lib/wine, share/wine)
        public let rendererRoot: URL      // renderer DXMT (WINEDLLPATH_PREPEND)
        public let x64Deps: URL           // dylib di supporto (DYLD_LIBRARY_PATH)
        public let manifest: Manifest?

        public var wineVersion: String { manifest?.wineVersion ?? "unknown" }
        public var dxmtVersion: String { manifest?.dxmtVersion ?? "unknown" }
        public var monoVersion: String? { manifest?.monoVersion }

        public var summary: String {
            "Game-X Wine+DXMT — \(wineVersion) / DXMT \(dxmtVersion)"
        }

        /// Tutti i pezzi indispensabili ci sono?
        public var isUsable: Bool {
            FileManager.default.isExecutableFile(atPath: wineBinary)
                && FileManager.default.fileExists(atPath:
                    rendererRoot.appendingPathComponent("x86_64-windows/d3d11.dll").path)
                && FileManager.default.fileExists(atPath:
                    rendererRoot.appendingPathComponent("x86_64-unix/winemetal.so").path)
        }

        /// Il MSI di wine-mono (se presente nel runtime).
        public func monoMSI() -> URL? {
            let dir = wineRoot.appendingPathComponent("share/wine/mono")
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { return nil }
            return items.first { $0.lastPathComponent.hasPrefix("wine-mono-") && $0.pathExtension == "msi" }
        }
    }

    // MARK: - Percorsi

    public static let defaultName = "wine-dxmt"

    /// Cartella dei runtime gestiti da Game-X
    /// (`~/Library/Application Support/game-x/runtimes`).
    public static func runtimesRoot(config: Config) -> URL {
        URL(fileURLWithPath: (config.gamesRoot as NSString).expandingTildeInPath)
            .deletingLastPathComponent()
            .appendingPathComponent("runtimes")
    }

    /// Cerca tutti i runtime DXMT installati.
    public static func list(config: Config) -> [Info] {
        let root = runtimesRoot(config: config)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        return items.compactMap { discover(root: $0) }.sorted { $0.name < $1.name }
    }

    /// Riconosce un runtime DXMT dalla sua cartella.
    public static func discover(root: URL) -> Info? {
        let fm = FileManager.default

        // 1. installazione Wine: <root>/wine oppure <root> stesso
        let candidates: [URL] = [
            root.appendingPathComponent("wine"), root
        ]
        var wineRoot: URL?
        var wineBinary: String?
        for base in candidates {
            let bin = base.appendingPathComponent("bin/wine")
            if fm.isExecutableFile(atPath: bin.path) {
                wineRoot = base
                wineBinary = bin.path
                break
            }
        }
        guard let wineRoot, let wineBinary else { return nil }

        // 2. renderer DXMT
        let renderer = root.appendingPathComponent("renderers/dxmt/wine")
        guard fm.fileExists(atPath: renderer.appendingPathComponent("x86_64-windows/d3d11.dll").path)
        else { return nil }

        // 3. dylib di supporto (opzionale: alcune build ne fanno a meno)
        let deps = root.appendingPathComponent("x64deps")

        // 4. manifest (opzionale)
        var manifest: Manifest?
        let manifestURL = root.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL) {
            manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        }

        return Info(
            root: root,
            name: root.lastPathComponent,
            wineBinary: wineBinary,
            wineRoot: wineRoot,
            rendererRoot: renderer,
            x64Deps: deps,
            manifest: manifest
        )
    }

    // MARK: - Ambiente di lancio

    /// Variabili d'ambiente necessarie perché Wine carichi DXMT e trovi le dylib.
    ///
    /// - `WINEDLLPATH_PREPEND`: DXMT viene servito come "builtin" (le DLL hanno
    ///   lo stesso nome di quelle di Wine e vengono cercate prima).
    /// - `WINEDLLOVERRIDES`: forza i builtin (quindi DXMT) per d3d11/dxgi/ecc.
    /// - `DYLD_LIBRARY_PATH`: Wine fa `dlopen()` con **SONAME nudo**
    ///   (`libMoltenVK.dylib`, `libfreetype.dylib`…) → serve la cartella x64deps.
    public static func environment(for info: Info) -> [String: String] {
        var env: [String: String] = [:]
        env["WINEDLLPATH_PREPEND"] = info.rendererRoot.path
        env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,dxgi,winemetal=b"
        if FileManager.default.fileExists(atPath: info.x64Deps.path) {
            var path = info.x64Deps.path
            if let existing = ProcessInfo.processInfo.environment["DYLD_LIBRARY_PATH"], !existing.isEmpty {
                path += ":" + existing
            }
            env["DYLD_LIBRARY_PATH"] = path
        }
        env["DXMT_LOG_LEVEL"] = env["DXMT_LOG_LEVEL"] ?? "warn"
        env["MVK_CONFIG_LOG_LEVEL"] = "0"

        // Cache delle pipeline Metal compilate (LLVM JIT): senza, ogni avvio
        // ricompila tutti gli shader → caricamenti lentissimi e stutter.
        env["DXMT_SHADER_CACHE"] = env["DXMT_SHADER_CACHE"] ?? "1"
        let cacheDir = info.root.appendingPathComponent("cache/dxmt")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            env["DXMT_SHADER_CACHE_PATH"] = env["DXMT_SHADER_CACHE_PATH"] ?? cacheDir.path
        }
        return env
    }

    /// Crea i symlink `ntdll.so` / `winemac.so` accanto a `winemetal.so`:
    /// `winemetal.so` ha `LC_RPATH=@loader_path/` e su Wine installato
    /// `pre_exec()` non imposta `DYLD_LIBRARY_PATH`.
    ///
    /// IMPORTANTE: il symlink deve risolvere allo **stesso file** che Wine carica
    /// dal proprio `lib/wine/x86_64-unix` — altrimenti dyld carica due copie di
    /// `winemac.so` e le classi Objective-C duplicate fanno crashare i processi
    /// (errore `Class WineApplication is implemented in both …`).
    public static func ensureUnixLinks(_ info: Info) throws {
        let fm = FileManager.default
        let unix = info.rendererRoot.appendingPathComponent("x86_64-unix")
        let wineUnix = info.wineRoot.appendingPathComponent("lib/wine/x86_64-unix")
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        for name in ["ntdll.so", "winemac.so"] {
            let target = wineUnix.appendingPathComponent(name)
            guard fm.fileExists(atPath: target.path) else { continue }
            let link = unix.appendingPathComponent(name)
            // percorso “fisico” (senza symlink intermedi) → confronto affidabile
            let targetPath = target.resolvingSymlinksInPath().path
            let linkPath = link.resolvingSymlinksInPath().path
            if linkPath == targetPath { continue }
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: targetPath)
        }
    }

    // MARK: - Cache shader

    /// Stato della cache delle pipeline Metal (DXMT compila con LLVM alla
    /// prima esecuzione e salva il risultato qui).
    public struct ShaderCacheStatus: Sendable, Equatable {
        public let path: URL
        public let files: Int
        public let bytes: Int64
        /// Vero se non c'è ancora nulla: la prima esecuzione compilerà (lenta).
        public var isEmpty: Bool { bytes == 0 || files == 0 }
        public var human: String {
            isEmpty ? "empty (first run: DXMT will compile shaders)"
                    : "\(files) file, \(ByteFormat.human(bytes))"
        }
    }

    /// Cartella della cache shader di un runtime.
    public static func shaderCacheDir(for info: Info) -> URL {
        info.root.appendingPathComponent("cache/dxmt")
    }

    // MARK: - Warm-up (cache già compilata per un gioco?)

    /// Marcatore scritto quando un gioco è stato “riscaldato”: la prossima volta
    /// non c'è bisogno di ricompilare nulla prima di giocare.
    public static func warmupMarker(appid: String, for info: Info) -> URL {
        shaderCacheDir(for: info).appendingPathComponent(".warmed-\(appid)")
    }

    public static func isWarmed(appid: String, for info: Info) -> Bool {
        var isDir: ObjCBool = false
        let url = warmupMarker(appid: appid, for: info)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    }

    /// Segna il gioco come riscaldato, ricordando la dimensione della cache.
    public static func markWarmed(appid: String, for info: Info, bytes: Int64) {
        let dir = shaderCacheDir(for: info)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload = "appid=\(appid)\nbytes=\(bytes)\ndate=\(ISO8601DateFormatter().string(from: Date()))\n"
        try? payload.write(to: warmupMarker(appid: appid, for: info), atomically: true, encoding: .utf8)
    }

    /// La cache è cresciuta molto dopo il warm-up? (nuove aree = nuovi shader)
    public static func cacheGrewSinceWarmup(appid: String, for info: Info, tolerance: Int64 = 2_000_000) -> Bool {
        guard isWarmed(appid: appid, for: info),
              let text = try? String(contentsOf: warmupMarker(appid: appid, for: info), encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("bytes=") }),
              let recorded = Int64(line.dropFirst("bytes=".count)) else { return false }
        return shaderCacheStatus(for: info).bytes > recorded + tolerance
    }

    /// Misura la cache (dimensione e numero di file “shaders*.db”).
    public static func shaderCacheStatus(for info: Info) -> ShaderCacheStatus {
        let dir = shaderCacheDir(for: info)
        let fm = FileManager.default
        var files = 0
        var bytes: Int64 = 0
        if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for item in items {
                let name = item.lastPathComponent
                // la cache è un DB SQLite: contano db + wal (il -lock/-shm sono vuoti)
                guard name.hasPrefix("shaders") , name.hasSuffix(".db") || name.hasSuffix(".db-wal") else { continue }
                files += 1
                bytes += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return ShaderCacheStatus(path: dir, files: files, bytes: bytes)
    }

    /// Messaggio da mostrare PRIMA di avviare un gioco (una riga).
    public static func shaderCacheNotice(for info: Info) -> String {
        let s = shaderCacheStatus(for: info)
        if s.isEmpty {
            return "first run on this runtime: DXMT will compile shaders (the first scene may freeze for 1-3 minutes — that is not a hang)"
        }
        return "shader cache present (\(s.human)): what you already saw loads instantly; new shaders compile on first encounter (1-3 min the first time per area)"
    }

    // MARK: - wine-mono

    public static let monoDownloadURLPrefix = "https://dl.winehq.org/wine/wine-mono"

    /// wine-mono è installato nel prefix?
    public static func monoInstalled(in prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath:
            prefix.appendingPathComponent("drive_c/windows/mono/mono-2.0").path)
    }

    /// Scarica il MSI di wine-mono nella cartella del runtime.
    @discardableResult
    public static func downloadMono(version: String, into info: Info) throws -> URL {
        let dir = info.wineRoot.appendingPathComponent("share/wine/mono")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("wine-mono-\(version)-x86.msi")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        guard let url = URL(string: "\(monoDownloadURLPrefix)/\(version)/wine-mono-\(version)-x86.msi") else {
            throw DXMTError.badURL
        }
        Log.shared.info("download wine-mono \(version)…")
        let data = try Data(contentsOf: url)
        guard data.count > 1_000_000 else { throw DXMTError.downloadFailed(url.absoluteString, data.count) }
        try data.write(to: dest)
        Log.shared.info("wine-mono scaricato: \(ByteFormat.human(Int64(data.count)))")
        return dest
    }

    /// Installa wine-mono nel prefix (se non già presente).
    @discardableResult
    public static func ensureMono(
        info: Info, prefix: URL, version: String?, config: Config
    ) throws -> Bool {
        guard !monoInstalled(in: prefix) else { return false }
        let wanted = version ?? "11.1.0"

        var msi = info.monoMSI()
        if msi == nil {
            msi = try downloadMono(version: wanted, into: info)
        }
        guard let msi else { return false }

        try ensureUnixLinks(info)
        var env = Prefix.baseEnvironment(config: config, prefix: prefix)
        env.merge(environment(for: info)) { _, new in new }

        Log.shared.info("installing wine-mono into the prefix…")
        let result = try ProcessRunner.run(
            info.wineBinary, ["msiexec", "/i", msi.path, "/qn"], environment: env)
        guard result.success else { throw DXMTError.monoInstallFailed(result.exitCode) }
        return true
    }

    // MARK: - Installazione del runtime da archivio

    /// Installa un runtime da un archivio `.tar.xz`/`.tar.gz` (già scaricato),
    /// verificandone l'hash se fornito.
    @discardableResult
    public static func installArchive(
        _ archive: URL, name: String = defaultName, sha256: String?, config: Config
    ) throws -> Info {
        if let sha256 {
            let actual = try fileSHA256(archive)
            guard actual.lowercased() == sha256.lowercased() else {
                throw DXMTError.checksumMismatch(expected: sha256, actual: actual)
            }
        }
        let root = runtimesRoot(config: config)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            _ = try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        // bsdtar riconosce la compressione da solo.
        let result = try ProcessRunner.run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path])
        guard result.success else { throw DXMTError.extractFailed(result.exitCode) }

        // L'archivio può contenere una cartella radice singola: se il layout
        // non è riconosciuto direttamente, prova a scendere di un livello.
        if let info = discover(root: dest) { return info }
        if let items = try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if discover(root: item) != nil {
                    // sposta il contenuto al livello superiore
                    for child in (try? FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                        try? FileManager.default.moveItem(
                            at: child, to: dest.appendingPathComponent(child.lastPathComponent))
                    }
                    try? FileManager.default.removeItem(at: item)
                    break
                }
            }
        }
        guard let info = discover(root: dest) else { throw DXMTError.badLayout(dest.path) }
        return info
    }

    public static func fileSHA256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Errori

    public enum DXMTError: Error, LocalizedError {
        case badURL
        case downloadFailed(String, Int)
        case checksumMismatch(expected: String, actual: String)
        case extractFailed(Int32)
        case badLayout(String)
        case monoInstallFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .badURL: return "invalid wine-mono URL"
            case .downloadFailed(let url, let size):
                return "download fallito da \(url) (\(size) byte)"
            case .checksumMismatch(let e, let a): return "sha256 mismatch (expected \(e), got \(a))"
            case .extractFailed(let code): return "estrazione archivio fallita (exit \(code))"
            case .badLayout(let path): return "unrecognized runtime layout in \(path)"
            case .monoInstallFailed(let code): return "installazione wine-mono fallita (exit \(code))"
            }
        }
    }
}
