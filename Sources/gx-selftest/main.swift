import Foundation
import GameXCore

// Self-test for GameXCore without XCTest / Swift Testing
// (CommandLineTools on this machine doesn't expose them and the Xcode license
// isn't accepted). Run with: `swift run gx-selftest`.

final class Harness {
    private var passed = 0
    private var failed = 0

    func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if condition { passed += 1; print("  ok  \(message)") }
        else { failed += 1; print("  FAIL \(message)  (\(file):\(line))") }
    }

    func equal<T: Equatable>(_ a: T, _ b: T, _ message: String) {
        check(a == b, "\(message) — expected \(b), got \(a)")
    }

    func finish() -> Int32 {
        print("\n\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}

let h = Harness()

print("TOML parser and config")
do {
    let toml = """
    # comment
    [paths]
    prefix_root = "~/WinePrefixes"
    [launch]
    esync = true
    msync = false
    """
    let entries = TOMLParser.parse(toml)
    h.equal(entries.count, 3, "entry count")
    h.equal(entries.first?.section, "paths", "section")
    h.equal(entries.first?.key, "prefix_root", "key")
    h.equal(entries.first?.value, "~/WinePrefixes", "value")

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("gx-test-\(UUID().uuidString).toml")
    try? """
    [runtime]
    gptk_app = "/tmp/GPTK.app"
    [launch]
    esync = false
    """.write(to: tmp, atomically: true, encoding: .utf8)
    let config = Config.resolve(environment: ["GX_PREFIX_ROOT": "/tmp/prefixes"], fileURL: tmp)
    h.equal(config.gptkApp, "/tmp/GPTK.app", "config from file")
    h.check(config.esync == false, "esync from file")
    h.equal(config.prefixRoot, "/tmp/prefixes", "env overrides file")
    try? FileManager.default.removeItem(at: tmp)
}

print("Runtime")
h.equal(Runtime.parseMajor(from: "wine-11.10"), 11, "major 11")
h.equal(Runtime.parseMajor(from: "wine-7.7 (Game Porting Toolkit 1.1)"), 7, "major 7")
h.check(Runtime.parseMajor(from: "unknown") == nil, "major nil")
do {
    let old = ResolvedRuntime(kind: .gptkWine, wineBinary: "/x", version: "wine-7.7",
                              wineMajor: 7, gptkApp: nil, hasD3DMetal: true, rosettaAvailable: true)
    let new = ResolvedRuntime(kind: .wineStaging, wineBinary: "/y", version: "wine-11.10",
                              wineMajor: 11, gptkApp: nil, hasD3DMetal: false, rosettaAvailable: true)
    h.check(old.supportsModernSteam == false, "wine 7 does not support modern Steam")
    h.check(new.supportsModernSteam == true, "wine 11 supports modern Steam")
}

print("DXMF runtime")
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-dxmf-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    // Host finto: `bin/wine` eseguibile ma MAI eseguito. La versione dell'host
    // è dichiarata accanto all'host, così la scoperta non invoca Wine (isolamento).
    func makeHost(_ name: String, declared: String) -> URL {
        let host = root.appendingPathComponent(name)
        try? fm.createDirectory(at: host.appendingPathComponent("bin"),
                                withIntermediateDirectories: true)
        let wine = host.appendingPathComponent("bin/wine")
        try? Data([0x7f, 0x45, 0x4c, 0x46]).write(to: wine)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try? "{\"wineVersion\":\"\(declared)\"}".write(
            to: host.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return host
    }

    // F001b: stub dei due `.so` dell'host. `patched` decide se portano i marker
    // che `strings`/`nm` cercano; `libs` crea le librerie di sistema.
    func writeHostLibs(_ host: URL, patched: Bool, libs: Bool) {
        let unix = host.appendingPathComponent("lib/wine/x86_64-unix")
        try? fm.createDirectory(at: unix, withIntermediateDirectories: true)
        try? "\(patched ? "WINEDLLPATH_PREPEND" : "no-dllpath-marker")\n".write(
            to: unix.appendingPathComponent("ntdll.so"), atomically: true, encoding: .utf8)
        try? "\(patched ? "macdrv_functions" : "no-macdrv-marker")\n".write(
            to: unix.appendingPathComponent("winemac.so"), atomically: true, encoding: .utf8)
        guard libs else { return }
        let external = host.appendingPathComponent("lib/external")
        try? fm.createDirectory(at: external, withIntermediateDirectories: true)
        for lib in ["libfreetype.6.dylib", "libMoltenVK.dylib", "libgnutls.30.dylib"] {
            try? Data([0xca, 0xfe, 0xba, 0xbe]).write(to: external.appendingPathComponent(lib))
        }
    }

    // Stage finto: d3d11 + dxgi (PE + unix), con pin 11.10 dichiarato.
    let stage = root.appendingPathComponent("game-stage/wine")
    for module in ["d3d11", "dxgi"] {
        for (dir, ext) in [("x86_64-windows", "dll"), ("x86_64-unix", "so")] {
            let file = stage.appendingPathComponent("\(dir)/\(module).\(ext)")
            try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? Data([0x7f, 0x45, 0x4c, 0x46]).write(to: file)
        }
    }
    try? "{\"pinnedVersion\":\"11.10\"}".write(
        to: stage.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    let host = makeHost("wine-d3dmetal", declared: "wine-11.10")
    writeHostLibs(host, patched: true, libs: true)
    let cfg = Config(dxmfWineRoot: host.path, dxmfStage: stage.path)
    guard let info = DXMF.discover(config: cfg) else {
        h.check(false, "dxmf discover finds host + stage")
        exit(h.finish())
    }
    h.check(info.isUsable, "dxmf runtime usable")
    h.check(info.unusableReason == nil, "usable → nil reason")
    h.equal(info.wineVersion, "wine-11.10", "host wine version")
    h.equal(info.modules, ["d3d11", "dxgi"], "modules from the stage")
    h.equal(info.pinnedVersion, "11.10", "pin from the stage manifest")
    h.check(info.versionMismatch == nil, "matching versions → no mismatch")
    h.equal(DXMF.moduleFiles(for: info).count, 2, "moduleFiles pairing")
    let pair = DXMF.moduleFiles(for: info).first { $0.name == "d3d11" }
    h.equal(pair?.pe.path, stage.appendingPathComponent("x86_64-windows/d3d11.dll").path,
            "PE path d3d11")
    h.equal(pair?.unix.path, stage.appendingPathComponent("x86_64-unix/d3d11.so").path,
            "unix path d3d11")

    // environment esatto, default (quiet = true, nessun frame log / lock).
    let env = DXMF.environment(for: info, diagnostics: DXMF.Diagnostics())
    h.equal(env["WINEDLLPATH_PREPEND"], stage.path, "WINEDLLPATH_PREPEND = stage")
    h.equal(env["WINEDLLOVERRIDES"], "d3d9,d3d11,dxgi=b", "WINEDLLOVERRIDES base")
    h.equal(env["DXMF_DIAG_QUIET"], "1", "DXMF_DIAG_QUIET default 1")
    h.check(env["DXMF_FRAME_TIME"] == nil, "no frame log by default")
    h.check(env["DXMF_LOCK_DIR"] == nil, "no lock dir by default")
    h.check(env["DXMF_GATE_LOCK_WAIT"] == nil, "no gate wait by default")

    // frame log / lock dir / gate wait esposti.
    let diag = DXMF.Diagnostics(quiet: false,
                                frameLog: URL(fileURLWithPath: "/tmp/gx-frame.log"),
                                lockDir: "/tmp/gx-locks",
                                gateLockWait: 300)
    let env2 = DXMF.environment(for: info, diagnostics: diag)
    h.equal(env2["DXMF_FRAME_TIME"], "/tmp/gx-frame.log", "DXMF_FRAME_TIME")
    h.equal(env2["DXMF_LOCK_DIR"], "/tmp/gx-locks", "DXMF_LOCK_DIR")
    h.equal(env2["DXMF_GATE_LOCK_WAIT"], "300", "DXMF_GATE_LOCK_WAIT")
    h.check(env2["DXMF_DIAG_QUIET"] == nil, "not quiet → no DXMF_DIAG_QUIET")

    // extra applicato per ultimo e vince.
    let env3 = DXMF.environment(for: info, diagnostics: DXMF.Diagnostics(),
                                extra: ["WINEDLLPATH_PREPEND": "/override"])
    h.equal(env3["WINEDLLPATH_PREPEND"], "/override", "extra wins")

    // dylib di supporto: esistono solo se la cartella esiste davvero.
    let depsDir = root.appendingPathComponent("x64deps")
    try? FileManager.default.createDirectory(at: depsDir, withIntermediateDirectories: true)
    let envDeps = DXMF.environment(for: info, diagnostics: DXMF.Diagnostics(depsDir: depsDir))
    h.check((envDeps["DYLD_LIBRARY_PATH"] ?? "").contains(depsDir.path),
            "depsDir present → DYLD_LIBRARY_PATH")
    let envNoDeps = DXMF.environment(
        for: info,
        diagnostics: DXMF.Diagnostics(depsDir: root.appendingPathComponent("missing-deps")))
    h.check(envNoDeps["DYLD_LIBRARY_PATH"] == nil,
            "a deps folder that does not exist is not declared")
    h.equal(DXMF.resolveDepsDir(config: Config(dxmfDeps: depsDir.path))?.path, depsDir.path,
            "resolveDepsDir honours the explicit config")

    // Il muro: host wine-7.7 con pin 11.10 → mismatch nominato + non usabile.
    let oldHost = makeHost("wine-gptk-77", declared: "wine-7.7")
    let oldCfg = Config(dxmfWineRoot: oldHost.path, dxmfStage: stage.path)
    guard let old = DXMF.discover(config: oldCfg) else {
        h.check(false, "dxmf discover finds the old host")
        exit(h.finish())
    }
    h.check(old.versionMismatch != nil, "wine-7.7 vs pin 11.10 → mismatch")
    h.check(old.isUsable == false, "wine-7.7 host is not usable")
    h.check(old.unusableReason != nil, "unusable reason is named")
    h.check((old.versionMismatch ?? "").contains("wine-7.7"), "mismatch names host version")
    h.check((old.versionMismatch ?? "").contains("11.10"), "mismatch names pinned version")
    // L'ordine dei rifiuti: la versione viene prima delle capacità (l'host
    // wine-7.7 qui non ha nemmeno le patch: il messaggio deve restare il mismatch).
    h.check(!(old.unusableReason ?? "").contains("--from-source"),
            "version mismatch precedes the capability refusal")

    // F001b — capacità dell'host: 4 host finti (a/b/c/d), senza eseguire Wine.
    func capsHost(_ name: String, patched: Bool, libs: Bool) -> DXMF.HostCapabilities {
        let fake = makeHost(name, declared: "wine-11.10")
        writeHostLibs(fake, patched: patched, libs: libs)
        return DXMF.hostCapabilities(forBinary: fake.appendingPathComponent("bin/wine").path)
    }

    let capA = capsHost("cap-a-patched-libs", patched: true, libs: true)
    h.check(capA.canLoadDXMFModules, "(a) patch+libs → modules loadable")
    h.check(capA.canHostSteam, "(a) patch+libs → Steam hostable")
    h.check(capA.refusal == nil, "(a) patch+libs → no refusal")
    h.equal(capA.systemLibraries, ["freetype", "MoltenVK", "gnutls"], "(a) 3 system libraries")

    let capB = capsHost("cap-b-patched-nolibs", patched: true, libs: false)
    h.check(capB.canLoadDXMFModules, "(b) patch no libs → modules loadable")
    h.check(capB.canHostSteam == false, "(b) patch no libs → Steam not hostable")
    h.check(capB.refusal == nil, "(b) patch no libs → no refusal (game-only host)")
    h.check(capB.summary.contains("game only"), "(b) summary calls it game-only")

    let capC = capsHost("cap-c-libs-nopatch", patched: false, libs: true)
    h.check(capC.canLoadDXMFModules == false, "(c) libs no patch → modules not loadable")
    h.check(capC.canHostSteam == false, "(c) libs no patch → Steam not hostable")
    let refusalC = capC.refusal ?? ""
    h.check(refusalC.contains("WINEDLLPATH_PREPEND"), "(c) refusal names the ntdll patch")
    h.check(refusalC.contains("macdrv_functions"), "(c) refusal names the winemac patch")
    h.check(refusalC.contains("gx runtime install --from-source"), "(c) refusal names the remedy")

    let capD = capsHost("cap-d-none", patched: false, libs: false)
    h.check(capD.canLoadDXMFModules == false, "(d) neither → modules not loadable")
    h.check(capD.canHostSteam == false, "(d) neither → Steam not hostable")
    h.check(capD.systemLibraries.isEmpty, "(d) neither → no libraries")
    h.check(capD.refusal != nil, "(d) neither → named refusal")

    // (b) via discover: un host patchato senza librerie resta usabile per il gioco.
    let gameOnlyHost = makeHost("cap-game-only", declared: "wine-11.10")
    writeHostLibs(gameOnlyHost, patched: true, libs: false)
    let gameOnlyCfg = Config(dxmfWineRoot: gameOnlyHost.path, dxmfStage: stage.path)
    if let gameOnly = DXMF.discover(config: gameOnlyCfg) {
        h.check(gameOnly.isUsable, "(b) game-only host is usable")
        h.check(gameOnly.unusableReason == nil, "(b) game-only host → no unusable reason")
        h.check(gameOnly.hostCapabilities.canLoadDXMFModules, "(b) game-only → modules loadable")
        h.check(gameOnly.hostCapabilities.canHostSteam == false, "(b) game-only → can't host Steam")
    } else {
        h.check(false, "(b) discover finds the game-only host")
    }

    // (c) via discover: senza patch l'host è inutilizzabile, e il rifiuto
    // composto nomina la patch mancante e il rimedio.
    let noPatchHost = makeHost("cap-nopatch", declared: "wine-11.10")
    writeHostLibs(noPatchHost, patched: false, libs: true)
    let noPatchCfg = Config(dxmfWineRoot: noPatchHost.path, dxmfStage: stage.path)
    if let noPatch = DXMF.discover(config: noPatchCfg) {
        h.check(noPatch.isUsable == false, "(c) unpatched host is not usable")
        let reason = noPatch.unusableReason ?? ""
        h.check(reason.contains("WINEDLLPATH_PREPEND"), "(c) unusableReason names missing ntdll patch")
        h.check(reason.contains("gx runtime install --from-source"), "(c) unusableReason names the remedy")
    } else {
        h.check(false, "(c) discover finds the unpatched host")
    }

    // Host reali (read-only), solo se esistono: la misura della tabella §1-bis.
    let realHome = fm.homeDirectoryForCurrentUser
    let realD3DMetal = realHome.appendingPathComponent("wine-d3dmetal/bin/wine").path
    if fm.isExecutableFile(atPath: realD3DMetal) {
        let caps = DXMF.hostCapabilities(forBinary: realD3DMetal)
        let required = ["freetype", "MoltenVK", "gnutls"]
        h.check(caps.hasDllPathPrepend, "real ~/wine-d3dmetal has WINEDLLPATH_PREPEND")
        h.check(caps.hasMacdrvBridge, "real ~/wine-d3dmetal has macdrv_functions")
        h.check(caps.canLoadDXMFModules, "real ~/wine-d3dmetal loads dxmf modules")
        h.check(caps.refusal == nil, "real ~/wine-d3dmetal: no capability refusal")
        // Le librerie di sistema di questo host sono cambiate sotto la lane
        // (misurato 2026-10-15: 0 alle 22:10, tutte e 3 alle 22:12). La probe
        // misura lo stato reale, quindi non fissiamo un valore: verifichiamo
        // che `canHostSteam` concordi con le librerie misurate (nel messaggio).
        h.check(caps.canHostSteam == (caps.canLoadDXMFModules
                    && required.allSatisfy(caps.systemLibraries.contains)),
                "real ~/wine-d3dmetal: canHostSteam matches measured \(caps.systemLibraries)")
    }
    let realStaging = "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"
    if fm.isExecutableFile(atPath: realStaging) {
        let caps = DXMF.hostCapabilities(forBinary: realStaging)
        h.check(caps.hasDllPathPrepend == false, "real Wine Staging lacks WINEDLLPATH_PREPEND")
        h.check(caps.hasMacdrvBridge == false, "real Wine Staging lacks macdrv_functions")
        h.check(caps.canLoadDXMFModules == false, "real Wine Staging cannot load dxmf modules")
        h.check(caps.canHostSteam == false, "real Wine Staging cannot host Steam UI (no patches)")
        h.equal(caps.systemLibraries, ["freetype", "MoltenVK", "gnutls"],
                "real Wine Staging: 3 system libraries")
        h.check(caps.refusal != nil, "real Wine Staging: named refusal")
    }

    // Uno stage senza moduli completi non è uno stage.
    let emptyStage = root.appendingPathComponent("empty-stage")
    try? fm.createDirectory(at: emptyStage.appendingPathComponent("x86_64-windows"),
                            withIntermediateDirectories: true)
    h.check(DXMF.discoverStage(root: emptyStage) == nil, "incomplete stage → nil")
}

print("Game registry")
do {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gx-reg-\(UUID().uuidString)")
    var registry = GameRegistry()
    registry.games.append(GameEntry(name: "elden-ring", prefix: "Steam", appid: 1245620))
    try? registry.save(gamesRoot: root)
    let loaded = GameRegistry.load(gamesRoot: root)
    h.equal(loaded.games.count, 1, "one game saved")
    h.equal(loaded.games.first?.appid, 1245620, "appid round-trip")
    try? FileManager.default.removeItem(at: root)

    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("gx-missing-\(UUID().uuidString)")
    h.check(GameRegistry.load(gamesRoot: missing).games.isEmpty, "missing registry → empty")
}

print("GPU / Metal")
do {
    let old = GPUInfo(macOSVersion: "26.6.2", architecture: "arm64", chip: "Apple M4")
    h.check(old.metal4Verdict(gptkVersion: "GPTK").contains("unavailable"), "Metal 4 unavailable on macOS 26")
    let new = GPUInfo(macOSVersion: "27.0", architecture: "arm64", chip: "Apple M4")
    h.equal(new.metal4Verdict(gptkVersion: "GPTK 4"), "Metal 4 available", "Metal 4 available")
    h.check(new.maxMetal.contains("Metal 4"), "maxMetal on macOS 27")
}

print("Boxes (M1)")
do {
    h.check(Prefix.validateName("Steam"), "valid name Steam")
    h.check(Prefix.validateName("gx-test_1"), "valid name with - and _")
    h.check(Prefix.validateName("my.games"), "valid name with .")
    h.check(!Prefix.validateName(""), "empty name invalid")
    h.check(!Prefix.validateName("../evil"), "path traversal invalid")
    h.check(!Prefix.validateName("a/b"), "slash invalid")
    h.equal(ByteFormat.human(0), "0 B", "0 bytes")
    h.equal(ByteFormat.human(1536), "1.5 KB", "1536 bytes")
    h.equal(ByteFormat.human(2_147_483_648), "2.0 GB", "2 GiB")
    h.check(Runtime.select(nil, config: Config()) != nil, "select(nil) → auto runtime")
    let staging = "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine"
    if FileManager.default.isExecutableFile(atPath: staging) {
        h.equal(Runtime.select(staging, config: Config())?.kind, .wineStaging,
                 "select(path staging) keeps kind")
    }
}

print("Dependencies (M2)")
do {
    h.check(Deps.info(for: "vcrun2022")?.risk == .safe, "vcrun2022 is safe")
    h.check(Deps.info(for: "dotnet6")?.risk == .delicate, "dotnet6 is delicate")
    h.check(Deps.info(for: "nope") == nil, "unknown verb → nil")
    h.equal(Deps.command(verbs: ["vcrun2022"]).joined(separator: " "), "-q vcrun2022", "install command")
    h.equal(Deps.command(verbs: ["vcrun2022"], remove: true).joined(separator: " "),
             "-q --uninstall vcrun2022", "remove command")
    do { try Deps.validate(["vcrun2022", "corefonts"]); h.check(true, "validate known verbs") }
    catch { h.check(false, "validate known verbs: \(error)") }
    do { try Deps.validate(["bogus"]); h.check(false, "validate must reject bogus") }
    catch { h.check(true, "validate rejects unknown verb") }
}

print("Steam / Shim (M3)")
do {
    h.check(Shim.sourceURL != nil, "shim source bundled")
    do {
        let built = try Shim.build(config: Config())
        h.equal(built.count, 2, "shim built for 2 architectures")
        h.check(built[.x86_64].map { FileManager.default.fileExists(atPath: $0.path) } == true,
                "shim x64 exists")
    } catch {
        h.check(false, "build shim: \(error)")
    }
}

print("Game registry and launcher (M4)")
do {
    var registry = GameRegistry()
    registry.upsert(GameEntry(name: "b", prefix: "P", appid: 2))
    registry.upsert(GameEntry(name: "a", prefix: "P", exe: "x.exe"))
    h.equal(registry.games.map { $0.name }, ["a", "b"], "upsert sorts by name")
    registry.upsert(GameEntry(name: "a", prefix: "P", exe: "y.exe"))
    h.equal(registry.find("a")?.exe, "y.exe", "upsert replaces")
    h.check(registry.remove("a"), "remove true")
    h.check(!registry.remove("zzz"), "remove false when absent")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("gx-m4-\(UUID().uuidString)/prefixes")
    try? FileManager.default.createDirectory(
        at: root.appendingPathComponent("P/drive_c"), withIntermediateDirectories: true)
    let cfg = Config.resolve(environment: ["GX_PREFIX_ROOT": root.path],
                             fileURL: root.appendingPathComponent("none.toml"))
    let paths = cfg.resolvedPaths()
    let rt = ResolvedRuntime(kind: .wineStaging, wineBinary: "/usr/bin/true", version: "wine-11.10",
                             wineMajor: 11, gptkApp: nil, hasD3DMetal: false, rosettaAvailable: true)
    do {
        let plan = try GameLauncher.plan(
            for: GameEntry(name: "t", prefix: "P", exe: "C:\\x.exe", args: ["-a"], env: ["WINEESYNC": "0"]),
            config: cfg, paths: paths, runtime: rt)
        h.equal(plan.args, ["C:\\x.exe", "-a"], "plan exe+args")
        h.equal(plan.env["WINEESYNC"], "0", "plan env override")
    } catch { h.check(false, "plan exe: \(error)") }
    do {
        _ = try GameLauncher.plan(for: GameEntry(name: "t", prefix: "P"),
                                  config: cfg, paths: paths, runtime: rt)
        h.check(false, "plan without target must fail")
    } catch { h.check(true, "plan without target → error") }
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
}

print("Logging and doctor (M5)")
do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gx-log-\(UUID().uuidString).log")
    try? "l1\nl2\nl3\nl4\nl5\n".write(to: tmp, atomically: true, encoding: .utf8)
    h.equal(Logs.tail(tmp, lines: 2), ["l4", "l5"], "tail 2 lines")
    try? FileManager.default.removeItem(at: tmp)

    let report = Doctor.run(config: Config())
    h.check(!report.checks.isEmpty, "doctor produces checks")
    let c = report.counts
    h.equal(c.ok + c.warn + c.fail, report.checks.count, "counts consistent")
    do {
        let data = try JSONEncoder().encode(report)
        h.check(data.count > 0, "doctor report JSON-encodable")
    } catch { h.check(false, "JSON doctor: \(error)") }

    do {
        let gpu = GPUInfo(macOSVersion: "27.0", architecture: "arm64", chip: "Apple M4", gpuCores: 10)
        let data = try JSONEncoder().encode(gpu)
        h.check(data.count > 0, "GPUInfo encodable")
    } catch { h.check(false, "JSON gpu: \(error)") }
}

print("GPTK and Setup (M6b)")
do {
    h.equal(GPTK.recommended(for: 14), 2, "macOS 14 → GPTK 2")
    h.equal(GPTK.recommended(for: 15), 3, "macOS 15 → GPTK 3")
    h.equal(GPTK.recommended(for: 26), 3, "macOS 26 → GPTK 3")
    h.equal(GPTK.recommended(for: 27), 4, "macOS 27 → GPTK 4")
    h.check(GPTK.installHint(for: 27).contains("GPTK 4"), "hint mentions GPTK 4")
    let comps = Setup.status(config: Config())
    h.check(comps.contains { $0.id == "wine-staging" }, "setup includes wine-staging")
    h.check(comps.contains { $0.id == "gptk" }, "setup includes gptk")
}

print("Game-X Wine+DXMT runtime")
do {
    // Layout auto-consistente riconosciuto in una cartella temporanea.
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-dxmt-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    for dir in ["wine/bin", "wine/lib/wine/x86_64-unix", "wine/share/wine/mono",
                "renderers/dxmt/wine/x86_64-windows", "renderers/dxmt/wine/x86_64-unix", "x64deps"] {
        try? fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    // binari finti (bastano eseguibili vuoti)
    for f in ["wine/bin/wine", "wine/lib/wine/x86_64-unix/ntdll.so", "wine/lib/wine/x86_64-unix/winemac.so",
              "renderers/dxmt/wine/x86_64-windows/d3d11.dll", "renderers/dxmt/wine/x86_64-unix/winemetal.so",
              "wine/share/wine/mono/wine-mono-11.1.0-x86.msi"] {
        let url = root.appendingPathComponent(f)
        try? Data([0x7f, 0x45, 0x4c, 0x46]).write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    let manifest = DXMT.Manifest(name: "wine-dxmt", wineVersion: "wine-11.10",
                                 dxmtVersion: "0.80", monoVersion: "11.1.0")
    try? JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))

    guard let info = DXMT.discover(root: root) else {
        h.check(false, "DXMT layout riconosciuto")
        exit(h.finish())
    }
    h.check(info.isUsable, "runtime DXMT utilizzabile")
    h.equal(info.wineVersion, "wine-11.10", "Wine version from manifest")
    h.equal(info.dxmtVersion, "0.80", "DXMT version from manifest")

    let env = DXMT.environment(for: info)
    h.equal(env["WINEDLLPATH_PREPEND"], info.rendererRoot.path, "WINEDLLPATH_PREPEND = renderer")
    h.check((env["WINEDLLOVERRIDES"] ?? "").contains("d3d11"), "override d3d11 presente")
    h.check((env["WINEDLLOVERRIDES"] ?? "").contains("winemetal=b"), "override winemetal=b")
    h.check((env["DYLD_LIBRARY_PATH"] ?? "").contains(info.x64Deps.path), "DYLD_LIBRARY_PATH su x64deps")
    h.equal(info.monoMSI()?.lastPathComponent, "wine-mono-11.1.0-x86.msi", "MSI mono trovato")

    // i symlink winemetal (ntdll.so/winemac.so) vengono creati accanto a winemetal.so
    try? DXMT.ensureUnixLinks(info)
    let link = root.appendingPathComponent("renderers/dxmt/wine/x86_64-unix/ntdll.so")
    h.check(fm.fileExists(atPath: link.path), "symlink ntdll.so creato")

    // un layout non-DXMT non deve essere riconosciuto
    let empty = fm.temporaryDirectory.appendingPathComponent("gx-empty-\(UUID().uuidString)")
    try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
    h.check(DXMT.discover(root: empty) == nil, "empty folder is not a DXMT runtime")
    try? fm.removeItem(at: empty)

    // presenza di mono nel prefix
    let fakePrefix = fm.temporaryDirectory.appendingPathComponent("gx-prefix-\(UUID().uuidString)")
    try? fm.createDirectory(at: fakePrefix.appendingPathComponent("drive_c/windows"), withIntermediateDirectories: true)
    h.check(!DXMT.monoInstalled(in: fakePrefix), "mono assente rilevato")
    try? fm.createDirectory(at: fakePrefix.appendingPathComponent("drive_c/windows/mono/mono-2.0"),
                            withIntermediateDirectories: true)
    h.check(DXMT.monoInstalled(in: fakePrefix), "mono presente rilevato")
    try? fm.removeItem(at: fakePrefix)
}

print("Command line tokens")
do {
    h.equal(CommandLineTokens.split("notepad"), ["notepad"], "single token")
    h.equal(CommandLineTokens.split("cmd /c dir C:\\"), ["cmd", "/c", "dir", "C:\\"], "simple split")
    h.equal(CommandLineTokens.split("\"C:\\Program Files\\App\\app.exe\" --flag"),
             ["C:\\Program Files\\App\\app.exe", "--flag"], "quoted path")
    h.equal(CommandLineTokens.split("a  b"), ["a", "b"], "collapses spaces")
    h.equal(CommandLineTokens.split(""), [], "empty")
}

print("Steam Input / localconfig.vdf")
do {
    // File di esempio con DUE sezioni "apps" (una annidata) per verificare
    // che venga scelta quella di primo livello.
    let vdf = """
    "UserLocalConfigStore"
    {
    	"Software"
    	{
    		"Valve"
    		{
    			"Steam"
    			{
    				"apps"
    				{
    					"999999"
    					{
    						"usetime"		"1"
    					}
    				}
    			}
    		}
    	}
    	"apps"
    	{
    		"814380"
    		{
    			"UseSteamControllerConfig"		"0"
    			"SteamControllerRumble"		"-1"
    		}
    		"377160"
    		{
    			"SteamControllerRumble"		"-1"
    		}
    	}
    	"controller_config"
    	{
    		"814380"
    		{
    			"usetime"		"47.35"
    		}
    	}
    }
    """

    guard let section = SteamInput.appsSection(of: vdf) else {
        h.check(false, "appsSection trovata")
        exit(h.finish())
    }
    h.check(section.contains("814380"), "appsSection picks the right section")
    h.check(!section.contains("999999"), "appsSection does not pick the nested one")

    h.equal(SteamInput.value(of: SteamInput.controllerKey, forApp: "814380", in: section), "0",
            "lettura UseSteamControllerConfig")
    h.check(SteamInput.value(of: SteamInput.controllerKey, forApp: "377160", in: section) == nil,
            "chiave assente -> nil")

    var updated = SteamInput.setValue("2", of: SteamInput.controllerKey, forApp: "814380", in: section)
    h.equal(SteamInput.value(of: SteamInput.controllerKey, forApp: "814380", in: updated), "2",
            "value updated to 2 (enabled)")
    h.check(updated.contains("SteamControllerRumble"), "other keys are preserved")

    updated = SteamInput.setValue("2", of: SteamInput.controllerKey, forApp: "377160", in: updated)
    h.equal(SteamInput.value(of: SteamInput.controllerKey, forApp: "377160", in: updated), "2",
            "key inserted into existing block")

    updated = SteamInput.setValue("2", of: SteamInput.controllerKey, forApp: "12345", in: updated)
    h.equal(SteamInput.value(of: SteamInput.controllerKey, forApp: "12345", in: updated), "2",
            "block created for a new app")

    h.check(SteamInput.bracesBalanced(updated), "braces balanced after edits")
    h.check(!SteamInput.bracesBalanced("{\n\t\"a\"\n"), "unbalanced braces detected")
}

print("Shader cache DXMT")
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-cache-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    for d in ["wine/bin", "renderers/dxmt/wine/x86_64-windows", "renderers/dxmt/wine/x86_64-unix"] {
        try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    for f in ["wine/bin/wine", "renderers/dxmt/wine/x86_64-windows/d3d11.dll",
              "renderers/dxmt/wine/x86_64-unix/winemetal.so"] {
        let url = root.appendingPathComponent(f)
        try? Data([0x7f]).write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    guard let info = DXMT.discover(root: root) else {
        h.check(false, "runtime for cache test")
        exit(h.finish())
    }
    h.check(DXMT.shaderCacheStatus(for: info).isEmpty, "empty cache at the start")
    h.check(DXMT.shaderCacheNotice(for: info).contains("first run"),
            "first-run notice")
    let cache = DXMT.shaderCacheDir(for: info)
    try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try? Data(repeating: 0, count: 1024).write(to: cache.appendingPathComponent("shaders_320.db"))
    try? Data(repeating: 0, count: 512).write(to: cache.appendingPathComponent("shaders_320.db-wal"))
    let st = DXMT.shaderCacheStatus(for: info)
    h.check(!st.isEmpty, "cache popolata rilevata")
    h.equal(st.files, 2, "conta db e wal")
    h.equal(st.bytes, 1536, "sums the sizes")
    h.check(DXMT.shaderCacheNotice(for: info).contains("shader cache present"), "cache-present notice")
    try? Data().write(to: cache.appendingPathComponent("shaders_320.db-lock"))
    h.equal(DXMT.shaderCacheStatus(for: info).files, 2, "-lock is not counted")
}

print("Warm-up shader marker")
do {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-warm-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    for d in ["wine/bin", "renderers/dxmt/wine/x86_64-windows", "renderers/dxmt/wine/x86_64-unix"] {
        try? fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
    }
    for f in ["wine/bin/wine", "renderers/dxmt/wine/x86_64-windows/d3d11.dll",
              "renderers/dxmt/wine/x86_64-unix/winemetal.so"] {
        let u = root.appendingPathComponent(f)
        try? Data([0x7f]).write(to: u)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
    guard let info = DXMT.discover(root: root) else {
        h.check(false, "runtime for warm-up test")
        exit(h.finish())
    }
    let appid = "814380"
    h.check(!DXMT.isWarmed(appid: appid, for: info), "not warmed at the start")
    h.check(!DXMT.cacheGrewSinceWarmup(appid: appid, for: info), "without marker it is not reported as grown")
    DXMT.markWarmed(appid: appid, for: info, bytes: 1_000_000)
    h.check(DXMT.isWarmed(appid: appid, for: info), "warmed after markWarmed")
    h.check(!DXMT.cacheGrewSinceWarmup(appid: appid, for: info), "cache unchanged -> no recompile")
    try? Data(repeating: 0, count: 4_000_000).write(
        to: DXMT.shaderCacheDir(for: info).appendingPathComponent("shaders_320.db"))
    h.check(DXMT.cacheGrewSinceWarmup(appid: appid, for: info), "cache grew -> warm-up needed")
}

// Igiene F002: lock per box (BoxLock) e orfani winedbg (Orphans).
runHygieneChecks(h)

// F004: innesti — find per enumerazione, lock a livello di libreria,
// Steam su dxvk + gioco su dxmf, risoluzione dell'exe.
runPrefixChecks(h)

// F003: il tetto di log (LaunchLog).
runLogChecks(h)

runLockScopeChecks(h)
exit(h.finish())
