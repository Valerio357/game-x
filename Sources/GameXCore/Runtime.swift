import Foundation

/// Runtime Wine risolto: percorso, versione, capacità.
public struct ResolvedRuntime: Sendable {
    public enum Kind: String, Sendable {
        case dxmtWine = "Game-X Wine+DXMT"
        case gptkWine = "GPTK"
        case wineStaging = "Wine Staging"
        case homebrew = "Homebrew Wine"
        case custom = "custom"
    }

    public let kind: Kind
    public let wineBinary: String
    public let version: String            // es. "wine-11.10"
    public let wineMajor: Int?            // es. 11
    public let gptkApp: String?
    public let hasD3DMetal: Bool
    public let rosettaAvailable: Bool
    /// Cartella del runtime Game-X Wine+DXMT (nil per i runtime di sistema).
    public let runtimeRoot: String?

    public init(
        kind: Kind,
        wineBinary: String,
        version: String,
        wineMajor: Int?,
        gptkApp: String?,
        hasD3DMetal: Bool,
        rosettaAvailable: Bool,
        runtimeRoot: String? = nil
    ) {
        self.kind = kind
        self.wineBinary = wineBinary
        self.version = version
        self.wineMajor = wineMajor
        self.gptkApp = gptkApp
        self.hasD3DMetal = hasD3DMetal
        self.rosettaAvailable = rosettaAvailable
        self.runtimeRoot = runtimeRoot
    }

    /// Dettagli del runtime DXMT (se questo runtime è un Game-X Wine+DXMT).
    public var dxmt: DXMT.Info? {
        guard kind == .dxmtWine, let runtimeRoot else { return nil }
        return DXMT.discover(root: URL(fileURLWithPath: runtimeRoot))
    }

    /// Dettagli del runtime D3DMetal (se questo runtime è un Game-X Wine+D3DMetal).
    public var d3dmetal: D3DMetal.Info? {
        guard let runtimeRoot else { return nil }
        return D3DMetal.discover(root: URL(fileURLWithPath: runtimeRoot))
    }

    /// La UI Steam richiede un Wine moderno (vedi DESIGN §11.4).
    public var supportsModernSteam: Bool { (wineMajor ?? 0) >= 8 }

    public var summary: String {
        if let d3dm = d3dmetal {
            let folder = runtimeRoot.map { " [" + URL(fileURLWithPath: $0).lastPathComponent + "]" } ?? ""
            return "Game-X Wine+D3DMetal — \(version) / D3DMetal \(d3dm.d3dmetalVersion)\(folder)"
        }
        if let dx = dxmt {
            return "Game-X Wine+DXMT — \(dx.wineVersion) [DXMT \(dx.dxmtVersion)]"
        }
        return "\(kind.rawValue) — \(version)" + (gptkApp != nil ? " (\(gptkApp!))" : "")
    }
}

/// Voce selezionabile nella UI/CLI per il runtime di un box.
public struct RuntimeChoice: Sendable, Identifiable, Hashable {
    /// Selettore accettato da `Runtime.select` (nome cartella del runtime,
    /// oppure `dxmt`/`gptk`/`staging`/`homebrew` per quelli di sistema).
    public let id: String
    public let label: String
    /// Etichetta breve del motore (per la UI).
    public let engine: String
}

/// Discovery dei runtime disponibili.
public enum Runtime {

    /// Scelte per creare un box. L'unico runtime supportato è **wine-gptk**
    /// (Wine+D3DMetal). Se non è installato mostriamo comunque una voce guida,
    /// così l'utente sa cosa fare (niente DXMT/Staging/GPTK/Homebrew nel picker).
    public static func choices(config: Config) -> [RuntimeChoice] {
        let gptk = d3dmetalRuntimes(config: config).map { rt -> RuntimeChoice in
            let folder = rt.runtimeRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? D3DMetal.defaultName
            return RuntimeChoice(id: folder,
                                 label: "Wine+D3DMetal (Apple GPTK)  \(folder)",
                                 engine: "Wine+D3DMetal")
        }
        if !gptk.isEmpty { return gptk }
        return [RuntimeChoice(id: D3DMetal.defaultName,
                              label: "Wine+D3DMetal — not installed (run `gx runtime build-gptk`)",
                              engine: "Wine+D3DMetal")]
    }


    /// Risolve il runtime da usare secondo la precedenza:
    /// override esplicito → **wine-gptk (D3DMetal, default)** → DXMT → GPTK → Staging → Homebrew.
    public static func resolve(config: Config) -> ResolvedRuntime? {
        if let override = config.resolvedPaths().wineBinaryOverride,
           FileManager.default.isExecutableFile(atPath: override) {
            let version = ProcessRunner.firstLine(override, ["--version"]) ?? "unknown"
            return ResolvedRuntime(
                kind: kind(forBinary: override, config: config) ?? .custom,
                wineBinary: override, version: version,
                wineMajor: parseMajor(from: version), gptkApp: nil,
                hasD3DMetal: false, rosettaAvailable: rosettaAvailable(),
                runtimeRoot: DXMT.list(config: config)
                    .first { $0.wineBinary == override }?.root.path)
        }

        // 1. Game-X Wine + D3DMetal (`wine-gptk`): **default supportato** (vedi UX.md).
        if let d3dm = d3dmetalRuntimes(config: config).first {
            return d3dm
        }
        // 2. Game-X Wine + DXMT (ripiego open source).
        if let dxmt = dxmtRuntimes(config: config).first {
            return dxmt
        }

        var candidates: [(ResolvedRuntime.Kind, String, String?)] = []
        candidates.append((.gptkWine, DefaultPaths.gptkWineBinary, config.gptkApp))
        candidates.append((.wineStaging, DefaultPaths.wineStagingBinary, nil))
        candidates.append((.homebrew, DefaultPaths.homebrewWine, nil))

        for (kind, binary, gptkApp) in candidates {
            guard FileManager.default.isExecutableFile(atPath: binary) else { continue }
            let version = ProcessRunner.firstLine(binary, ["--version"]) ?? "unknown"
            return ResolvedRuntime(
                kind: kind,
                wineBinary: binary,
                version: version,
                wineMajor: parseMajor(from: version),
                gptkApp: gptkApp,
                hasD3DMetal: gptkApp.map(detectD3DMetal) ?? false,
                rosettaAvailable: rosettaAvailable()
            )
        }
        return nil
    }

    /// Elenca tutti i runtime trovati (wine-gptk/D3DMetal per primo: è il default).
    public static func list(config: Config) -> [ResolvedRuntime] {
        var result: [ResolvedRuntime] = d3dmetalRuntimes(config: config)
        result.append(contentsOf: dxmtRuntimes(config: config))
        let candidates: [(ResolvedRuntime.Kind, String, String?)] = [
            (.gptkWine, DefaultPaths.gptkWineBinary, config.gptkApp),
            (.wineStaging, DefaultPaths.wineStagingBinary, nil),
            (.homebrew, DefaultPaths.homebrewWine, nil),
        ]
        for (kind, binary, gptkApp) in candidates where FileManager.default.isExecutableFile(atPath: binary) {
            let version = ProcessRunner.firstLine(binary, ["--version"]) ?? "unknown"
            result.append(ResolvedRuntime(
                kind: kind, wineBinary: binary, version: version,
                wineMajor: parseMajor(from: version), gptkApp: gptkApp,
                hasD3DMetal: gptkApp.map(detectD3DMetal) ?? false,
                rosettaAvailable: rosettaAvailable()))
        }
        return result
    }

    /// Runtime consigliato per la UI Steam: preferisce Wine >= 8 (DESIGN §11.4).
    /// Se nessun runtime moderno è disponibile, ricade su `resolve`.
    public static func resolveForSteam(config: Config) -> ResolvedRuntime? {
        let modern = list(config: config).first { ($0.wineMajor ?? 0) >= 8 }
        return modern ?? resolve(config: config)
    }

    /// Seleziona un runtime per nome (`gptk`, `staging`, `homebrew`) oppure
    /// per path esplicito. Usato da `gx prefix create --runtime`.
    public static func select(_ name: String?, config: Config) -> ResolvedRuntime? {
        select(name, config: config, knownRuntimes: nil)
    }

    /// Variante con lista di runtime già risolta (evita di rilanciare
    /// `wine --version` quando si itera su più prefix).
    public static func select(_ name: String?, config: Config,
                             knownRuntimes: [ResolvedRuntime]?) -> ResolvedRuntime? {
        guard let name, !name.isEmpty else { return resolve(config: config) }
        let known = knownRuntimes ?? list(config: config)

        switch name.lowercased() {
        case "dxmt", "wine-dxmt", "gamex", "game-x":
            return known.first { $0.kind == .dxmtWine }
        case "gptk":
            return known.first { $0.kind == .gptkWine }
        case "staging", "wine-staging", "wine_staging":
            return known.first { $0.kind == .wineStaging }
        case "homebrew":
            return known.first { $0.kind == .homebrew }
        default:
            // nome della cartella del runtime (es. "wine-dxmt", "wine-dxmt-reloc")
            if let match = known.first(where: {
                guard let root = $0.runtimeRoot else { return false }
                return URL(fileURLWithPath: root).lastPathComponent == name
            }) {
                return match
            }
            // path esplicito: se corrisponde a un runtime noto, mantieni il kind
            if let match = known.first(where: { $0.wineBinary == name }) {
                return match
            }
            guard FileManager.default.isExecutableFile(atPath: name) else { return nil }
            let version = ProcessRunner.firstLine(name, ["--version"]) ?? "unknown"
            return ResolvedRuntime(
                kind: .custom, wineBinary: name, version: version,
                wineMajor: parseMajor(from: version), gptkApp: nil,
                hasD3DMetal: false, rosettaAvailable: rosettaAvailable())
        }
    }

    /// Runtime da usare per un prefix: quello registrato nei metadati
    /// (se il binario esiste ancora), altrimenti la risoluzione globale.
    public static func forPrefix(_ prefix: PrefixRecord, config: Config) -> ResolvedRuntime? {
        forPrefix(prefix, config: config, knownRuntimes: nil)
    }

    /// Variante con lista runtime già risolta (per evitare spawn ripetuti).
    public static func forPrefix(_ prefix: PrefixRecord, config: Config,
                                 knownRuntimes: [ResolvedRuntime]?) -> ResolvedRuntime? {
        if let meta = prefix.loadMeta(), let binary = meta.wineBinary,
           FileManager.default.isExecutableFile(atPath: binary) {
            return select(binary, config: config, knownRuntimes: knownRuntimes)
        }
        return resolve(config: config)
    }

    /// Runtime DXMT installati (da `<runtimes>/…`).
    public static func dxmtRuntimes(config: Config) -> [ResolvedRuntime] {
        DXMT.list(config: config).compactMap { info in
            guard info.isUsable else { return nil }
            let version = ProcessRunner.firstLine(info.wineBinary, ["--version"])
                ?? info.wineVersion
            return ResolvedRuntime(
                kind: .dxmtWine,
                wineBinary: info.wineBinary,
                version: version,
                wineMajor: parseMajor(from: version),
                gptkApp: nil,
                hasD3DMetal: false,
                rosettaAvailable: rosettaAvailable(),
                runtimeRoot: info.root.path)
        }
    }

    /// Runtime D3DMetal installati (da `<runtimes>/…`).
    /// Vengono esposti con `kind = .gptkWine` + `hasD3DMetal = true` (stessa
    /// semantica dei runtime GPTK di sistema, ma il binario è il nostro).
    public static func d3dmetalRuntimes(config: Config) -> [ResolvedRuntime] {
        D3DMetal.list(config: config).compactMap { info in
            guard info.isUsable else { return nil }
            let version = ProcessRunner.firstLine(info.wineBinary, ["--version"]) ?? info.wineVersion
            return ResolvedRuntime(
                kind: .gptkWine,
                wineBinary: info.wineBinary,
                version: version,
                wineMajor: parseMajor(from: version),
                gptkApp: nil,
                hasD3DMetal: true,
                rosettaAvailable: rosettaAvailable(),
                runtimeRoot: info.root.path)
        }
    }

    /// Determina il kind di un binario wine arbitrario confrontandolo coi runtime noti.
    static func kind(forBinary binary: String, config: Config) -> ResolvedRuntime.Kind? {
        if dxmtRuntimes(config: config).contains(where: { $0.wineBinary == binary }) {
            return .dxmtWine
        }
        if d3dmetalRuntimes(config: config).contains(where: { $0.wineBinary == binary }) {
            return .gptkWine
        }
        if binary == DefaultPaths.gptkWineBinary { return .gptkWine }
        if binary == DefaultPaths.wineStagingBinary { return .wineStaging }
        if binary == DefaultPaths.homebrewWine { return .homebrew }
        return nil
    }

    /// Verifica la presenza di Rosetta 2.
    public static func rosettaAvailable() -> Bool {
        guard let r = try? ProcessRunner.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) else {
            return false
        }
        return r.success
    }

    /// Cerca il framework D3DMetal nel runtime GPTK.
    public static func detectD3DMetal(gptkApp: String) -> Bool {
        let fm = FileManager.default
        let roots = [
            "\(gptkApp)/Contents/Resources/wine/lib/external/D3DMetal.framework",
            "\(gptkApp)/Contents/Resources/wine/lib/external/libd3dshared.dylib",
        ]
        return roots.contains { fm.fileExists(atPath: $0) }
    }

    /// Estrae la major version da stringhe tipo "wine-11.10 (Staging)".
    public static func parseMajor(from version: String) -> Int? {
        // trova la prima sequenza numerica dopo un eventuale "wine-"
        let scalars = Array(version)
        var digits = ""
        var started = false
        for ch in scalars {
            if ch.isNumber {
                digits.append(ch); started = true
            } else if started {
                break
            }
        }
        return Int(digits)
    }
}
