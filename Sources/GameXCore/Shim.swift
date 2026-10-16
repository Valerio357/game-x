import Foundation

/// Installazione e verifica dello shim `steamwebhelper` (fix Wine bug #60263).
///
/// Vedi DESIGN §11. Lo shim inietta `--no-sandbox --disable-gpu --single-process`.
///
/// **Niente `chflags uchg`**: bloccare il file impediva a Steam di applicare gli
/// aggiornamenti (`failed to rename ... error 5` → fatal error). Lo shim viene
/// invece riconosciuto tramite un marker nel binario e reinstallato quando Steam
/// lo sovrascrive con un aggiornamento.
public enum Shim {

    public enum Arch: String, Sendable {
        case x86_64
        case i386

        public var outputName: String {
            self == .x86_64 ? "steamwebhelper_shim_x64.exe" : "steamwebhelper_shim_x86.exe"
        }
    }

    public enum ShimError: Error, CustomStringConvertible {
        case sourceMissing
        case compilerMissing(String)
        case buildFailed(Arch, Int32, String)
        case steamMissing

        public var description: String {
            switch self {
            case .sourceMissing: return "shim source not found in the bundle"
            case .compilerMissing(let c): return "mingw-w64 compiler not found (\(c)). Install: brew install mingw-w64"
            case .buildFailed(let arch, let code, let err):
                return "shim build \(arch.rawValue) failed (exit \(code)): \(err)"
            case .steamMissing: return "Steam is not installed in the box"
            }
        }
    }

    /// Stringa presente solo nel nostro shim.
    static let marker = "game-x-steamwebhelper-shim-v2"

    public static var sourceURL: URL? {
        BundledResources.shimSource
    }

    public static func compiler(for arch: Arch) -> String? {
        let name = arch == .x86_64 ? "x86_64-w64-mingw32-gcc" : "i686-w64-mingw32-gcc"
        return ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Compila lo shim (cache su mtime). Ritorna i binari per architettura.
    @discardableResult
    public static func build(config: Config, force: Bool = false) throws -> [Arch: URL] {
        guard let source = sourceURL else { throw ShimError.sourceMissing }
        let cache = config.resolvedPaths().cacheRoot.appendingPathComponent("shims")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let sourceDate = (try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date
        var result: [Arch: URL] = [:]

        for arch in [Arch.x86_64, .i386] {
            let output = cache.appendingPathComponent(arch.outputName)
            let outputDate = (try? FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate]) as? Date
            let fresh = !force && outputDate != nil && sourceDate != nil && outputDate! >= sourceDate!
            if fresh { result[arch] = output; continue }

            guard let cc = compiler(for: arch) else { throw ShimError.compilerMissing("\(arch.rawValue)") }
            let r = try ProcessRunner.run(cc, ["-O2", "-o", output.path, source.path])
            guard r.success else {
                throw ShimError.buildFailed(arch, r.exitCode, r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            result[arch] = output
        }
        return result
    }

    public static func cefDirectories(in prefix: PrefixRecord) -> [URL] {
        let base = prefix.driveC.appendingPathComponent("Program Files (x86)/Steam/bin/cef")
        return ["cef.win64", "cef.win7x64", "cef.win7"].compactMap { name in
            let url = base.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// `steamwebhelper.exe` corrente è il nostro shim (contiene il marker)?
    public static func isShim(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return data.range(of: Data(marker.utf8)) != nil
    }

    // MARK: - Lo stato dello shim, una sola fonte di verita'

    /// Esito della verifica dello shim su tutte le directory CEF.
    ///
    /// Casi del contratto:
    /// - `shimmed`: ogni `steamwebhelper.exe` porta il marker;
    /// - `real`: e' il file vero (marker assente);
    /// - `ambiguous`: `steamwebhelper.exe` e `steamwebhelper_real.exe` esistono e
    ///   sono **identici** ⇒ e' il file vero, non lo shim (caso che inganna un
    ///   check basato solo sull'esistenza del file);
    /// - `missingDirs`: nessuna directory CEF (Steam assente o non scompattato);
    /// - `missingExecutable`: la directory CEF esiste ma manca il webhelper.
    ///
    /// Usata **da tutti** i lettori (`gx steam status`, `gx dxmf doctor`): cosi'
    /// non possono divergere. `Status` porta anche le due dimensioni lette dal
    /// disco, perche' il messaggio sia verificabile da chi legge.
    public struct Status: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case shimmed
            case real
            case ambiguous
            case missingDirs
            case missingExecutable
        }

        /// Una directory CEF con le due dimensioni lette davvero dal disco.
        public struct Entry: Sendable, Equatable {
            public let directory: URL
            public let executable: URL
            public let executableSize: Int?
            public let executableIsShim: Bool
            public let real: URL
            public let realSize: Int?
            /// `steamwebhelper.exe` e `steamwebhelper_real.exe` sono byte-identici.
            public let identical: Bool
        }

        public let kind: Kind
        public let entries: [Entry]

        public init(kind: Kind, entries: [Entry]) {
            self.kind = kind
            self.entries = entries
        }

        public var isShimmed: Bool { kind == .shimmed }

        /// Dettaglio verificabile: nomina i due file e le **due dimensioni**.
        public var detail: String {
            switch kind {
            case .missingDirs:
                return "no CEF directory under the prefix"
            case .shimmed:
                let n = entries.filter { $0.executableIsShim }.count
                return "marker '\(Shim.marker)' in \(n) CEF dir(s)"
            case .ambiguous:
                return entries.filter { $0.identical }.map { entry in
                    "\(entry.executable.lastPathComponent) == \(entry.real.lastPathComponent) "
                        + "(\(Status.sizeText(entry.executableSize)) each) — "
                        + "this is the real helper, not the shim"
                }.joined(separator: "; ")
            case .real:
                return entries.map { entry in
                    "\(entry.directory.lastPathComponent): \(entry.executable.lastPathComponent) "
                        + "\(Status.sizeText(entry.executableSize))"
                        + (entry.realSize.map { ", \($0) B real" } ?? "")
                        + " — no marker"
                }.joined(separator: "; ")
            case .missingExecutable:
                return entries.map { entry in
                    "\(entry.directory.lastPathComponent): \(entry.executable.lastPathComponent) missing"
                }.joined(separator: "; ")
            }
        }

        public static func sizeText(_ size: Int?) -> String {
            guard let size else { return "?" }
            return ByteFormat.human(Int64(size))
        }
    }

    /// Stato dello shim: **una sola** funzione per doctor, `steam status` e
    /// `prefix info`. Riconosce il marker per contenuto; quando i due file
    /// esistono e hanno lo stesso contenuto lo dichiara (`ambiguous`), cosi' un
    /// file vero non viene mai scambiato per shim.
    public static func status(in prefix: PrefixRecord) -> Status {
        let fm = FileManager.default
        let dirs = cefDirectories(in: prefix)
        guard !dirs.isEmpty else { return Status(kind: .missingDirs, entries: []) }

        var entries: [Status.Entry] = []
        var kinds: [Status.Kind] = []
        for dir in dirs {
            let exe = dir.appendingPathComponent("steamwebhelper.exe")
            let real = dir.appendingPathComponent("steamwebhelper_real.exe")
            let exeSize = size(of: exe)
            let realSize = size(of: real)
            let exeIsShim = exeSize != nil && isShim(exe)
            let identical: Bool
            if exeSize != nil, realSize != nil, !exeIsShim,
               fm.contentsEqual(atPath: exe.path, andPath: real.path) {
                identical = true
            } else {
                identical = false
            }
            entries.append(Status.Entry(
                directory: dir, executable: exe, executableSize: exeSize,
                executableIsShim: exeIsShim, real: real, realSize: realSize,
                identical: identical))
            if exeIsShim { kinds.append(.shimmed) }
            else if identical { kinds.append(.ambiguous) }
            else if exeSize != nil { kinds.append(.real) }
            else { kinds.append(.missingExecutable) }
        }

        let kind: Status.Kind
        if kinds.allSatisfy({ $0 == .shimmed }) { kind = .shimmed }
        else if kinds.contains(.ambiguous) { kind = .ambiguous }
        else if kinds.contains(.real) { kind = .real }
        else if kinds.contains(.missingExecutable) { kind = .missingExecutable }
        else { kind = .real }
        return Status(kind: kind, entries: entries)
    }

    private static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    /// Shimmato su tutte le directory CEF? Delega a `status(in:)`: nessuna
    /// seconda logica di verifica puo' divergere da questa.
    public static func isInstalled(in prefix: PrefixRecord) -> Bool {
        status(in: prefix).isShimmed
    }

    /// Rimuove un eventuale lock `uchg` lasciato dalle versioni precedenti.
    public static func clearLock(_ url: URL) {
        _ = try? ProcessRunner.run("/usr/bin/chflags", ["nouchg", url.path])
    }

    /// Sblocca tutti i file shim del prefix (fix one-shot per i prefix con vecchio uchg).
    public static func clearLocks(in prefix: PrefixRecord) {
        for dir in cefDirectories(in: prefix) {
            clearLock(dir.appendingPathComponent("steamwebhelper.exe"))
            clearLock(dir.appendingPathComponent("steamwebhelper_real.exe"))
        }
    }

    /// Reinstalla lo shim in tutte le directory CEF (idempotente, aggiorna il real).
    public static func install(in prefix: PrefixRecord, builtShims: [Arch: URL]) throws {
        guard prefix.hasSteam else { throw ShimError.steamMissing }
        let fm = FileManager.default

        for dir in cefDirectories(in: prefix) {
            let target = dir.appendingPathComponent("steamwebhelper.exe")
            let real = dir.appendingPathComponent("steamwebhelper_real.exe")
            clearLock(target)
            clearLock(real)

            if isShim(target) {
                // già il nostro shim: assicura solo che il real esista
                if !fm.fileExists(atPath: real.path) {
                    Log.shared.warn("shim presente ma steamwebhelper_real.exe mancante in \(dir.path)")
                }
            } else if fm.fileExists(atPath: target.path) {
                // target è il webhelper reale (nuovo o aggiornato): salvalo come real
                if fm.fileExists(atPath: real.path) { try? fm.removeItem(at: real) }
                try fm.moveItem(at: target, to: real)
            }

            let arch: Arch = dir.lastPathComponent == "cef.win7" ? .i386 : .x86_64
            guard let shim = builtShims[arch] else { continue }
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            try fm.copyItem(at: shim, to: target)
            Log.shared.debug("shim installed in \(dir.path)")
        }
    }

    /// Compila (se serve) e installa lo shim se manca o è stato sovrascritto.
    @discardableResult
    public static func ensureInstalled(
        in prefix: PrefixRecord,
        config: Config,
        force: Bool = false
    ) throws -> [Arch: URL] {
        let built = try build(config: config, force: force)
        if force || !isInstalled(in: prefix) {
            try install(in: prefix, builtShims: built)
        }
        return built
    }
}
