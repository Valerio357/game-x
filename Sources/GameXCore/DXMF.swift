import Foundation

/// Runtime **Game-X Wine + DXMF**: un host Wine (default `~/wine-d3dmetal`)
/// più lo *stage* dei moduli dxmf (`d3d11`, `dxgi`, …) con la **stessa**
/// versione. Il crossing PE↔unix (`WINE_UNIX_CALL`) è legato alla versione
/// dell'host: un host diverso non carica i moduli, quindi un runtime con
/// versioni disallineate è dichiarato inutilizzabile, mai provato.
///
/// Layout:
///
///     <runtimeRoot>/bin/wine                     (host)
///     <stage>/x86_64-windows/<module>.dll        (PE half)
///     <stage>/x86_64-unix/<module>.so            (unix half)
///     <stage/manifest.json>  oppure
///     <stage>/../wine-runtime.manifest           (pin dichiarato)
///
/// Il contratto d'ambiente (WINEDLLPATH_PREPEND + WINEDLLOVERRIDES) è quello
/// provato in `dxmf/CRITICAL.md` (`DEC-137`).
public enum DXMF {

    // MARK: - Info

    public struct Info: Sendable, Equatable {
        public let wineBinary: String      // <runtimeRoot>/bin/wine
        public let runtimeRoot: URL        // ~/wine-d3dmetal
        public let wineVersion: String     // "wine-11.10"
        public let stageRoot: URL          // .../game-stage/wine (WINEDLLPATH_PREPEND)
        public let modules: [String]       // ["d3d11","dxgi"]
        public let pinnedVersion: String?  // dichiarata dallo stage/manifest, se c'è
        public let wineMajor: Int?
        /// File da cui viene il pin (per il messaggio di rifiuto). nil = default.
        public let pinSource: String?

        public init(
            wineBinary: String,
            runtimeRoot: URL,
            wineVersion: String,
            stageRoot: URL,
            modules: [String],
            pinnedVersion: String?,
            wineMajor: Int? = nil,
            pinSource: String? = nil
        ) {
            self.wineBinary = wineBinary
            self.runtimeRoot = runtimeRoot
            self.wineVersion = wineVersion
            self.stageRoot = stageRoot
            self.modules = modules
            self.pinnedVersion = pinnedVersion
            self.wineMajor = wineMajor ?? Runtime.parseMajor(from: wineVersion)
            self.pinSource = pinSource
        }

        /// Perché questo runtime non è utilizzabile (nil se lo è).
        /// Sempre nominato con il percorso esatto: mai `isUsable: false` muto.
        public var unusableReason: String? {
            let fm = FileManager.default
            if !fm.isExecutableFile(atPath: wineBinary) {
                return "host Wine not executable: \(wineBinary)"
            }
            if modules.isEmpty {
                return "no dxmf modules staged under \(stageRoot.path)"
            }
            for module in modules {
                let pe = stageRoot.appendingPathComponent("x86_64-windows/\(module).dll")
                let unix = stageRoot.appendingPathComponent("x86_64-unix/\(module).so")
                if !fm.fileExists(atPath: pe.path) {
                    return "module \(module) missing PE half: \(pe.path)"
                }
                if !fm.fileExists(atPath: unix.path) {
                    return "module \(module) missing unix half: \(unix.path)"
                }
            }
            if let mismatch = versionMismatch { return mismatch }
            return nil
        }

        /// Binario + PE + unix per ogni modulo, con la versione allineata.
        public var isUsable: Bool { unusableReason == nil }

        /// Versione host ≠ versione dei moduli ⇒ messaggio; nil se combaciano.
        /// Un host diverso non carica i moduli (ABI `WINE_UNIX_CALL` legata
        /// alla versione), quindi è un muro: si rifiuta per nome.
        public var versionMismatch: String? {
            let pin = pinnedVersion ?? DXMF.pinnedWineVersion
            let source = pinSource.map { " (pin from \($0))" }
                ?? " (pin default \(DXMF.pinnedWineVersion))"
            guard let host = DXMF.parseMajorMinor(from: wineVersion) else {
                return "host Wine version '\(wineVersion)' is not parseable; cannot confirm pinned \(pin)\(source)"
            }
            guard let pinned = DXMF.parseMajorMinor(from: pin) else {
                return "pinned Wine version '\(pin)' is not parseable\(source)"
            }
            if host.major == pinned.major && host.minor == pinned.minor { return nil }
            return "host Wine \(wineVersion) (major.minor \(host.major).\(host.minor)) does not match "
                + "pinned \(pin)\(source): the PE↔unix ABI (WINE_UNIX_CALL) is version-locked, "
                + "so these modules do not load on this host"
        }
    }

    // MARK: - Diagnostics

    /// Diagnostica dxmf (una chiusura pesante alla volta, regola della factory).
    public struct Diagnostics: Sendable, Equatable {
        public var quiet: Bool          // DXMF_DIAG_QUIET  (default: true)
        public var frameLog: URL?       // DXMF_FRAME_TIME
        public var lockDir: String?     // DXMF_LOCK_DIR
        public var gateLockWait: Int?   // DXMF_GATE_LOCK_WAIT

        public init(
            quiet: Bool = true,
            frameLog: URL? = nil,
            lockDir: String? = nil,
            gateLockWait: Int? = nil
        ) {
            self.quiet = quiet
            self.frameLog = frameLog
            self.lockDir = lockDir
            self.gateLockWait = gateLockWait
        }
    }

    // MARK: - Costanti

    /// La versione dichiarata dai moduli (`DXMF_WINE_PINNED_VERSION`).
    public static let pinnedWineVersion = "11.10"
    public static let defaultRuntimeRoot = "~/wine-d3dmetal"
    /// Override di base: i tre moduli storici, tutti builtin (`=b`).
    public static let overrideDefault = "d3d9,d3d11,dxgi=b"

    /// I moduli già coperti da `overrideDefault`: non si duplicano.
    static let baseOverrideModules: Set<String> = ["d3d9", "d3d11", "dxgi"]

    // MARK: - Discovery

    /// Host Wine + stage: il primo che risolve. `nil` = dxmf non installato.
    public static func discover(config: Config) -> Info? {
        let root = url(config.dxmfWineRoot)
        let stage = config.dxmfStage.isEmpty ? nil : url(config.dxmfStage)
        return discover(root: root, stageRoot: stage)
    }

    /// Variante senza `Config`: `stageRoot` esplicito, altrimenti lo stage di
    /// default. Usata da `ResolvedRuntime.dxmf`.
    public static func discover(root: URL, stageRoot: URL? = nil) -> Info? {
        let fm = FileManager.default
        let wine = root.appendingPathComponent("bin/wine")
        guard fm.isExecutableFile(atPath: wine.path) else { return nil }

        let stage: URL
        if let stageRoot {
            stage = stageRoot
        } else if let found = defaultStageRoot() {
            stage = found
        } else {
            return nil
        }

        let scanned = scanStage(root: stage)
        let wineVersion = hostWineVersion(binary: wine.path, root: root)
        return Info(
            wineBinary: wine.path,
            runtimeRoot: root,
            wineVersion: wineVersion,
            stageRoot: stage,
            modules: scanned.modules,
            pinnedVersion: scanned.pinned,
            wineMajor: Runtime.parseMajor(from: wineVersion),
            pinSource: scanned.pinSource
        )
    }

    /// Solo lo stage (senza host), per `gx dxmf status` e per la diagnostica.
    /// `nil` se lo stage non contiene almeno un modulo completo (PE + unix).
    public static func discoverStage(root: URL) -> (root: URL, modules: [String], pinned: String?)? {
        let scanned = scanStage(root: root)
        guard !scanned.modules.isEmpty else { return nil }
        return (root, scanned.modules, scanned.pinned)
    }

    /// Stage di default quando `config.dxmfStage` è vuoto:
    /// `~/Workspace/dxmf/build/game-stage/wine` se completo, altrimenti il più
    /// recente (per mtime) fra `~/Workspace/dxmf-*/build/game-stage/wine` che
    /// hanno almeno un modulo completo. Il percorso scelto è sempre quello
    /// esposto da `Info.stageRoot`: mai scelto in silenzio.
    public static func defaultStageRoot() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let explicit = home.appendingPathComponent("Workspace/dxmf/build/game-stage/wine")
        if !scanStage(root: explicit).modules.isEmpty { return explicit }

        let workspace = home.appendingPathComponent("Workspace")
        guard let items = try? fm.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else { return nil }

        var best: (url: URL, date: Date)?
        for item in items where item.lastPathComponent.hasPrefix("dxmf-") {
            let stage = item.appendingPathComponent("build/game-stage/wine")
            guard !scanStage(root: stage).modules.isEmpty else { continue }
            let date = (try? stage.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if best == nil || date > best!.date {
                best = (stage, date)
            }
        }
        return best?.url
    }

    /// Scansiona lo stage: i moduli sono la coppia di **path** (PE + unix),
    /// mai il solo nome.
    static func scanStage(root: URL) -> (modules: [String], pinned: String?, pinSource: String?) {
        let fm = FileManager.default
        let peDir = root.appendingPathComponent("x86_64-windows")
        let unixDir = root.appendingPathComponent("x86_64-unix")
        var modules: [String] = []
        if let files = try? fm.contentsOfDirectory(at: peDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "dll" {
                let name = file.deletingPathExtension().lastPathComponent
                if fm.fileExists(atPath: unixDir.appendingPathComponent("\(name).so").path) {
                    modules.append(name)
                }
            }
        }
        modules.sort()
        let (pinned, source) = pinnedVersion(alongside: root)
        return (modules, pinned, source)
    }

    /// Legge il pin dichiarato accanto allo stage. `manifest.json` (chiavi
    /// `wineVersion`/`wine`/`pinnedVersion`) vince sul default; per fedeltà al
    /// generatore reale (`scripts/stage-wine-runtime.sh`) si accetta anche
    /// `wine-runtime.manifest` (`pinned-wine-version=…`).
    static func pinnedVersion(alongside stage: URL) -> (String?, String?) {
        let bases = [stage, stage.deletingLastPathComponent()]
        for base in bases {
            let json = base.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: json),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                for key in ["wineVersion", "wine", "pinnedVersion"] {
                    if let value = object[key] as? String, !value.isEmpty {
                        return (value, json.path)
                    }
                }
            }
            let kv = base.appendingPathComponent("wine-runtime.manifest")
            if let text = try? String(contentsOf: kv, encoding: .utf8) {
                for rawLine in text.split(separator: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    if key == "pinned-wine-version" || key == "pinned-wine-release", !value.isEmpty {
                        return (value, kv.path)
                    }
                }
            }
        }
        return (nil, nil)
    }

    /// Versione dell'host: se accanto all'host c'è un manifest che la dichiara
    /// la si usa (così i test restano ermetici e non invocano Wine); altrimenti
    /// si misura con `wine --version`.
    static func hostWineVersion(binary: String, root: URL) -> String {
        let manifest = root.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifest),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["wineVersion", "wine", "pinnedVersion"] {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
        }
        return ProcessRunner.firstLine(binary, ["--version"]) ?? "unknown"
    }

    // MARK: - Ambiente

    /// Variabili d'ambiente del contratto d'ambiente. Sempre questi nomi.
    /// `extra` è applicato per ultimo e vince.
    public static func environment(
        for info: Info,
        diagnostics: Diagnostics,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env: [String: String] = [:]
        env["WINEDLLPATH_PREPEND"] = info.stageRoot.path

        var overrides = overrideDefault
        for module in info.modules where !baseOverrideModules.contains(module) {
            overrides += ",\(module)=b"
        }
        env["WINEDLLOVERRIDES"] = overrides

        if diagnostics.quiet { env["DXMF_DIAG_QUIET"] = "1" }
        if let frameLog = diagnostics.frameLog { env["DXMF_FRAME_TIME"] = frameLog.path }
        if let lockDir = diagnostics.lockDir, !lockDir.isEmpty { env["DXMF_LOCK_DIR"] = lockDir }
        if let wait = diagnostics.gateLockWait { env["DXMF_GATE_LOCK_WAIT"] = "\(wait)" }

        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Coppie (PE, unix) dei moduli presenti: la prova che i moduli sono i
    /// NOSTRI è il path, mai il nome.
    public static func moduleFiles(for info: Info) -> [(name: String, pe: URL, unix: URL)] {
        info.modules.map { module in
            (name: module,
             pe: info.stageRoot.appendingPathComponent("x86_64-windows/\(module).dll"),
             unix: info.stageRoot.appendingPathComponent("x86_64-unix/\(module).so"))
        }
    }

    // MARK: - Utility

    static func url(_ raw: String) -> URL {
        URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Estrae major/minor da "wine-11.10", "11.10", "wine-7.7 (Staging)"…
    static func parseMajorMinor(from version: String) -> (major: Int, minor: Int)? {
        let scalars = Array(version)
        var index = 0
        func readInt() -> Int? {
            var digits = ""
            while index < scalars.count, scalars[index].isNumber {
                digits.append(scalars[index])
                index += 1
            }
            return Int(digits)
        }
        while index < scalars.count, !scalars[index].isNumber { index += 1 }
        guard let major = readInt() else { return nil }
        guard index < scalars.count, scalars[index] == "." else { return nil }
        index += 1
        guard let minor = readInt() else { return nil }
        return (major, minor)
    }
}
