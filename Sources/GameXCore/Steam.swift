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

        public var description: String {
            switch self {
            case .notInstalled(let n): return "Steam is not installed in box '\(n)'"
            case .setupUnavailable(let p): return "SteamSetup.exe not found (\(p)); download it or check your network"
            case .setupFailed(let c): return "SteamSetup.exe exited with code \(c)"
            case .updateTimeout(let s): return "timed out waiting for the Steam update (\(s)s)"
            case .runtimeTooOld(let v): return "Wine runtime too old for Steam (\(v)); Wine >= 8 required (use Wine Staging)"
            }
        }
    }

    public static func status(in prefix: PrefixRecord) -> Status {
        guard prefix.hasSteam else { return .notInstalled }
        return .installed(shimInstalled: Shim.isInstalled(in: prefix))
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
            var env = Prefix.baseEnvironment(config: config, prefix: prefix.url, runtime: runtime)
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
        var env = Prefix.baseEnvironment(config: config, prefix: prefix.url, runtime: runtime)
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

        var env = Prefix.baseEnvironment(config: config, prefix: prefix.url, runtime: runtime)
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
        warmupIfCold: Bool = true,
        progress: (String) -> Void = { _ in }
    ) throws -> ProcessResult {
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

    /// Termina i processi del prefix.
    public static func stop(prefix: PrefixRecord, runtime: ResolvedRuntime) {
        Prefix.kill(prefix, runtime: runtime)
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
