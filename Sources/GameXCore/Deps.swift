import Foundation

/// Dipendenze Windows installabili via winetricks (M2).
public enum Deps {

    public struct Verb: Sendable {
        public let name: String
        public let risk: Risk
        public let note: String
        /// DLL/file sentinella per rilevare l'installazione (best effort).
        public let sentinel: String?
    }

    public enum Risk: String, Sendable {
        case safe = "safe"
        case delicate = "delicate"
        case unsupported = "unsupported"
    }

    /// Known verbs with a risk note for GPTK/modern Wine.
    public static let known: [Verb] = [
        .init(name: "corefonts", risk: .safe,
              note: "Microsoft fonts (Arial, Times...); helps installers",
              sentinel: "drive_c/windows/Fonts/arial.ttf"),
        .init(name: "vcrun2022", risk: .safe,
              note: "Visual C++ runtime 2015-2022 (x86/x64)",
              sentinel: "drive_c/windows/system32/msvcp140.dll"),
        .init(name: "vcrun2019", risk: .safe,
              note: "Visual C++ runtime 2015-2019",
              sentinel: "drive_c/windows/system32/msvcp140.dll"),
        .init(name: "d3dcompiler_47", risk: .safe,
              note: "D3D shader compiler; some apps need it",
              sentinel: "drive_c/windows/system32/d3dcompiler_47.dll"),
        .init(name: "dotnet6", risk: .delicate,
              note: ".NET 6 runtime; prefer Wine Staging",
              sentinel: nil),
        .init(name: "dotnet48", risk: .delicate,
              note: ".NET 4.8 runtime; slow/fragile install",
              sentinel: nil),
        .init(name: "gdiplus", risk: .safe,
              note: "GDI+; sometimes needed by .NET/Unity apps",
              sentinel: "drive_c/windows/system32/gdiplus.dll"),
        .init(name: "dxvk", risk: .delicate,
              note: "DXVK latest: D3D9/10/11 -> Vulkan (needs Vulkan 1.3/BDA; FAILS on MoltenVK)",
              sentinel: nil),
        .init(name: "dxvk1103", risk: .delicate,
              note: "DXVK 1.10.3: D3D9/10/11 -> Vulkan 1.1 (works on MoltenVK; use for DX11 games)",
              sentinel: nil),
    ]

    public static func info(for name: String) -> Verb? {
        known.first { $0.name == name }
    }

    public enum DepsError: Error, CustomStringConvertible {
        case unknownVerb(String)
        case unsupportedVerb(String)
        case winetricksNotFound(String)
        case failed(Int32)

        public var description: String {
            switch self {
            case .unknownVerb(let v):
                return "unknown verb: '\(v)'. See `gx deps list`."
            case .unsupportedVerb(let v):
                return "verb '\(v)' is marked unsupported and won't be installed."
            case .winetricksNotFound(let p):
                return "winetricks not found: \(p)"
            case .failed(let code):
                return "winetricks exited with code \(code)"
            }
        }
    }

    /// Verifica i verb e rifiuta gli sconosciuti/unsupported.
    public static func validate(_ verbs: [String]) throws {
        for v in verbs {
            guard let info = info(for: v) else { throw DepsError.unknownVerb(v) }
            if info.risk == .unsupported { throw DepsError.unsupportedVerb(v) }
        }
    }

    /// Rileva i verb installati nel prefix interrogando `winetricks list-installed`.
    /// Più affidabile del controllo dei file (Wine fornisce molti DLL builtin,
    /// es. `msvcp140.dll`, che darebbero falsi positivi).
    public static func listInstalled(
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime
    ) -> Set<String> {
        guard FileManager.default.isExecutableFile(atPath: config.winetricks) else { return [] }
        var env = environment(prefix: prefix, config: config, runtime: runtime)
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        guard let result = try? ProcessRunner.run(
            config.winetricks, ["list-installed"], environment: env) else { return [] }

        let lines = (result.stdout + "\n" + result.stderr)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasPrefix("#") && $0 != "-" }
        return Set(lines)
    }

    /// Rilevamento rapido basato su file sentinella (fallback, soggetto a falsi positivi).
    public static func detectBySentinel(in prefix: PrefixRecord) -> [String] {
        known.compactMap { verb in
            guard let sentinel = verb.sentinel else { return nil }
            let url = prefix.url.appendingPathComponent(sentinel)
            return FileManager.default.fileExists(atPath: url.path) ? verb.name : nil
        }
    }

    /// Costruisce l'ambiente per winetricks puntato al runtime del prefix.
    static func environment(prefix: PrefixRecord, config: Config, runtime: ResolvedRuntime) -> [String: String] {
        var env = Prefix.baseEnvironment(config: config, prefix: prefix.url, runtime: runtime)
        env["WINE"] = runtime.wineBinary
        return env
    }

    /// Comando winetricks che verrebbe eseguito (per --dry-run / log).
    public static func command(verbs: [String], remove: Bool = false) -> [String] {
        remove ? ["-q", "--uninstall"] + verbs : ["-q"] + verbs
    }

    @discardableResult
    public static func install(
        verbs: [String],
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        dryRun: Bool = false
    ) throws -> Int32 {
        try validate(verbs)
        return try run(verbs: verbs, remove: false, prefix: prefix,
                       config: config, runtime: runtime, dryRun: dryRun)
    }

    @discardableResult
    public static func remove(
        verbs: [String],
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        dryRun: Bool = false
    ) throws -> Int32 {
        try validate(verbs)
        return try run(verbs: verbs, remove: true, prefix: prefix,
                       config: config, runtime: runtime, dryRun: dryRun)
    }

    private static func run(
        verbs: [String],
        remove: Bool,
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        dryRun: Bool
    ) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: config.winetricks) else {
            throw DepsError.winetricksNotFound(config.winetricks)
        }

        let args = command(verbs: verbs, remove: remove)
        let env = environment(prefix: prefix, config: config, runtime: runtime)

        Log.shared.info("winetricks \(args.joined(separator: " ")) [prefix \(prefix.name)]")

        if dryRun {
            Log.shared.info("(dry-run) WINE=\(runtime.wineBinary) WINEPREFIX=\(prefix.url.path)")
            return 0
        }

        // Log dedicato per l'operazione.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = config.resolvedPaths().logsRoot
            .appendingPathComponent("deps/\(prefix.name)-\(stamp).log")

        return try ProcessRunner.runStreaming(
            config.winetricks, args, environment: env, logFile: logFile)
    }
}
