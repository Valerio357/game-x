import Foundation

/// Integrazione Steam (DESIGN §11).
public enum Steam {

    /// Flag di avvio obbligatori (DESIGN §11.3).
    public static let launchFlags = ["-no-cef-sandbox", "-forcedesktopscaling", "1", "-noverifyfiles"]

    public static let setupURL = "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"

    public enum Status: Sendable {
        case notInstalled
        case installed(shimInstalled: Bool)
    }

    public enum SteamError: Error, CustomStringConvertible {
        case notInstalled(String)
        case setupUnavailable(String)
        case setupFailed(Int32)
        case updateTimeout(Int)
        case runtimeTooOld(String)
        case appNotInstalled(String)
        case gameExecutableNotFound(String)
        case gameExecutableAmbiguous(String, [String])

        public var description: String {
            switch self {
            case .notInstalled(let n): return "Steam is not installed in box '\(n)'"
            case .setupUnavailable(let p): return "SteamSetup.exe not found (\(p)); download it or check your network"
            case .setupFailed(let c): return "SteamSetup.exe exited with code \(c)"
            case .updateTimeout(let s): return "timed out waiting for the Steam update (\(s)s)"
            case .runtimeTooOld(let v): return "Wine runtime too old for Steam (\(v)); Wine >= 8 required (use Wine Staging)"
            case .appNotInstalled(let id):
                return "appid \(id) is not installed in this box (no appmanifest_\(id).acf); install it in Steam first"
            case .gameExecutableNotFound(let id):
                return "appid \(id) is installed but no game executable was found in its install directory; "
                    + "launch it with `gx dxmf run <box> -- <exe>`"
            case .gameExecutableAmbiguous(let id, let paths):
                return "appid \(id) has \(paths.count) candidate executables; refusing to guess:\n  "
                    + paths.joined(separator: "\n  ")
                    + "\nlaunch one explicitly with `gx dxmf run <box> -- <exe>`"
            }
        }
    }

    public static func status(in prefix: PrefixRecord) -> Status {
        guard prefix.hasSteam else { return .notInstalled }
        return .installed(shimInstalled: Shim.isInstalled(in: prefix))
    }

    // MARK: - Environment (Steam never carries the dxmf contract)

    /// Ambiente per i processi **Steam** (installer, update, UI, `wineserver -k`):
    /// base del prefix con il contratto dxmf **rimosso**. La UI di Steam compone
    /// in D3D11 via dxvk: con i moduli dxmf diventa **nera**. Il contratto dxmf si
    /// applica **solo** al processo del gioco (`Prefix.dxmfLaunchEnvironment`).
    public static func steamEnvironment(
        config: Config, prefix: PrefixRecord, runtime: ResolvedRuntime
    ) -> [String: String] {
        let base = Prefix.baseEnvironment(config: config, prefix: prefix.url, runtime: runtime)
        let modules = runtime.dxmf.map {
            Set(DXMF.baseOverrideModules).union($0.modules)
        } ?? []
        return strippingDXMFContract(base, dxmfModules: modules)
    }

    /// Rimuove da un ambiente ogni traccia del contratto dxmf:
    /// `WINEDLLPATH_PREPEND`, i `DXMF_*` e i moduli dxmf da `WINEDLLOVERRIDES`
    /// (restano gli override del prefix, cioè dxvk). Pura e testabile.
    public static func strippingDXMFContract(
        _ env: [String: String], dxmfModules: Set<String>
    ) -> [String: String] {
        var out = env
        out.removeValue(forKey: "WINEDLLPATH_PREPEND")
        for key in ["DXMF_DIAG_QUIET", "DXMF_FRAME_TIME", "DXMF_LOCK_DIR", "DXMF_GATE_LOCK_WAIT"] {
            out.removeValue(forKey: key)
        }
        if let overrides = out["WINEDLLOVERRIDES"] {
            let cleaned = removingDLLOverrides(dxmfModules, from: overrides)
            if cleaned.isEmpty { out.removeValue(forKey: "WINEDLLOVERRIDES") }
            else { out["WINEDLLOVERRIDES"] = cleaned }
        }
        return out
    }

    /// Toglie da `WINEDLLOVERRIDES` le voci dei moduli indicati, preservando
    /// gruppi e altri override.
    static func removingDLLOverrides(_ modules: Set<String>, from overrides: String) -> String {
        let groups = overrides.split(separator: ";", omittingEmptySubsequences: false)
        var keptGroups: [String] = []
        for group in groups {
            let entries = group.split(separator: ",", omittingEmptySubsequences: false)
            let kept = entries.filter { entry in
                let name = entry.split(separator: "=", maxSplits: 1).first.map(String.init)
                    ?? String(entry)
                return !modules.contains(name.trimmingCharacters(in: .whitespaces))
            }
            let joined = kept.joined(separator: ",")
            if !joined.isEmpty { keptGroups.append(joined) }
        }
        return keptGroups.joined(separator: ";")
    }

    // MARK: - Install (online)

    /// Installa Steam **scaricandolo online** e applica lo shim.
    ///
    /// Passi:
    /// 1. scarica (o usa) `SteamSetup.exe` ed esegue `/S` → bootstrapper;
    /// 2. avvia Steam per completare il download del client (con timeout);
    /// 3. applica lo shim `steamwebhelper` (dopo l'update, che altrimenti lo sovrascriverebbe).
    @discardableResult
    public static func install(
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        setupPath: URL? = nil,
        setupDownload: Bool = true,
        waitForUpdate: Bool = true,
        updateTimeout: Int = 900,
        force: Bool = false,
        progress: (String) -> Void = { _ in }
    ) throws -> String {
        try Prefix.refuseIfLocked(box: prefix.name, config: config)
        guard runtime.supportsModernSteam else { throw SteamError.runtimeTooOld(runtime.version) }
        guard prefix.isInitialized else {
            throw SteamError.notInstalled("prefix not initialized: \(prefix.name)")
        }

        if prefix.hasSteam && !force {
            try Shim.ensureInstalled(in: prefix, config: config, force: false)
            Prefix.updateMetaKind(prefix, kind: .steam, runtime: runtime)
            return "Steam already present; shim verified/restored"
        }

        // Sblocca eventuali shim con vecchio `uchg`, altrimenti l'update di Steam fallisce.
        Shim.clearLocks(in: prefix)
        // 1) bootstrapper
        if let setup = try resolveSetup(setupPath: setupPath, download: setupDownload) {
            progress("Eseguo \(setup.lastPathComponent) /S…")
            var env = steamEnvironment(config: config, prefix: prefix, runtime: runtime)
            env["WINEARCH"] = config.arch
            let result = try ProcessRunner.run(runtime.wineBinary, [setup.path, "/S"], environment: env)
            guard result.success else { throw SteamError.setupFailed(result.exitCode) }
        } else {
            throw SteamError.setupUnavailable("~/Downloads/SteamSetup.exe")
        }
        guard prefix.hasSteam else {
            throw SteamError.setupFailed(-1)
        }

        // 2) primo update (scarica il client completo)
        if waitForUpdate {
            try driveUpdate(prefix: prefix, config: config, runtime: runtime,
                            timeout: updateTimeout, progress: progress)
        }

        // 3) shim (dopo l'update)
        progress("Applying the steamwebhelper shim…")
        try Shim.ensureInstalled(in: prefix, config: config, force: false)
        Prefix.updateMetaKind(prefix, kind: .steam, runtime: runtime)
        return "Steam installed online and shim applied"
    }

    /// Avvia Steam, attende che l'update finisca, poi lo ferma.
    static func driveUpdate(
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        timeout: Int,
        progress: (String) -> Void
    ) throws {
        var env = steamEnvironment(config: config, prefix: prefix, runtime: runtime)
        if config.esync { env["WINEESYNC"] = "1" }

        progress("Starting Steam for the first client download…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.wineBinary)
        process.arguments = [prefix.steamExe.path, "-no-cef-sandbox"]
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()

        let steamDir = prefix.driveC.appendingPathComponent("Program Files (x86)/Steam")
        let webhelper = steamDir.appendingPathComponent("bin/cef/cef.win64/steamwebhelper.exe")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        let started = Date()
        var lastReport = Date()
        var complete = false

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 5)
            if isClientReady(webhelper: webhelper) { complete = true; break }
            if Date().timeIntervalSince(lastReport) >= 20 {
                let size = ByteFormat.human(Self.directorySize(steamDir))
                progress("download client in corso… (\(size))")
                lastReport = Date()
            }
        }

        // Ferma Steam: lo shim va applicato a client fermo.
        Prefix.kill(prefix, runtime: runtime)
        Thread.sleep(forTimeInterval: 2)

        guard complete else {
            let elapsed = Int(Date().timeIntervalSince(started))
            throw SteamError.updateTimeout(elapsed)
        }
    }

    /// Il client completo è pronto quando `cef.win64/steamwebhelper.exe` esiste
    /// ed è stabile (non modificato di recente). È l'unico file che compare solo
    /// a download/extract completato; il testo del bootstrap non è affidabile
    /// perché l'installer scrive già "Update complete".
    static func isClientReady(webhelper: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: webhelper.path),
              let date = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(date) > 8
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Ripristina lo shim dopo un auto-update di Steam. Idempotente.
    @discardableResult
    public static func repair(
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        force: Bool = true
    ) throws -> String {
        try Prefix.refuseIfLocked(box: prefix.name, config: config)
        guard prefix.hasSteam else { throw SteamError.notInstalled(prefix.name) }
        try Shim.ensureInstalled(in: prefix, config: config, force: force)
        Prefix.updateMetaKind(prefix, kind: .steam, runtime: runtime)
        return "shim steamwebhelper reinstallato e protetto"
    }

    /// Trova o scarica SteamSetup.exe.
    static func resolveSetup(setupPath: URL?, download: Bool) throws -> URL? {
        let fm = FileManager.default
        if let setupPath, fm.fileExists(atPath: setupPath.path) { return setupPath }

        let downloads = Paths.url("~/Downloads/SteamSetup.exe")
        if fm.fileExists(atPath: downloads.path) { return downloads }

        guard download else { return nil }
        let dest = Paths.url(DefaultPaths.cacheRoot).appendingPathComponent("SteamSetup.exe")
        try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        Log.shared.info("scarico SteamSetup.exe da \(setupURL)")
        let result = try ProcessRunner.run("/usr/bin/curl", ["-fL", setupURL, "-o", dest.path])
        return result.success && fm.fileExists(atPath: dest.path) ? dest : nil
    }

    // MARK: - Run

    /// Avvia Steam con i flag corretti.
    ///
    /// Auto-riparazione: se all'avvio Steam applica un aggiornamento, sostituisce
    /// `steamwebhelper.exe` con il file reale (niente più `uchg`, altrimenti l'update
    /// fallisce). In quel caso Game-X rileva la sostituzione, ferma Steam, reinstalla
    /// lo shim e rilancia una volta sola, così la UI non resta nera.
    @discardableResult
    public static func run(
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        progress: (String) -> Void = { _ in }
    ) throws -> ProcessResult {
        try Prefix.refuseIfLocked(box: prefix.name, config: config)
        guard prefix.hasSteam else { throw ProcessError.executableNotFound(prefix.steamExe.path) }
        guard runtime.supportsModernSteam else {
            throw ProcessError.launchFailed(
                runtime.wineBinary,
                "Wine runtime too old (\(runtime.version)) for the Steam UI — Wine >= 8 required (DESIGN §11.4)")
        }
        try? Shim.ensureInstalled(in: prefix, config: config, force: false)
        // Crash senza dialog modale (altrimenti ogni crash lascia un winedbg appeso).
        Prefix.disableCrashDialogs(in: prefix, config: config, runtime: runtime)
        // Steam/CEF richiede mono per far nascere il browser (vedi DESIGN-DXMT.md).
        if let info = runtime.dxmt {
            try? DXMT.ensureMono(info: info, prefix: prefix.url,
                                 version: info.monoVersion, config: config)
        }
        // Controller: il runtime include SDL2, quindi Wine espone il pad fisico
        // via XInput (misurato 2026-10-02 con `gxpadlive.exe`: 113 cambi di stato).
        // Con Steam Input ATTIVO invece Steam *aggancia* XInput nell'overlay e
        // nasconde il pad fisico al gioco: se Steam non rileva lui il controller
        // (caso BLE, PID 0x0B13) il gioco non vede niente. Perciò disattiviamo
        // l'override per-app e lasciamo usare il pad fisico.
        if !SteamInput.steamIsRunning(prefix: prefix) {
            let apps = SteamInput.installedAppIDs(in: prefix)
            if !apps.isEmpty,
               let res = try? SteamInput.ensureDisabled(appIDs: apps, in: prefix),
               !res.changed.isEmpty {
                progress("Controller: physical pad via XInput (Steam Input disabled for \(res.changed.count) games)")
            }
        }

        var env = steamEnvironment(config: config, prefix: prefix, runtime: runtime)
        if config.esync { env["WINEESYNC"] = "1" }
        let webhelper = prefix.driveC
            .appendingPathComponent("Program Files (x86)/Steam/bin/cef/cef.win64/steamwebhelper.exe")

        var process = try ProcessRunner.spawn(runtime.wineBinary,
                                              [prefix.steamExe.path] + launchFlags,
                                              environment: env)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 3)
            // L'update di Steam ha rimpiazzato lo shim?
            if FileManager.default.fileExists(atPath: webhelper.path), !Shim.isShim(webhelper) {
                progress("Steam applied an update: re-applying the shim and restarting…")
                Prefix.kill(prefix, runtime: runtime)
                Thread.sleep(forTimeInterval: 3)
                _ = try? Shim.ensureInstalled(in: prefix, config: config, force: false)
                process = try ProcessRunner.spawn(runtime.wineBinary,
                                                  [prefix.steamExe.path] + launchFlags,
                                                  environment: env)
                break
            }
        }
        process.waitUntilExit()
        return ProcessResult(exitCode: process.terminationStatus, stdout: "", stderr: "")
    }

    /// Lancio di un gioco via Steam.
    ///
    /// Se la cache shader non è ancora stata riscaldata per questo gioco, prima
    /// **compila** (warm-up: avvia, aspetta che la cache sia stabile, chiude) e
    /// poi avvia la partita vera — così la compilazione NON avviene in gioco.
    @discardableResult
    public static func launch(
        appid: String,
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        exe: URL? = nil,
        warmupIfCold: Bool = true,
        progress: (String) -> Void = { _ in }
    ) throws -> ProcessResult {
        try Prefix.refuseIfLocked(box: prefix.name, config: config)

        // Runtime dxmf: il gioco deve nascere con il **nostro** ambiente. Un
        // `-applaunch` fa nascere il gioco dal processo Steam già avviato, che
        // non ha il contratto dxmf: risolviamo l'exe e lo lanciamo direttamente
        // (pattern provato da `dxmf/scripts/app-probe.sh`).
        if let info = runtime.dxmf {
            let gameExe: URL
            if let exe {
                gameExe = exe
            } else {
                gameExe = try resolveGameExecutable(appid: appid, prefix: prefix)
            }
            progress("dxmf: resolved game executable: \(gameExe.path)")
            let env = Prefix.dxmfLaunchEnvironment(
                config: config,
                prefix: prefix.url,
                info: info,
                diagnostics: dxmfDiagnostics(from: config),
                extra: ["SteamAppId": appid, "SteamGameId": appid])
            return try ProcessRunner.run(runtime.wineBinary, [gameExe.path], environment: env)
        }

        if let info = runtime.dxmt {
            let cold = !DXMT.isWarmed(appid: appid, for: info)
                || DXMT.cacheGrewSinceWarmup(appid: appid, for: info)
            if warmupIfCold && cold {
                progress("shaders not compiled yet for this game: compiling them NOW (outside the game)")
                _ = try warmup(appid: appid, prefix: prefix, config: config, runtime: runtime,
                               stopOnFinish: true, progress: progress)
                progress("compilation done: starting the game")
            } else {
                progress(DXMT.shaderCacheNotice(for: info))
            }
        }
        return try Prefix.exec(
            prefix,
            command: [prefix.steamExe.path, "-applaunch", appid],
            config: config,
            runtime: runtime
        )
    }

    /// Termina i processi del prefix. Rispetta il lock: se un mutatore è dentro,
    /// non uccide (rifiuto consapevole, dichiarato nel log); `BoxLock` resta la
    /// fonte unica.
    public static func stop(prefix: PrefixRecord, config: Config = Config(), runtime: ResolvedRuntime) {
        if case .held(let info) = BoxLock.state(box: prefix.name, config: config) {
            Log.shared.warn("Steam.stop refused for box '\(prefix.name)': \(info)")
            return
        }
        Prefix.kill(prefix, runtime: runtime)
    }

    // MARK: - Game executable resolution (dxmf)

    /// Risolve l'eseguibile del gioco dai metadati Steam dell'installazione:
    /// `steamapps/appmanifest_<appid>.acf` → `installdir`, più le librerie
    /// elencate da `libraryfolders.vdf`.
    ///
    /// Regole (nessun indovinello): candidati = gli `.exe` **direttamente**
    /// dentro `steamapps/common/<installdir>`; uno solo → lo si usa; più di uno
    /// → si rifiuta elencandoli; nessuno → si rifiuta per nome. Un `--exe`
    /// esplicito (parametro `exe` di `launch`) vince sempre e non passa di qui.
    public static func resolveGameExecutable(appid: String, prefix: PrefixRecord) throws -> URL {
        let fm = FileManager.default
        let steamapps = prefix.driveC
            .appendingPathComponent("Program Files (x86)/Steam/steamapps")

        var steamappsDirs: [URL] = [steamapps]
        let vdf = steamapps.appendingPathComponent("libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8) {
            for raw in libraryPaths(in: text) {
                guard let unix = unixPath(forWindowsPath: raw, prefix: prefix) else { continue }
                let sa = URL(fileURLWithPath: unix).appendingPathComponent("steamapps")
                if !steamappsDirs.contains(where: { $0.standardizedFileURL == sa.standardizedFileURL }) {
                    steamappsDirs.append(sa)
                }
            }
        }

        var installDirs: [URL] = []
        for sa in steamappsDirs {
            let acf = sa.appendingPathComponent("appmanifest_\(appid).acf")
            guard let text = try? String(contentsOf: acf, encoding: .utf8),
                  let installdir = firstQuotedValue("installdir", in: text),
                  !installdir.isEmpty else { continue }
            let dir = sa.appendingPathComponent("common").appendingPathComponent(installdir)
            if fm.fileExists(atPath: dir.path) { installDirs.append(dir) }
        }
        guard !installDirs.isEmpty else { throw SteamError.appNotInstalled(appid) }

        var candidates: [URL] = []
        for dir in installDirs {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries where entry.pathExtension.lowercased() == "exe" {
                if !candidates.contains(where: { $0.standardizedFileURL == entry.standardizedFileURL }) {
                    candidates.append(entry)
                }
            }
        }
        candidates.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        switch candidates.count {
        case 0: throw SteamError.gameExecutableNotFound(appid)
        case 1: return candidates[0]
        default: throw SteamError.gameExecutableAmbiguous(appid, candidates.map { $0.path })
        }
    }

    /// Le librerie elencate da `libraryfolders.vdf` (formato moderno `"path"` e
    /// quello vecchio `"1" "D:\\…"`).
    static func libraryPaths(in vdf: String) -> [String] {
        var paths: [String] = []
        for pattern in ["\"path\"\\s+\"([^\"]*)\"", "\"\\d+\"\\s+\"([A-Za-z]:[^\"]*)\""] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in re.matches(in: vdf, range: NSRange(vdf.startIndex..., in: vdf)) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: vdf) else { continue }
                paths.append(String(vdf[range]))
            }
        }
        return paths
    }

    /// `C:\\Program Files (x86)\\Steam` → `<prefix>/drive_c/Program Files (x86)/Steam`.
    static func unixPath(forWindowsPath win: String, prefix: PrefixRecord) -> String? {
        var normalized = win.replacingOccurrences(of: "\\", with: "/")
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        let chars = Array(normalized)
        guard chars.count >= 2, chars[1] == ":" else { return nil }
        let drive = String(chars[0]).lowercased()
        let rest = String(normalized.dropFirst(2))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = prefix.url.appendingPathComponent("drive_\(drive)")
        return rest.isEmpty ? root.path : root.appendingPathComponent(rest).path
    }

    static func firstQuotedValue(_ key: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s+\"([^\"]*)\""),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    /// Diagnostica dxmf derivata dalla `Config` (il `--frame-log` è un flag CLI e
    /// resta `nil` qui: l'avvio diretto non ha un frame log).
    static func dxmfDiagnostics(from config: Config) -> DXMF.Diagnostics {
        DXMF.Diagnostics.defaults(config: config)
    }

    // MARK: - Warm-up shader

    public struct WarmupReport: Sendable {
        public var startBytes: Int64 = 0
        public var endBytes: Int64 = 0
        public var samples: Int = 0
        public var reason: String = ""
        public var shaderFiles: Int = 0
        public var added: Int64 { endBytes - startBytes }
    }

    /// Avvia il gioco e **aspetta che DXMT compili e salvi gli shader**, poi
    /// (opzionalmente) chiude tutto. È il modo per non pagare la compilazione
    /// durante la partita: la cache resta e gli avvii successivi sono rapidi.
    ///
    /// Si ferma quando la cache smette di crescere per `stallSeconds`
    /// oppure allo scadere di `timeoutSeconds`.
    @discardableResult
    public static func warmup(
        appid: String,
        prefix: PrefixRecord,
        config: Config,
        runtime: ResolvedRuntime,
        timeoutSeconds: Int = 900,
        stallSeconds: Int = 30,
        stopOnFinish: Bool = false,
        progress: (String) -> Void = { _ in }
    ) throws -> WarmupReport {
        var report = WarmupReport()
        guard let info = runtime.dxmt else {
            report.reason = "runtime is not DXMT: no warm-up needed"
            return report
        }
        let start = DXMT.shaderCacheStatus(for: info)
        report.startBytes = start.bytes
        report.shaderFiles = start.files
        progress("shader cache at start: \(start.human)")

        // avvia il gioco via Steam (Steam deve essere già avviato o lo avvia)
        progress("launching the game for warm-up (appid \(appid))…")
        _ = try Prefix.exec(prefix, command: [prefix.steamExe.path, "-applaunch", appid],
                            config: config, runtime: runtime)

        var lastBytes = report.startBytes
        var lastGrowth = Date()
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 5)
            report.samples += 1
            let now = DXMT.shaderCacheStatus(for: info)
            if now.bytes > lastBytes {
                let delta = now.bytes - lastBytes
                progress("shader compilati: +\(ByteFormat.human(delta)) (totale \(ByteFormat.human(now.bytes)))")
                lastBytes = now.bytes
                lastGrowth = Date()
            } else if Date().timeIntervalSince(lastGrowth) >= TimeInterval(stallSeconds) {
                report.reason = "cache stabile da \(stallSeconds)s"
                break
            }
        }
        if report.reason.isEmpty { report.reason = "timeout of \(timeoutSeconds)s reached" }

        let end = DXMT.shaderCacheStatus(for: info)
        report.endBytes = end.bytes
        report.shaderFiles = end.files
        // segna il gioco come riscaldato (la prossima volta: avvio immediato)
        DXMT.markWarmed(appid: appid, for: info, bytes: end.bytes)
        if report.added > 0 {
            progress("warm-up: +\(ByteFormat.human(report.added)) shader data compiled \(report.reason)")
        } else {
            progress("warm-up: no new shaders (\(report.reason))")
        }
        if stopOnFinish {
            progress("closing the game…")
            Prefix.kill(prefix, runtime: runtime)
        } else {
            progress("you can close the game now: the cache is saved and the next run will be fast")
        }
        return report
    }
}
