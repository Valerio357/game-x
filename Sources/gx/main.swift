import Foundation
import GameXCore

let version = "0.1.0"

// MARK: - Entry point

let rawArgs = Array(CommandLine.arguments.dropFirst())

// Global flags (may precede the command).
let globalFlags: Set<String> = ["-v", "--verbose", "--debug", "--quiet"]
let args = rawArgs.filter { !globalFlags.contains($0) }

func fail(_ error: CLIError) -> Never {
    FileHandle.standardError.write(Data("gx: \(error.description)\n".utf8))
    exit(error.exitCode.rawValue)
}

func loadContext() -> (Config, Paths) {
    let config = Config.resolve()
    var level = LogLevel(config.logLevel)
    let argv = CommandLine.arguments
    if argv.contains("--verbose") || argv.contains("-v") || argv.contains("--debug") { level = .debug }
    if argv.contains("--quiet") { level = .error }
    Log.shared.configure(level: level, logFile: Logs.commandLog(config: config),
                         verboseConsole: level == .debug)
    Log.shared.info("gx " + CommandLine.arguments.dropFirst().joined(separator: " "))
    return (config, config.resolvedPaths())
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        Out.print(text)
    } else {
        fail(.denied("JSON encoding failed"))
    }
}

// MARK: - Argument parsing

/// Splits positional args and flags (`--key value` or `--key`).
/// `--` terminates flag parsing; everything after is positional.
func splitArgs(_ args: [String]) -> (positional: [String], flags: [String: String]) {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            positional.append(contentsOf: args[(i + 1)...])
            break
        }
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                flags[key] = args[i + 1]
                i += 2
            } else {
                flags[key] = "true"
                i += 1
            }
        } else {
            positional.append(arg)
            i += 1
        }
    }
    return (positional, flags)
}

/// Like `splitArgs`, but also collects repeatable flags (`--arg`, `--env`).
func splitArgsFull(
    _ args: [String],
    repeatable: Set<String>
) -> (positional: [String], flags: [String: String], repeated: [String: [String]]) {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            positional.append(contentsOf: args[(i + 1)...])
            break
        }
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            let hasValue = i + 1 < args.count && !args[i + 1].hasPrefix("--")
            if repeatable.contains(key) {
                if hasValue {
                    repeated[key, default: []].append(args[i + 1])
                    i += 2
                } else {
                    repeated[key, default: []].append("true")
                    i += 1
                }
            } else if hasValue {
                flags[key] = args[i + 1]
                i += 2
            } else {
                flags[key] = "true"
                i += 1
            }
        } else {
            positional.append(arg)
            i += 1
        }
    }
    return (positional, flags, repeated)
}

func requireRuntime(_ config: Config) -> ResolvedRuntime {
    guard let rt = Runtime.resolve(config: config) else {
        fail(.runtimeNotFound("no Wine runtime found (install GPTK or Wine Staging, or set GX_WINE)"))
    }
    return rt
}

func requireSteamRuntime(_ config: Config) -> ResolvedRuntime {
    guard let rt = Runtime.resolveForSteam(config: config) else {
        fail(.runtimeNotFound("no Wine runtime found"))
    }
    return rt
}

/// Runtime of a box: metadata → override → global resolution.
func runtimeForPrefix(_ prefix: PrefixRecord, config: Config, override: String?) -> ResolvedRuntime {
    if let explicit = override, let rt = Runtime.select(explicit, config: config) { return rt }
    if let rt = Runtime.forPrefix(prefix, config: config) { return rt }
    return requireRuntime(config)
}

/// Runtime for Steam operations: override → box runtime (if modern) → Steam resolution.
func runtimeForSteam(_ prefix: PrefixRecord, config: Config, override: String?) -> ResolvedRuntime {
    if let explicit = override, let rt = Runtime.select(explicit, config: config) { return rt }
    if let rt = Runtime.forPrefix(prefix, config: config), rt.supportsModernSteam { return rt }
    return requireSteamRuntime(config)
}

func requirePrefix(_ name: String, _ paths: Paths) -> PrefixRecord {
    guard let prefix = Prefix.find(name, paths: paths) else {
        fail(.prefixNotFound("box '\(name)' not found in \(paths.prefixRoot.path)"))
    }
    return prefix
}

// MARK: - Dispatch

guard let command = args.first else {
    Help.printUsage()
    exit(ExitCode.ok.rawValue)
}

let rest = Array(args.dropFirst())

switch command {
case "version", "--version", "-V":
    Out.print("gx \(version)")

case "help", "--help", "-h":
    Help.printUsage()

case "info":
    cmdInfo(rest)

case "doctor":
    cmdDoctor(rest)

case "gpu":
    guard rest.first == "info" else { fail(.usage("usage: gx gpu info [--json]")) }
    cmdGPUInfo(Array(rest.dropFirst()))

case "runtime":
    cmdRuntime(rest)

case "prefix", "box":
    cmdPrefix(rest)

case "deps":
    cmdDeps(rest)

case "steam":
    cmdSteam(rest)

case "game":
    cmdGame(rest)

case "log":
    cmdLog(rest)

case "setup":
    cmdSetup(rest)

default:
    fail(.usage("unknown command: '\(command)'. Try `gx help`."))
}

// MARK: - Commands

func cmdInfo(_ args: [String] = []) {
    let (config, paths) = loadContext()
    let json = args.contains("--json")
    let rt = Runtime.resolve(config: config)
    let gpu = GPUInfo.detect()

    if json {
        let report = InfoReport(
            version: version,
            configFile: DefaultPaths.configFile.path,
            config: ConfigJSON(
                prefixRoot: paths.prefixRoot.path, gamesRoot: paths.gamesRoot.path,
                logsRoot: paths.logsRoot.path, gptkApp: paths.gptkApp.path,
                winetricks: config.winetricks, arch: config.arch,
                steamPrefix: config.defaultSteamPrefix),
            runtime: rt.map {
                RuntimeJSON(kind: $0.kind.rawValue, binary: $0.wineBinary, version: $0.version,
                            wineMajor: $0.wineMajor, d3dmetal: $0.hasD3DMetal,
                            rosetta: $0.rosettaAvailable, steamOK: $0.supportsModernSteam)
            },
            gpu: gpu)
        printJSON(report)
        return
    }

    Out.print(Out.bold("Game-X \(version)"))
    Out.print()
    Out.print(Out.bold("Configuration"))
    Out.field("config file", DefaultPaths.configFile.path)
    Out.field("boxes root", paths.prefixRoot.path)
    Out.field("games root", paths.gamesRoot.path)
    Out.field("logs root", paths.logsRoot.path)
    Out.field("gptk app", paths.gptkApp.path)
    Out.field("winetricks", config.winetricks)
    Out.field("arch", config.arch)
    Out.field("steam box", config.defaultSteamPrefix)
    Out.print()
    Out.print(Out.bold("Resolved runtime"))
    if let rt {
        Out.field("kind", rt.kind.rawValue)
        Out.field("binary", rt.wineBinary)
        Out.field("version", rt.version)
        Out.field("d3dmetal", rt.hasD3DMetal ? "yes" : "no")
        Out.field("rosetta", rt.rosettaAvailable ? "yes" : "no")
        Out.field("steam ready", rt.supportsModernSteam ? "yes" : "no (runtime too old)")
    } else {
        Out.print("  " + Out.yellow("no runtime found"))
    }
}

func cmdDoctor(_ args: [String] = []) {
    let (config, _) = loadContext()

    // --fix: installs the components that diagnostics reports as missing, then re-checks.
    if args.contains("--fix") {
        let missing = Setup.status(config: config).filter { !$0.installed }
        if missing.isEmpty {
            Out.print(Out.green("nothing to fix"))
        } else {
            Out.print(Out.bold("Installing \(missing.count) missing component(s)…"))
            let count = Setup.installMissing(config: config) { Out.print("  \($0)") }
            Out.print(Out.green("\(count) installed"))
        }
        Out.print()
    }

    let report = Doctor.run(config: config)
    if args.contains("--json") {
        printJSON(report)
        exit(report.hasFailures ? ExitCode.generic.rawValue : ExitCode.ok.rawValue)
    }
    Out.print(Out.bold("gx doctor"))
    Out.print()
    for check in report.checks {
        let tag: String
        switch check.status {
        case .ok: tag = Out.green("[ OK ]")
        case .warn: tag = Out.yellow("[WARN]")
        case .fail: tag = Out.red("[FAIL]")
        }
        var line = "  \(tag) \(check.title)"
        if let detail = check.detail { line += Out.dim(" — \(detail)") }
        Out.print(line)
        if let remedy = check.remedy {
            Out.print(Out.dim("         → \(remedy)"))
        }
    }
    let counts = report.counts
    Out.print()
    Out.print(Out.dim("  \(counts.ok) ok, \(counts.warn) warn, \(counts.fail) fail"))
    exit(report.hasFailures ? ExitCode.generic.rawValue : ExitCode.ok.rawValue)
}

func cmdGPUInfo(_ args: [String] = []) {
    let (config, _) = loadContext()
    let gpu = GPUInfo.detect()
    let gptkV = Runtime.resolve(config: config).flatMap { $0.kind == .gptkWine ? "GPTK \($0.version)" : nil }
    if args.contains("--json") {
        printJSON(GPUReport(gpu: gpu, metal4: gpu.metal4Verdict(gptkVersion: gptkV), maxMetal: gpu.maxMetal))
        return
    }
    Out.print(Out.bold("GPU / Metal"))
    Out.field("macOS", gpu.macOSVersion)
    Out.field("architecture", gpu.architecture)
    Out.field("chip", gpu.chip ?? "?")
    Out.field("GPU cores", gpu.gpuCores.map(String.init) ?? "?")
    Out.field("apple silicon", gpu.isAppleSilicon ? "yes" : "no")
    Out.field("max metal", gpu.maxMetal)
    Out.field("metal 4", gpu.metal4Verdict(gptkVersion: gptkV))
}

func cmdRuntimeList() {
    let (config, _) = loadContext()
    Out.print(Out.bold("Available Wine runtimes"))
    let runtimes = Runtime.list(config: config)
    if runtimes.isEmpty {
        Out.print("  " + Out.yellow("none"))
        return
    }
    for rt in runtimes {
        var badge = ""

        if let d3dm = rt.d3dmetal {
            badge = d3dm.isUsable ? " " + Out.green("(self-contained)") : " " + Out.yellow("(incomplete)")
        }
        if let dx = rt.dxmt, !dx.isUsable { badge += " " + Out.yellow("(incomplete)") }
        Out.print("  • \(rt.summary)\(badge)")
        Out.print(Out.dim("      \(rt.wineBinary)"))
        if let root = rt.runtimeRoot { Out.print(Out.dim("      runtime: \(root)")) }
    }
}

/// Riga di stato della cache shader (una per runtime).
func printShaderCache(_ info: DXMT.Info) {
    let s = DXMT.shaderCacheStatus(for: info)
    let value = s.isEmpty ? Out.yellow(s.human) : Out.green(s.human)
    Out.print("  shaders:   \(value)")
    Out.print(Out.dim("      \(s.path.path)"))
}

// MARK: - Runtime install / mono

func cmdRuntime(_ args: [String]) {
    guard let sub = args.first else {
        fail(.usage("usage: gx runtime <list|status|install|build-gptk|mono>"))
    }
    let rest = Array(args.dropFirst())
    let (pos, flags) = splitArgs(rest)

    switch sub {
    case "list", "ls":
        cmdRuntimeList()

    case "status":
        let (config, _) = loadContext()
        let infos = DXMT.list(config: config)
        guard !infos.isEmpty else {
            Out.print(Out.yellow("No Game-X Wine+DXMT runtime installed."))
            Out.print("Install it with: gx runtime install --from-source (or --tar FILE)")
            return
        }
        for info in infos {
            Out.print(Out.bold(info.name))
            Out.print("  wine:      \(info.wineBinary)")
            Out.print("  version:   \(info.wineVersion) / DXMT \(info.dxmtVersion)")
            Out.print("  renderer:  \(info.rendererRoot.path)")
            Out.print("  x64deps:   \(info.x64Deps.path)")
            Out.print("  mono MSI:  \(info.monoMSI()?.lastPathComponent ?? "—")")
            Out.print("  usable:    \(info.isUsable ? Out.green("yes") : Out.red("no"))")
            printShaderCache(info)
        }

    case "cache":
        let (config, _) = loadContext()
        let infos = DXMT.list(config: config)
        guard !infos.isEmpty else { fail(.runtimeNotFound("no Game-X Wine+DXMT runtime installed")) }
        for info in infos { printShaderCache(info) }

    case "install":
        cmdRuntimeInstall(pos: pos, flags: flags)

    case "build-gptk", "build-gptk-runtime":
        cmdRuntimeBuildGPTK(flags: flags)

    case "mono":
        let (config, _) = loadContext()
        guard let info = DXMT.list(config: config).first(where: { $0.isUsable }) else {
            fail(.runtimeNotFound("no Game-X Wine+DXMT runtime found — run `gx runtime install` first"))
        }
        var chosen: [PrefixRecord]
        if let name = flags["prefix"] {
            guard let record = Prefix.list(paths: config.resolvedPaths()).first(where: { $0.name == name }) else {
                fail(.runtimeNotFound("prefix '\(name)' not found"))
            }
            chosen = [record]
        } else {
            chosen = Prefix.list(paths: config.resolvedPaths())
        }
        for record in chosen {
            if DXMT.monoInstalled(in: record.url) {
                Out.print("  \(record.name): " + Out.green("wine-mono ok"))
                continue
            }
            Out.print("  \(record.name): installing wine-mono…")
            do {
                _ = try DXMT.ensureMono(info: info, prefix: record.url,
                                        version: info.monoVersion, config: config)
                Out.print("  \(record.name): " + Out.green("wine-mono installed"))
            } catch {
                Out.print("  \(record.name): " + Out.red("\(error.localizedDescription)"))
            }
        }

    default:
        fail(.usage("usage: gx runtime <list|status|install|build-gptk|mono>"))
    }
}

/// Costruisce il runtime **wine-gptk** (Wine dai sorgenti CodeWeavers + redist D3DMetal).
/// È l'operazione che prima si faceva a mano: ora è dentro il tool.
func cmdRuntimeBuildGPTK(flags: [String: String]) {
    // Script canonico: incluso nel bundle GameXCore (anche dentro GameX.app).
    // Fallback: checkout del repo da cui si sta eseguendo.
    let script = BundledResources.buildRuntimeScript
        ?? {
            let cwd = FileManager.default.currentDirectoryPath + "/scripts/build-runtime-gptk.sh"
            return FileManager.default.isExecutableFile(atPath: cwd) ? cwd : nil
        }()
    guard let script else {
        fail(.runtimeNotFound("build-runtime-gptk.sh not found (missing from the app bundle?)"))
    }

    let dryRun = flags["dry-run"] != nil
    var wineRoot = flags["wine-root"] ?? WineBase.defaultRoot

    // La base Wine (sorgenti CodeWeavers) è un artefatto grosso: se manca la scarichiamo
    // dal release (o la prendiamo da --wine-tar), poi innestiamo D3DMetal.
    if !dryRun, flags["wine-root"] == nil, !WineBase.isInstalled(root: wineRoot) {
        do {
            wineRoot = try WineBase.ensure(tar: flags["wine-tar"]) { Out.print("  " + $0) }
        } catch {
            fail(.runtimeNotFound("\(error.localizedDescription)\n  pass --wine-root <dir> or --wine-tar <file|url>"))
        }
    }

    var args = [script, "--wine-root", wineRoot]
    if let v = flags["gptk-dmg"] { args += ["--gptk-dmg", v] }
    if let v = flags["redist"] { args += ["--redist", v] }
    if let v = flags["name"] { args += ["--name", v] }
    if let v = flags["x64deps"] { args += ["--x64deps", v] }
    if dryRun { args.append("--dry-run") }
    Out.print("Building runtime wine-gptk (CodeWeavers Wine + Apple D3DMetal)…")
    if !dryRun {
        Out.print(Out.dim("  wine-root: \(wineRoot)"))
        Out.print(Out.dim("  D3DMetal : Apple Game Porting Toolkit 4 DMG (developer.apple.com)"))
    }
    do {
        let code = try ProcessRunner.runStreaming("/bin/bash", args)
        if code != 0 { fail(.runtimeNotFound("build failed (exit \(code))")) }
        if dryRun {
            Out.print(Out.dim("(dry-run) no changes made"))
            return
        }
        Out.print(Out.green("OK") + " runtime wine-gptk ready — check with `gx runtime list`")
        Out.print("  then: gx box create <name> --runtime wine-gptk")
    } catch {
        fail(.runtimeNotFound("build failed: \(error.localizedDescription)"))
    }
}

func cmdRuntimeInstall(pos: [String], flags: [String: String]) {
    let (config, _) = loadContext()
    let name = flags["name"] ?? (pos.first ?? DXMT.defaultName)

    var archive: URL?
    let sha = flags["sha256"]

    if let tar = flags["tar"] {
        archive = URL(fileURLWithPath: (tar as NSString).expandingTildeInPath)
    } else if let urlString = flags["url"] {
        guard let url = URL(string: urlString) else { fail(.usage("invalid --url")) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        Out.print("Downloading \(url.lastPathComponent)…")
        do {
            let data = try Data(contentsOf: url)
            try data.write(to: dest)
            Out.print("  \(ByteFormat.human(Int64(data.count)))")
        } catch {
            fail(.runtimeNotFound("download failed: \(error.localizedDescription)"))
        }
        archive = dest
    } else if let src = flags["from-local"] {
        let root = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
        guard let info = DXMT.discover(root: root) else {
            fail(.runtimeNotFound("no DXMT runtime layout in \(root.path)"))
        }
        try? DXMT.ensureUnixLinks(info)
        Out.print(Out.green("OK") + " runtime found: \(info.summary)")
        Out.print("  \(info.root.path)")
        return
    } else if flags["from-source"] != nil {
        let script = FileManager.default.currentDirectoryPath + "/scripts/build-wine-dxmt.sh"
        guard FileManager.default.isExecutableFile(atPath: script) else {
            fail(.runtimeNotFound("scripts/build-wine-dxmt.sh not found — run from the game-x checkout"))
        }
        Out.print("Building Game-X Wine+DXMT from source (this takes ~1 hour)…")
        do {
            let code = try ProcessRunner.runStreaming("/bin/bash", [script])
            if code != 0 { fail(.runtimeNotFound("build failed (exit \(code))")) }
        } catch {
            fail(.runtimeNotFound("build failed: \(error.localizedDescription)"))
        }
        return
    }

    guard let archive else {
        fail(.usage("usage: gx runtime install [--tar FILE | --url URL | --from-source] [--sha256 HASH] [--name NAME]"))
    }
    guard FileManager.default.fileExists(atPath: archive.path) else {
        fail(.runtimeNotFound("archive not found: \(archive.path)"))
    }

    Out.print("Installing runtime '\(name)'…")
    do {
        let info = try DXMT.installArchive(archive, name: name, sha256: sha, config: config)
        try? DXMT.ensureUnixLinks(info)
        Out.print(Out.green("OK") + " \(info.summary)")
        Out.print("  wine:     \(info.wineBinary)")
        Out.print("  renderer: \(info.rendererRoot.path)")
        if sha == nil, let hash = try? DXMT.fileSHA256(archive) {
            Out.print(Out.dim("  sha256:   \(hash)"))
        }
    } catch {
        fail(.runtimeNotFound("\(error.localizedDescription)"))
    }
}

func cmdPrefix(_ args: [String]) {
    let (config, paths) = loadContext()
    guard let sub = args.first else {
        fail(.usage("usage: gx box <list|create|info|remove|purge|exec|open|kill>"))
    }
    let rest = Array(args.dropFirst())
    let (pos, flags) = splitArgs(rest)

    switch sub {
    case "list", "ls":
        cmdPrefixList(paths: paths, showTrash: flags["trash"] != nil)

    case "create", "new":
        guard let name = pos.first else {
            fail(.usage("usage: gx box create <name> [--runtime staging|gptk|homebrew|<path>] [--force]"))
        }
        guard let rt = Runtime.select(flags["runtime"], config: config) else {
            fail(.runtimeNotFound("runtime '\(flags["runtime"] ?? "auto")' not found"))
        }
        do {
            let b = try Prefix.create(name, config: config, runtime: rt, force: flags["force"] != nil)
            Out.print(Out.green("box '\(b.name)' ready") + " → \(b.url.path)")
            Out.print(Out.dim("   runtime: \(rt.summary)"))
        } catch { fail(.denied("\(error)")) }

    case "info":
        guard let name = pos.first else { fail(.usage("usage: gx box info <name>")) }
        cmdPrefixInfo(requirePrefix(name, paths))

    case "remove", "rm":
        guard let name = pos.first else {
            fail(.usage("usage: gx box remove <name> --yes [--purge] [--runtime ...]"))
        }
        let b = requirePrefix(name, paths)
        guard flags["yes"] != nil else {
            fail(.usage("removing '\(name)' requires --yes (saves may be lost)"))
        }
        do {
            Prefix.kill(b, runtime: runtimeForPrefix(b, config: config, override: flags["runtime"]))
            if flags["purge"] != nil {
                try FileManager.default.removeItem(at: b.url)
                Out.print(Out.green("box '\(name)' deleted permanently"))
            } else {
                let destination = try Prefix.remove(b, paths: paths)
                Out.print(Out.green("box '\(name)' moved to internal trash"))
                Out.print(Out.dim("   \(destination.path)"))
                Out.print(Out.dim("   delete: gx box purge '\(destination.lastPathComponent)'"))
            }
        } catch { fail(.denied("\(error)")) }

    case "purge":
        let trash = paths.prefixRoot.appendingPathComponent(".trash")
        if flags["all"] != nil {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
                for item in items { try? Prefix.purge(trash.appendingPathComponent(item)) }
                Out.print(Out.green("\(items.count) items removed from trash"))
            }
        } else if let entry = pos.first {
            let url = trash.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: url.path) else {
                fail(.prefixNotFound("'\(entry)' is not in the trash"))
            }
            try? Prefix.purge(url)
            Out.print(Out.green("deleted '\(entry)'"))
        } else {
            fail(.usage("usage: gx box purge <entry> | --all"))
        }

    case "exec", "run":
        guard let name = pos.first else { fail(.usage("usage: gx box exec <name> -- <cmd...>")) }
        let b = requirePrefix(name, paths)
        let rt = runtimeForPrefix(b, config: config, override: flags["runtime"])
        var command = Array(pos.dropFirst())
        if command.first == "--" { command.removeFirst() }
        guard !command.isEmpty else { fail(.usage("no command to run")) }
        do {
            let result = try Prefix.exec(b, command: command, config: config, runtime: rt)
            if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
            if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
            exit(result.exitCode)
        } catch { fail(.denied("\(error)")) }

    case "open":
        guard let name = pos.first else { fail(.usage("usage: gx box open <name>")) }
        _ = try? ProcessRunner.run("/usr/bin/open", [requirePrefix(name, paths).driveC.path])

    case "kill":
        guard let name = pos.first else { fail(.usage("usage: gx box kill <name>")) }
        let b = requirePrefix(name, paths)
        Prefix.kill(b, runtime: runtimeForPrefix(b, config: config, override: flags["runtime"]))
        Out.print("wine processes stopped for '\(name)'")

    default:
        fail(.usage("unknown box subcommand: '\(sub)'"))
    }
}

func cmdPrefixList(paths: Paths, showTrash: Bool) {
    let prefixes = Prefix.list(paths: paths)
    if prefixes.isEmpty {
        Out.print("no boxes in \(paths.prefixRoot.path)")
    } else {
        Out.print(Out.bold("Boxes"))
        for b in prefixes {
            let meta = b.loadMeta()
            var tags: [String] = []
            if let meta { tags.append(meta.runtimeKind) }
            if b.hasSteam { tags.append(Out.green("+Steam")) }
            let size = ByteFormat.human(b.sizeBytes())
            let tagText = tags.isEmpty ? "" : Out.dim(" [") + tags.joined(separator: Out.dim(", ")) + Out.dim("]")
            Out.print("  \(b.name.padding(toLength: 22, withPad: " ", startingAt: 0))\(size.padding(toLength: 10, withPad: " ", startingAt: 0)) \(tagText)")
        }
    }

    if showTrash {
        let trash = paths.prefixRoot.appendingPathComponent(".trash")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: trash.path), !items.isEmpty {
            Out.print()
            Out.print(Out.bold("Internal trash"))
            for item in items.sorted() { Out.print("  \(item)") }
        }
    }
}

func cmdPrefixInfo(_ b: PrefixRecord) {
    Out.print(Out.bold("Box '\(b.name)'"))
    Out.field("path", b.url.path)
    Out.field("initialized", b.isInitialized ? "yes" : "no")
    Out.field("size", ByteFormat.human(b.sizeBytes()))
    Out.field("steam", b.hasSteam ? Out.green("yes") : "no")
    if let meta = b.loadMeta() {
        Out.field("runtime", "\(meta.runtimeKind) — \(meta.runtimeVersion)")
        Out.field("created", meta.createdAt)
        if let updated = meta.updatedAt { Out.field("updated", updated) }
        Out.field("kind", meta.kind)
    } else {
        Out.field("runtime", Out.dim("not recorded"))
    }
    if b.hasSteam {
        Out.field("shim", Shim.isInstalled(in: b) ? Out.green("yes") : Out.red("no"))
    }
}

func cmdDeps(_ args: [String]) {
    let (config, paths) = loadContext()
    guard let sub = args.first else { fail(.usage("usage: gx deps <list|status|install|remove>")) }
    let (pos, flags) = splitArgs(Array(args.dropFirst()))

    switch sub {
    case "list":
        Out.print(Out.bold("Known winetricks verbs"))
        for v in Deps.known {
            let tag = v.risk == .safe ? Out.green(v.risk.rawValue)
                : (v.risk == .delicate ? Out.yellow(v.risk.rawValue) : Out.red(v.risk.rawValue))
            Out.print("  \(v.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(tag)  \(Out.dim(v.note))")
        }

    case "status":
        guard let name = pos.first else { fail(.usage("usage: gx deps status <box>")) }
        let b = requirePrefix(name, paths)
        let rt = runtimeForPrefix(b, config: config, override: flags["runtime"])
        let installed = Deps.listInstalled(prefix: b, config: config, runtime: rt)
        Out.print(Out.bold("Dependencies detected in '\(name)'"))
        for v in Deps.known {
            if installed.contains(v.name) {
                Out.print("  \(v.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(Out.green("installed"))")
            } else {
                Out.print("  \(v.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(Out.dim("missing"))")
            }
        }

    case "install", "remove":
        guard pos.count >= 2 else { fail(.usage("usage: gx deps \(sub) <box> <verb...> [--dry-run]")) }
        let b = requirePrefix(pos[0], paths)
        let verbs = Array(pos.dropFirst())
        let rt = runtimeForPrefix(b, config: config, override: flags["runtime"])
        let dryRun = flags["dry-run"] != nil

        do {
            var toRun = verbs
            if sub == "install" {
                let installed = Deps.listInstalled(prefix: b, config: config, runtime: rt)
                let already = verbs.filter { installed.contains($0) }
                toRun = verbs.filter { !installed.contains($0) }
                if !already.isEmpty { Out.print(Out.dim("already installed: \(already.joined(separator: " "))")) }
                if toRun.isEmpty { Out.print(Out.green("nothing to do")); return }
            }

            if dryRun {
                let cmd = Deps.command(verbs: toRun, remove: sub == "remove")
                Out.print(Out.bold("dry-run"))
                Out.field("WINE", rt.wineBinary)
                Out.field("WINEPREFIX", b.url.path)
                Out.field("command", "\(config.winetricks) \(cmd.joined(separator: " "))")
                return
            }

            let code = sub == "install"
                ? try Deps.install(verbs: toRun, prefix: b, config: config, runtime: rt)
                : try Deps.remove(verbs: toRun, prefix: b, config: config, runtime: rt)

            if code == 0 {
                Out.print(Out.green("\(sub) completed: \(toRun.joined(separator: " "))"))
                Out.print(Out.dim("   log: \(config.logsRoot)/deps/"))
            } else {
                fail(.denied("winetricks exit \(code) — see the log in \(config.logsRoot)/deps/"))
            }
        } catch { fail(.denied("\(error)")) }

    default:
        fail(.usage("unknown deps subcommand: '\(sub)'"))
    }
}

func cmdSteam(_ args: [String]) {
    let (config, paths) = loadContext()
    guard let sub = args.first else { fail(.usage("usage: gx steam <status|install|repair|run|stop|launch>")) }
    let (pos, flags) = splitArgs(Array(args.dropFirst()))

    func boxName(_ index: Int = 0) -> String {
        pos.count > index ? pos[index] : config.defaultSteamPrefix
    }

    switch sub {
    case "status":
        let name = boxName()
        let b = requirePrefix(name, paths)
        switch Steam.status(in: b) {
        case .notInstalled:
            Out.print("\(name): " + Out.yellow("Steam not installed"))
        case .installed(let shim):
            Out.print("\(name): Steam installed")
            Out.field("shim", shim ? Out.green("yes") : Out.red("no"))
            if !shim { Out.print(Out.dim("   repair with: gx steam repair \(name)")) }
        }

    case "install":
        let name = boxName()
        let b = requirePrefix(name, paths)
        let rt = runtimeForSteam(b, config: config, override: flags["runtime"])
        let setup = flags["setup"].map { URL(fileURLWithPath: Paths.expand($0)) }
        do {
            Out.print("installing Steam in '\(name)' (online download)…")
            let message = try Steam.install(
                prefix: b, config: config, runtime: rt,
                setupPath: setup,
                setupDownload: flags["no-download"] == nil,
                waitForUpdate: flags["no-update"] == nil,
                force: flags["force"] != nil,
                progress: { Out.print("  \($0)") })
            Out.print(Out.green(message))
            Out.print(Out.dim("   runtime: \(rt.summary)"))
            Out.print(Out.dim("   run with: gx steam run \(name)"))
        } catch { fail(.denied("\(error)")) }

    case "repair":
        let name = boxName()
        let b = requirePrefix(name, paths)
        let rt = runtimeForSteam(b, config: config, override: flags["runtime"])
        do {
            let message = try Steam.repair(prefix: b, config: config, runtime: rt,
                                           force: flags["no-rebuild"] == nil)
            Out.print(Out.green(message))
        } catch { fail(.denied("\(error)")) }

    case "run":
        let name = boxName()
        let b = requirePrefix(name, paths)
        guard b.hasSteam else { fail(.notInstalled("Steam not found in box '\(name)'")) }
        let rt = runtimeForSteam(b, config: config, override: flags["runtime"])
        do {
            let result = try Steam.run(prefix: b, config: config, runtime: rt,
                                       progress: { Out.print("  \($0)") })
            exit(result.exitCode)
        } catch { fail(.denied("\(error)")) }

    case "launch":
        guard pos.count >= 2 else { fail(.usage("usage: gx steam launch <box> <appid> [--no-warmup]")) }
        let b = requirePrefix(pos[0], paths)
        let rt = runtimeForSteam(b, config: config, override: flags["runtime"])
        do {
            let result = try Steam.launch(appid: pos[1], prefix: b, config: config, runtime: rt,
                                          warmupIfCold: flags["no-warmup"] == nil,
                                          progress: { Out.print("  \($0)") })
            exit(result.exitCode)
        } catch { fail(.denied("\(error)")) }

    case "warmup", "precompile":
        // Compila gli shader UNA volta, fuori dalla partita: avvia il gioco,
        // aspetta che la cache smetta di crescere, poi ti dice di chiudere.
        guard pos.count >= 2 else {
            fail(.usage("usage: gx steam warmup <box> <appid> [--timeout N] [--stall N] [--stop]"))
        }
        let b = requirePrefix(pos[0], paths)
        let rt = runtimeForSteam(b, config: config, override: flags["runtime"])
        let timeout = Int(flags["timeout"] ?? "900") ?? 900
        let stall = Int(flags["stall"] ?? "30") ?? 30
        let stop = flags["stop"] != nil
        do {
            let report = try Steam.warmup(
                appid: pos[1], prefix: b, config: config, runtime: rt,
                timeoutSeconds: timeout, stallSeconds: stall, stopOnFinish: stop,
                progress: { Out.print("  \($0)") })
            Out.print("Shaders in cache: \(report.shaderFiles) file, \(ByteFormat.human(report.endBytes))")
        } catch { fail(.denied("\(error)")) }

    case "stop":
        let name = boxName()
        let b = requirePrefix(name, paths)
        Steam.stop(prefix: b, runtime: runtimeForPrefix(b, config: config, override: flags["runtime"]))
        Out.print("Steam stopped in box '\(name)'")

    case "input":
        // Controller su Wine: di default si usa il pad FISICO via XInput, quindi
        // Steam Input viene disattivato (con SDL2 nel runtime il pad arriva a Wine.
        // Misurato 2026-10-02). `--on` torna al pad virtuale di Steam.
        let name = boxName()
        let b = requirePrefix(name, paths)
        let appIDs: [String]
        if let list = flags["appids"] {
            appIDs = list.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        } else {
            appIDs = SteamInput.installedAppIDs(in: b)
        }
        guard !appIDs.isEmpty else {
            Out.print(Out.yellow("no installed games found in box '\(name)'"))
            return
        }
        if flags["check"] != nil {
            Out.print(Out.bold("Steam Input (UseSteamControllerConfig) in '\(name)'"))
            for id in appIDs {
                let v = SteamInput.setting(appID: id, in: b)
                let label = v == SteamInput.enabledValue ? Out.green("enabled")
                          : (v == nil ? Out.yellow("assente") : Out.red("disabilitato (\(v!))"))
                Out.print("  \(id): \(label)")
            }
            return
        }
        // Default = pad fisico (Steam Input OFF). `--on` = pad virtuale di Steam.
        let wantOn = flags["on"] != nil
        do {
            let res = wantOn
                ? try SteamInput.ensureEnabled(appIDs: appIDs, in: b)
                : try SteamInput.ensureDisabled(appIDs: appIDs, in: b)
            if let why = res.skippedReason { fail(.denied(why)) }
            let state = wantOn ? "enabled" : "disabled"
            Out.print("Steam Input: \(res.alreadyEnabled.count) already \(state)"
                      + (res.changed.isEmpty ? "" : ", \(res.changed.count) aggiornati → \(res.changed.joined(separator: ", "))"))
            if let backup = res.backup { Out.print(Out.dim("  backup: \(backup.lastPathComponent)")) }
            if res.changed.isEmpty { Out.print(Out.green("  no changes needed")) }
        } catch { fail(.denied("\(error)")) }

    default:
        fail(.usage("unknown steam subcommand: '\(sub)'"))
    }
}

func cmdGame(_ args: [String]) {
    let (config, paths) = loadContext()
    guard let sub = args.first else { fail(.usage("usage: gx game <list|add|show|remove|launch>")) }
    let (pos, flags, repeated) = splitArgsFull(Array(args.dropFirst()), repeatable: ["arg", "env"])

    switch sub {
    case "list", "ls":
        let registry = GameRegistry.load(config: config)
        if registry.games.isEmpty {
            Out.print("no games registered")
        } else {
            Out.print(Out.bold("Games"))
            for g in registry.games {
                let target: String
                if let appid = g.appid { target = "appid \(appid)" }
                else if let exe = g.exe { target = exe }
                else { target = "?" }
                Out.print("  \(g.name.padding(toLength: 22, withPad: " ", startingAt: 0)) [\(g.prefix)] \(target)")
            }
        }

    case "add", "set":
        guard let name = pos.first else {
            fail(.usage("usage: gx game add <name> --prefix <box> [--appid <id> | --exe <path>] [--arg <a>]* [--env K=V]* [--notes <t>]"))
        }
        guard let boxName = flags["prefix"] else { fail(.usage("missing --prefix <box>")) }
        let b = requirePrefix(boxName, paths)

        var appid: Int?
        if let raw = flags["appid"] {
            guard let value = Int(raw) else { fail(.usage("appid is not numeric: '\(raw)'")) }
            appid = value
        }
        let exe = flags["exe"]
        if appid == nil && exe == nil { fail(.usage("need --appid <id> or --exe <path>")) }
        if appid != nil && !b.hasSteam {
            fail(.notInstalled("box '\(boxName)' has no Steam; required for --appid"))
        }

        var env: [String: String] = [:]
        for pair in repeated["env"] ?? [] {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail(.usage("--env requires K=V, got '\(pair)'")) }
            env[parts[0]] = parts[1]
        }

        let entry = GameEntry(name: name, prefix: boxName, appid: appid, exe: exe,
                              args: repeated["arg"] ?? [], env: env, notes: flags["notes"])
        var registry = GameRegistry.load(config: config)
        registry.upsert(entry)
        do {
            try registry.save(config: config)
            Out.print(Out.green("game '\(name)' registered") + " → \(GameRegistry.url(gamesRoot: paths.gamesRoot).path)")
        } catch { fail(.denied("\(error)")) }

    case "show":
        guard let name = pos.first else { fail(.usage("usage: gx game show <name>")) }
        guard let entry = GameRegistry.load(config: config).find(name) else {
            fail(.denied("game '\(name)' not found"))
        }
        let rt = runtimeForPrefix(requirePrefix(entry.prefix, paths), config: config, override: flags["runtime"])
        Out.print(Out.bold("Game '\(entry.name)'"))
        Out.field("box", entry.prefix)
        Out.field("appid", entry.appid.map(String.init) ?? Out.dim("—"))
        Out.field("exe", entry.exe ?? Out.dim("—"))
        if !entry.args.isEmpty { Out.field("args", entry.args.joined(separator: " ")) }
        if !entry.env.isEmpty {
            Out.field("env", entry.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        }
        if let notes = entry.notes { Out.field("notes", notes) }
        do {
            let plan = try GameLauncher.plan(for: entry, config: config, paths: paths, runtime: rt)
            Out.print()
            Out.print(Out.bold("Launch plan"))
            Out.field("wine", plan.wineBinary)
            Out.field("command", plan.args.joined(separator: " "))
        } catch { Out.print(Out.yellow("  plan unavailable: \(error)")) }

    case "remove", "rm":
        guard let name = pos.first else { fail(.usage("usage: gx game remove <name>")) }
        var registry = GameRegistry.load(config: config)
        guard registry.remove(name) else { fail(.denied("game '\(name)' not found")) }
        do {
            try registry.save(config: config)
            Out.print(Out.green("game '\(name)' removed"))
        } catch { fail(.denied("\(error)")) }

    case "launch", "run":
        guard let name = pos.first else { fail(.usage("usage: gx game launch <name> [--runtime ...]")) }
        guard let entry = GameRegistry.load(config: config).find(name) else {
            fail(.denied("game '\(name)' not found"))
        }
        let b = requirePrefix(entry.prefix, paths)
        let rt = runtimeForPrefix(b, config: config, override: flags["runtime"])
        if flags["dry-run"] != nil {
            do {
                let plan = try GameLauncher.plan(for: entry, config: config, paths: paths, runtime: rt)
                Out.print(Out.bold("dry-run"))
                Out.field("wine", plan.wineBinary)
                Out.field("WINEPREFIX", b.url.path)
                Out.field("command", plan.args.joined(separator: " "))
                return
            } catch { fail(.denied("\(error)")) }
        }
        do {
            Out.print("launching '\(entry.name)'…")
            let result = try GameLauncher.launch(entry, config: config, paths: paths, runtime: rt)
            if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
            if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
            exit(result.exitCode)
        } catch { fail(.denied("\(error)")) }

    default:
        fail(.usage("unknown game subcommand: '\(sub)'"))
    }
}

func cmdLog(_ args: [String]) {
    let (config, _) = loadContext()
    guard let sub = args.first else { fail(.usage("usage: gx log <list|path|tail>")) }
    let (pos, flags) = splitArgs(Array(args.dropFirst()))

    switch sub {
    case "path":
        Out.print(Logs.commandLog(config: config).path)

    case "list":
        let files = Logs.list(config: config)
        if files.isEmpty { Out.print("no logs in \(config.logsRoot)"); return }
        Out.print(Out.bold("Logs"))
        for f in files { Out.print("  \(f.path)") }

    case "tail":
        let lines = Int(flags["lines"] ?? "20") ?? 20
        let files = Logs.list(config: config)
        let target: URL?
        if let name = pos.first {
            target = files.first { $0.lastPathComponent.contains(name) || $0.path.contains(name) }
                ?? (FileManager.default.fileExists(atPath: name) ? URL(fileURLWithPath: name) : nil)
        } else {
            target = files.first
        }
        guard let target else { fail(.denied("no log found\(pos.first.map { " for '\($0)'" } ?? "")")) }
        Out.print(Out.dim("# \(target.path)"))
        for line in Logs.tail(target, lines: lines) where !line.isEmpty { Out.print(line) }

    default:
        fail(.usage("unknown log subcommand: '\(sub)'"))
    }
}

func cmdSetup(_ args: [String]) {
    let (config, _) = loadContext()
    let (pos, flags) = splitArgs(args)
    let dryRun = flags["dry-run"] != nil

    let components = Setup.status(config: config)
    let only = flags["only"] ?? pos.first

    if only == nil && flags["list"] != nil {
        Out.print(Out.bold("Components"))
        for c in components {
            let tag = c.installed ? Out.green("installed") : (c.installable ? Out.yellow("missing") : Out.red("manual"))
            Out.print("  \(c.id.padding(toLength: 14, withPad: " ", startingAt: 0)) \(tag)  \(Out.dim(c.title))")
        }
        return
    }

    if let only {
        guard let component = components.first(where: { $0.id == only }) else {
            fail(.usage("unknown component '\(only)'. See `gx setup --list`"))
        }
        if component.installed { Out.print(Out.green("\(component.title) already present")); return }
        if !component.installable {
            Out.print(Out.yellow("\(component.title) must be installed manually: \(component.manualURL ?? "-")"))
            return
        }
        Out.print("installing \(component.title)…")
        do {
            let code = try Setup.install(component, config: config, dryRun: dryRun)
            exit(code)
        } catch { fail(.denied("\(error)")) }
    }

    if dryRun {
        Out.print(Out.bold("dry-run — components to install"))
        for c in components where !c.installed {
            Out.print("  \(c.id): \(c.installable ? c.installCommand.joined(separator: " ") : "manual → \(c.manualURL ?? "-")")")
        }
        return
    }
    Out.print(Out.bold("Installing missing components…"))
    let count = Setup.installMissing(config: config) { Out.print("  \($0)") }
    Out.print(Out.green("\(count) components installed"))
}
