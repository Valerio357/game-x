import Foundation
import GameXCore

// F004: innesti. Test **ermetici**: box, cache e stage vivono in una tmpdir;
// nessun Wine, nessun box reale. Coprono il punto 1 (find per enumerazione),
// il punto 2 (il lock tenuto fa rifiutare le mutazioni di libreria), il punto 4
// (Steam non porta mai il contratto dxmf, il gioco sì) e il punto 5 (exe
// risolto da `appmanifest` + `libraryfolders.vdf`).

func runPrefixChecks(_ h: Harness) {
    print("F004: prefix enumeration, library lock, Steam/dxmf split, exe resolution")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-f004-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    let prefixRoot = root.appendingPathComponent("prefixes")
    let cacheRoot = root.appendingPathComponent("cache")
    try? fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
    let config = Config(prefixRoot: prefixRoot.path, cacheRoot: cacheRoot.path)
    let paths = config.resolvedPaths()

    func makeBox(_ name: String) -> PrefixRecord {
        let url = prefixRoot.appendingPathComponent(name)
        try? fm.createDirectory(at: url.appendingPathComponent("drive_c"),
                                withIntermediateDirectories: true)
        return PrefixRecord(name: name, url: url)
    }

    // 1) `find` risolve un box che il listino mostra, per **enumerazione**.
    let listed = makeBox("enum-box")
    h.check(Prefix.list(paths: paths).contains { $0.name == "enum-box" },
            "enum-box is visible to Prefix.list")
    h.equal(Prefix.find("enum-box", paths: paths)?.name, "enum-box",
            "find resolves a box the listing shows")
    h.equal(Prefix.find("enum-box", paths: paths)?.url.path, listed.url.path,
            "find returns the enumerated record")

    // Il caso misurato (`evidence/ambiguous-read-20261015.txt`): il listino
    // mostra il nome mentre il percorso assoluto non risolve. Si simula con un
    // box il cui `drive_c` è un symlink penzolante: l'enumerazione vede la voce,
    // lo `stat` assoluto di `drive_c` fallisce. `find` deve ricadere sul listino.
    let ghostURL = prefixRoot.appendingPathComponent("ghost-box")
    try? fm.createDirectory(at: ghostURL, withIntermediateDirectories: true)
    try? fm.createSymbolicLink(
        at: ghostURL.appendingPathComponent("drive_c"),
        withDestinationURL: prefixRoot.appendingPathComponent("missing-target"))
    let names = (try? fm.contentsOfDirectory(atPath: prefixRoot.path)) ?? []
    h.check(names.contains("ghost-box"), "the listing shows ghost-box by name")
    h.check(!fm.fileExists(atPath: ghostURL.appendingPathComponent("drive_c").path),
            "the absolute drive_c does not resolve (the fast path fails)")
    h.equal(Prefix.find("ghost-box", paths: paths)?.name, "ghost-box",
            "find falls back to enumeration when the absolute stat fails")

    // 2) Il lock tenuto fa **rifiutare** una mutazione di libreria; `.stale` no.
    let runtime = ResolvedRuntime(kind: .dxmfWine, wineBinary: "/usr/bin/true",
                                  version: "wine-11.10", wineMajor: 11,
                                  gptkApp: nil, hasD3DMetal: false, rosettaAvailable: false)
    let locked = "newbox"
    let held = try? BoxLock.acquire(box: locked, config: config,
                                    command: "gx steam install newbox",
                                    reason: "install", wait: 0)
    h.check(held != nil, "test holds the box lock")
    do {
        _ = try Prefix.create(locked, config: config, runtime: runtime)
        h.check(false, "Prefix.create must be refused while the box lock is held")
    } catch let BoxLock.LockError.heldBy(info) {
        h.equal(info.command, "gx steam install newbox",
                "the refusal names what the holder is doing")
        h.check(info.pidAlive, "the refusal names a live pid and its age")
    } catch {
        h.check(false, "Prefix.create refused with the wrong error: \(error)")
    }
    held?.release()

    // `.stale` = si può procedere (e si dichiara).
    let staleBox = "stale-box"
    let staleURL = BoxLock.lockURL(box: staleBox, config: config)
    try? fm.createDirectory(at: staleURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    let stale = BoxLockInfo(pid: 999_999, command: "gone", reason: "crash",
                            startedAt: ISO8601DateFormatter().string(from: Date()), box: staleBox)
    try? JSONEncoder().encode(stale).write(to: staleURL)
    do {
        let made = try Prefix.create(staleBox, config: config, runtime: runtime)
        h.equal(made.name, staleBox, "a stale lock does not block Prefix.create")
    } catch {
        h.check(false, "a stale lock must allow Prefix.create: \(error)")
    }

    // 4) Steam non porta **mai** il contratto dxmf; il gioco sì.
    let stage = root.appendingPathComponent("stage/wine")
    for module in ["d3d11", "dxgi"] {
        for (dir, ext) in [("x86_64-windows", "dll"), ("x86_64-unix", "so")] {
            let file = stage.appendingPathComponent("\(dir)/\(module).\(ext)")
            try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? Data([0x7f]).write(to: file)
        }
    }
    let info = DXMF.Info(
        wineBinary: "/usr/bin/true",
        runtimeRoot: root.appendingPathComponent("wine-host"),
        wineVersion: "wine-11.10",
        stageRoot: stage,
        modules: ["d3d11", "dxgi"],
        pinnedVersion: "11.10")
    let steamBox = PrefixRecord(name: "steam-box", url: root.appendingPathComponent("steam-box"))
    let dxmfRuntime = ResolvedRuntime(kind: .dxmfWine, wineBinary: "/usr/bin/true",
                                      version: "wine-11.10", wineMajor: 11,
                                      gptkApp: nil, hasD3DMetal: false,
                                      rosettaAvailable: false, dxmfInfo: info)

    let steamEnv = Steam.steamEnvironment(config: config, prefix: steamBox, runtime: dxmfRuntime)
    h.check(steamEnv["WINEDLLPATH_PREPEND"] == nil,
            "Steam environment never carries WINEDLLPATH_PREPEND")
    h.check(steamEnv["DXMF_DIAG_QUIET"] == nil,
            "Steam environment never carries DXMF_DIAG_QUIET")
    h.check(!(steamEnv["WINEDLLOVERRIDES"] ?? "").contains("d3d11=b"),
            "Steam environment does not force the dxmf builtin modules")

    // Lo stripper puro toglie un contratto dxmf ereditato, lasciando il prefix.
    let tainted: [String: String] = [
        "WINEDLLPATH_PREPEND": stage.path,
        "WINEDLLOVERRIDES": "d3d9,d3d11,dxgi=b;mshtml=",
        "DXMF_DIAG_QUIET": "1",
        "DXMF_FRAME_TIME": "/tmp/gx-frame.log",
        "DXMF_LOCK_DIR": "/tmp/gx-locks",
        "DXMF_GATE_LOCK_WAIT": "300",
    ]
    let clean = Steam.strippingDXMFContract(tainted, dxmfModules: ["d3d9", "d3d11", "dxgi"])
    h.check(clean["WINEDLLPATH_PREPEND"] == nil, "stripper removes WINEDLLPATH_PREPEND")
    h.check(clean["DXMF_DIAG_QUIET"] == nil && clean["DXMF_FRAME_TIME"] == nil
            && clean["DXMF_LOCK_DIR"] == nil && clean["DXMF_GATE_LOCK_WAIT"] == nil,
            "stripper removes the DXMF_* variables")
    h.equal(clean["WINEDLLOVERRIDES"], "mshtml=", "stripper keeps the prefix overrides")

    // Il contratto dxmf invece **deve** arrivare al processo del gioco.
    let gameEnv = Prefix.dxmfLaunchEnvironment(config: config, prefix: steamBox.url, info: info)
    h.equal(gameEnv["WINEDLLPATH_PREPEND"], stage.path,
            "dxmfLaunchEnvironment prepends the stage")
    h.check((gameEnv["WINEDLLOVERRIDES"] ?? "").contains("=b"),
            "dxmfLaunchEnvironment forces the builtin modules (=b)")

    // 5) Risoluzione dell'exe da un `steamapps` finto.
    let appid = "1343240"
    let gameBox = PrefixRecord(name: "game-box", url: root.appendingPathComponent("game-box"))
    let steamapps = gameBox.driveC
        .appendingPathComponent("Program Files (x86)/Steam/steamapps")
    let gameDir = steamapps.appendingPathComponent("common/Thymesia")
    try? fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
    let acf = """
    "AppState"
    {
    \t"appid"\t\t"\(appid)"
    \t"installdir"\t\t"Thymesia"
    }
    """
    try? acf.write(to: steamapps.appendingPathComponent("appmanifest_\(appid).acf"),
                   atomically: true, encoding: .utf8)
    let libraryVDF = """
    "libraryfolders"
    {
    \t"0"
    \t{
    \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
    \t}
    }
    """
    try? libraryVDF.write(to: steamapps.appendingPathComponent("libraryfolders.vdf"),
                          atomically: true, encoding: .utf8)

    try? Data([0x4d, 0x5a]).write(to: gameDir.appendingPathComponent("PlagueProject.exe"))
    do {
        let resolved = try Steam.resolveGameExecutable(appid: appid, prefix: gameBox)
        h.equal(resolved.lastPathComponent, "PlagueProject.exe",
                "one candidate is resolved")
        h.equal(resolved.deletingLastPathComponent().resolvingSymlinksInPath().path,
                gameDir.resolvingSymlinksInPath().path,
                "the resolved candidate lives in installdir")
    } catch {
        h.check(false, "one candidate should resolve: \(error)")
    }

    // Due candidati: rifiuto con l'elenco.
    try? Data([0x4d, 0x5a]).write(to: gameDir.appendingPathComponent("Launcher.exe"))
    do {
        _ = try Steam.resolveGameExecutable(appid: appid, prefix: gameBox)
        h.check(false, "two candidates must be refused")
    } catch let Steam.SteamError.gameExecutableAmbiguous(id, candidates) {
        h.equal(id, appid, "ambiguity names the appid")
        h.equal(Set(candidates.map { URL(fileURLWithPath: $0).lastPathComponent }),
                ["PlagueProject.exe", "Launcher.exe"],
                "ambiguity lists both candidates")
    } catch {
        h.check(false, "two candidates returned the wrong error: \(error)")
    }

    // AppID non installato: rifiuto per nome.
    do {
        _ = try Steam.resolveGameExecutable(appid: "999999", prefix: gameBox)
        h.check(false, "an uninstalled appid must be refused")
    } catch let Steam.SteamError.appNotInstalled(id) {
        h.equal(id, "999999", "the not-installed refusal names the appid")
    } catch {
        h.check(false, "an uninstalled appid returned the wrong error: \(error)")
    }

    // D1 (rilievo del VALIDATOR): `gx game launch` su un box dxmf deve applicare
    // il contratto d'ambiente, come `gx dxmf run` e `gx steam launch`.
    do {
        let cfg = Config(dxmfWineRoot: root.appendingPathComponent("wine-host").path,
                         dxmfStage: stage.path)
        let info = DXMF.Info(
            wineBinary: root.appendingPathComponent("wine-host/bin/wine").path,
            runtimeRoot: root.appendingPathComponent("wine-host"),
            wineVersion: "wine-11.10",
            stageRoot: stage,
            modules: ["d3d11", "dxgi"],
            pinnedVersion: "11.10")
        let boxURL = root.appendingPathComponent("boxes-live/gxdxmf-game")
        try? FileManager.default.createDirectory(
            at: boxURL.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
        let env = Prefix.dxmfLaunchEnvironment(
            config: cfg, prefix: boxURL, info: info,
            diagnostics: DXMF.Diagnostics.defaults(config: cfg), extra: [:])
        h.equal(env["WINEDLLPATH_PREPEND"], stage.path,
                "D1: a dxmf game launch carries WINEDLLPATH_PREPEND")
        // In `WINEDLLOVERRIDES` il `=b` chiude la LISTA di moduli: il contratto è
        // `d3d9,d3d11,dxgi=b`, quindi la sottostringa da cercare è quella intera.
        h.check((env["WINEDLLOVERRIDES"] ?? "").contains("d3d9,d3d11,dxgi=b"),
                "D1: a dxmf game launch forces the dxmf builtin modules")
        // Nessuna regressione sul runtime non-dxmf: quel percorso resta invariato.
        let stagingRT = ResolvedRuntime(kind: .wineStaging, wineBinary: "/usr/bin/true",
                                        version: "wine-11.10", wineMajor: 11, gptkApp: nil,
                                        hasD3DMetal: false, rosettaAvailable: false)
        h.check(stagingRT.dxmf == nil, "D1: a non-dxmf runtime takes the unchanged path")
    }
}
