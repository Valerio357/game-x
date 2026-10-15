import Foundation

/// `gx dxmf doctor [box]` — diagnostica del runtime dxmf e delle **dipendenze
/// del prefix**. Nato dalla richiesta del CEO: «runtime coerente, moduli
/// presenti, DIPENDENZE DEL PREFIX, x64deps, lock libero, orfani zero — e dice
/// cosa manca», per non scoprire una **box nera** (Steam che si apre NERO perché
/// manca dxvk, `DEC-137`).
///
/// La logica sta nella libreria (non nel CLI) per essere testabile dal
/// `gx-selftest` senza eseguire Wine. Il CLI stampa `[ OK ]`/`[WARN]`/`[FAIL]`
/// e mappa `hasFailures` sull'exit code.
public enum DXMFDoctor {

    public enum Status: String, Codable, Sendable {
        case ok = "OK"
        case warn = "WARN"
        case fail = "FAIL"
    }

    public struct Check: Codable, Sendable {
        /// Id stabile (per i test e per la UI): mai riusato con un altro senso.
        public let id: String
        public let status: Status
        public let title: String
        public let detail: String?
        public let remedy: String?

        public init(id: String, status: Status, title: String,
                    detail: String? = nil, remedy: String? = nil) {
            self.id = id
            self.status = status
            self.title = title
            self.detail = detail
            self.remedy = remedy
        }
    }

    public struct Report: Codable, Sendable {
        public let checks: [Check]

        public init(checks: [Check]) { self.checks = checks }

        public var hasFailures: Bool { checks.contains { $0.status == .fail } }
        public var counts: (ok: Int, warn: Int, fail: Int) {
            (checks.filter { $0.status == .ok }.count,
             checks.filter { $0.status == .warn }.count,
             checks.filter { $0.status == .fail }.count)
        }
    }

    /// I due verb winetricks essenziali per Steam (`DEC-137`).
    public static let requiredVerbs = ["d3dcompiler_47", "vcrun2022"]

    /// `box == nil` ⇒ solo le parti globali (1-4, 7) e lo dichiara.
    public static func run(config: Config, box: String? = nil) -> Report {
        var checks: [Check] = []
        let paths = config.resolvedPaths()

        let info = DXMF.discover(config: config)
        let depsDir = DXMF.resolveDepsDir(config: config, runtimeRoot: info?.runtimeRoot)
        let depsLibs = depsDir.map { DXMF.providedSupportLibraries(in: $0) } ?? []
        let hostLibs = info?.hostCapabilities.systemLibraries ?? []
        let allLibs = Set(hostLibs).union(depsLibs)

        // 1) Runtime coerente: host + versione + pin (major.minor).
        if let info {
            let pin = info.pinnedVersion ?? DXMF.pinnedWineVersion
            let source = info.pinSource.map { "from \($0)" } ?? "default \(DXMF.pinnedWineVersion)"
            if let mismatch = info.versionMismatch {
                checks.append(.init(
                    id: "runtime", status: .fail,
                    title: "runtime coherent — host \(info.wineVersion) vs pin \(pin)",
                    detail: mismatch,
                    remedy: "install a host whose major.minor matches the module pin "
                        + "(\(pin)); e.g. `gx runtime install --from-source`"))
            } else {
                checks.append(.init(
                    id: "runtime", status: .ok,
                    title: "runtime coherent — host \(info.wineVersion), pin \(pin)",
                    detail: "\(info.wineBinary) (pin \(source))"))
            }
        } else {
            checks.append(.init(
                id: "runtime", status: .fail,
                title: "runtime coherent — no dxmf host found",
                detail: "host \(config.dxmfWineRoot) has no executable bin/wine (or no stage)",
                remedy: "install it with `gx runtime install --from-source`, or set "
                    + "GX_DXMF_WINE_ROOT / GX_DXMF_STAGE"))
        }

        // 2) Moduli presenti: PE + unix, con il percorso. Si scansionano le due
        // cartelle (non solo `info.modules`, che `discover` filtra già ai moduli
        // completi): così un half mancante è un FAIL nominato, non un silenzio.
        if let info {
            let peDir = info.stageRoot.appendingPathComponent("x86_64-windows")
            let unixDir = info.stageRoot.appendingPathComponent("x86_64-unix")
            let peNames = ((try? FileManager.default.contentsOfDirectory(
                at: peDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "dll" }
                .map { $0.deletingPathExtension().lastPathComponent }
            let names = Set(peNames).union(info.modules).sorted()
            if names.isEmpty {
                checks.append(.init(
                    id: "modules", status: .fail,
                    title: "modules present — none staged",
                    detail: "stage \(info.stageRoot.path)",
                    remedy: "re-stage d3d11/dxgi under \(info.stageRoot.path) "
                        + "(`gx runtime install --from-source`)"))
            }
            for name in names {
                let pe = peDir.appendingPathComponent("\(name).dll")
                let unix = unixDir.appendingPathComponent("\(name).so")
                let peOK = FileManager.default.fileExists(atPath: pe.path)
                let unixOK = FileManager.default.fileExists(atPath: unix.path)
                if peOK && unixOK {
                    checks.append(.init(
                        id: "module.\(name)", status: .ok,
                        title: "module \(name) — PE + unix present",
                        detail: "PE \(pe.path) ; unix \(unix.path)"))
                } else {
                    var missing: [String] = []
                    if !peOK { missing.append("PE \(pe.path)") }
                    if !unixOK { missing.append("unix \(unix.path)") }
                    checks.append(.init(
                        id: "module.\(name)", status: .fail,
                        title: "module \(name) — missing half",
                        detail: missing.joined(separator: "; "),
                        remedy: "re-stage both halves of '\(name)' under "
                            + "\(info.stageRoot.path)"))
                }
            }
        } else {
            checks.append(.init(
                id: "modules", status: .fail,
                title: "modules present — cannot check without a host",
                remedy: "install the dxmf runtime first"))
        }

        // 3) Capacità dell'host: le 2 patch CodeWeavers + librerie di sistema,
        //    distinguendo «libs nell'host» da «libs via cartella deps».
        if let info {
            let caps = info.hostCapabilities
            if caps.canLoadDXMFModules {
                checks.append(.init(
                    id: "capabilities.patches", status: .ok,
                    title: "host capabilities — both CodeWeavers patches present",
                    detail: "ntdll.so WINEDLLPATH_PREPEND; winemac.so macdrv_functions"))
            } else {
                var missing: [String] = []
                if !caps.hasDllPathPrepend { missing.append("ntdll.so lacks WINEDLLPATH_PREPEND") }
                if !caps.hasMacdrvBridge { missing.append("winemac.so lacks macdrv_functions") }
                checks.append(.init(
                    id: "capabilities.patches", status: .fail,
                    title: "host capabilities — missing CodeWeavers patch(es)",
                    detail: missing.joined(separator: "; "),
                    remedy: "use a complete + patched host (`gx runtime install --from-source`); "
                        + "stock Wine cannot load the dxmf modules"))
            }

            let stillMissing = DXMF.HostCapabilities.requiredLibraries.filter { !allLibs.contains($0) }
            if stillMissing.isEmpty {
                let location = hostLibs.count == DXMF.HostCapabilities.requiredLibraries.count
                    ? "in the host" : "via the deps folder"
                checks.append(.init(
                    id: "capabilities.libraries", status: .ok,
                    title: "host capabilities — system libraries \(location)",
                    detail: "host: \(hostLibs.isEmpty ? "none" : hostLibs.joined(separator: ", "))"
                        + "; deps: \(depsLibs.isEmpty ? "none" : depsLibs.joined(separator: ", "))"))
            } else {
                checks.append(.init(
                    id: "capabilities.libraries", status: .warn,
                    title: "host capabilities — system libraries missing",
                    detail: "not in the host and not in the deps folder: "
                        + stillMissing.joined(separator: ", "),
                    remedy: "point GX_DXMF_DEPS at a folder holding freetype, MoltenVK "
                        + "and gnutls, or install them in the host"))
            }
        } else {
            checks.append(.init(
                id: "capabilities", status: .fail,
                title: "host capabilities — cannot check without a host",
                remedy: "install the dxmf runtime first"))
        }

        // 4) x64deps: cartella risolta e quali delle tre fornisce; se le librerie
        //    non sono né nell'host né nelle deps ⇒ FAIL con il rimedio.
        let libsMissingEverywhere = DXMF.HostCapabilities.requiredLibraries.filter {
            !allLibs.contains($0)
        }
        if let depsDir {
            if libsMissingEverywhere.isEmpty {
                let provided = depsLibs.isEmpty
                    ? "none of freetype, MoltenVK, gnutls" : depsLibs.joined(separator: ", ")
                checks.append(.init(
                    id: "x64deps", status: .ok,
                    title: "x64deps — \(depsDir.path)",
                    detail: "provides \(provided)"
                        + (hostLibs.isEmpty ? "" : "; host also has \(hostLibs.joined(separator: ", "))")))
            } else {
                checks.append(.init(
                    id: "x64deps", status: .fail,
                    title: "x64deps — libraries missing everywhere",
                    detail: "not in the host (\(hostLibs.isEmpty ? "none" : hostLibs.joined(separator: ", "))) "
                        + "and not in \(depsDir.path): \(libsMissingEverywhere.joined(separator: ", "))",
                    remedy: "put freetype/MoltenVK/gnutls in GX_DXMF_DEPS (or [dxmf] deps), "
                        + "or install them in the host"))
            }
        } else if libsMissingEverywhere.isEmpty {
            checks.append(.init(
                id: "x64deps", status: .ok,
                title: "x64deps — not needed (the host provides freetype, MoltenVK, gnutls)"))
        } else {
            checks.append(.init(
                id: "x64deps", status: .fail,
                title: "x64deps — no deps folder resolved",
                detail: "the host lacks \(libsMissingEverywhere.joined(separator: ", ")) and no "
                    + "x64deps / GX_DXMF_DEPS folder was found",
                remedy: "set GX_DXMF_DEPS (or [dxmf] deps) to a folder with "
                    + "freetype/MoltenVK/gnutls, or install them in the host"))
        }

        // 5) Dipendenze del prefix (solo con una box data).
        let record = box.flatMap { Prefix.find($0, paths: paths) }
        if let box {
            if let record {
                appendPrefixChecks(&checks, record: record, box: box)
            } else {
                checks.append(.init(
                    id: "box", status: .fail,
                    title: "box '\(box)' not found",
                    detail: paths.prefixRoot.path,
                    remedy: "create it with `gx box create \(box) --runtime dxmf`"))
            }
        }

        // 6) Lock (solo con una box esistente).
        if let box, record != nil {
            switch BoxLock.state(box: box, config: config) {
            case .free:
                checks.append(.init(id: "lock", status: .ok, title: "lock free"))
            case .held(let holder):
                checks.append(.init(
                    id: "lock", status: .warn,
                    title: "lock held by pid \(holder.pid) (\(holder.command))",
                    detail: "age \(Int(holder.ageSeconds))s; reason \(holder.reason)",
                    remedy: "wait for the mutation to finish; use --force only consciously"))
            case .stale(let holder):
                checks.append(.init(
                    id: "lock", status: .ok,
                    title: "lock stale (recoverable)",
                    detail: "pid \(holder.pid) (\(holder.command)); \(holder.reason)"))
            }
        }

        // 7) Orfani winedbg: >100 = WARN, isCrowded = FAIL.
        let orphans = Orphans.scan()
        var orphanDetail = "\(orphans.winedbg.count) winedbg --auto orphans, "
            + "\(orphans.totalProcesses) processes"
        if let limit = orphans.softLimit { orphanDetail += " / \(limit) max" }
        if orphans.isCrowded {
            checks.append(.init(
                id: "orphans", status: .fail,
                title: "winedbg orphans — process table crowded",
                detail: orphanDetail,
                remedy: "gx dxmf run --sweep (sweeps `winedbg --auto`)"))
        } else if orphans.winedbg.count > 100 {
            checks.append(.init(
                id: "orphans", status: .warn,
                title: "winedbg orphans — more than 100",
                detail: orphanDetail,
                remedy: "gx dxmf run --sweep (sweeps `winedbg --auto`)"))
        } else {
            checks.append(.init(id: "orphans", status: .ok,
                                title: "winedbg orphans", detail: orphanDetail))
        }

        return Report(checks: checks)
    }

    // MARK: - Dipendenze del prefix

    /// Il punto che avrebbe evitato la **box nera**: Steam presente + shim,
    /// wine-mono, override dxvk nel registry, verb winetricks essenziali.
    static func appendPrefixChecks(_ checks: inout [Check], record: PrefixRecord, box: String) {
        let depsRemedy = "gx deps install \(box) dxvk dxvk1103 d3dcompiler_47 vcrun2022"

        // Steam + shim (bug #60263: senza shim la UI si pianta).
        if record.hasSteam {
            if Shim.isInstalled(in: record) {
                checks.append(.init(id: "prefix.steam", status: .ok,
                                    title: "prefix Steam — installed, shim present"))
            } else {
                checks.append(.init(
                    id: "prefix.steam", status: .fail,
                    title: "prefix Steam — shim missing",
                    detail: "steamwebhelper is the real one (Wine bug #60263: the UI will hang)",
                    remedy: "gx steam repair \(box)"))
            }
        } else {
            checks.append(.init(
                id: "prefix.steam", status: .warn,
                title: "prefix Steam — not installed",
                detail: "fine for a direct dxmf game; install it for a Steam box",
                remedy: "gx steam install \(box)"))
        }

        // wine-mono: la UI di Steam / CEF ne ha bisogno.
        if DXMT.monoInstalled(in: record.url) {
            checks.append(.init(id: "prefix.mono", status: .ok,
                                title: "prefix wine-mono — installed"))
        } else if record.hasSteam {
            checks.append(.init(
                id: "prefix.mono", status: .fail,
                title: "prefix wine-mono — missing",
                detail: "the Steam UI (CEF) needs wine-mono",
                remedy: "gx runtime mono (or gx steam repair \(box))"))
        } else {
            checks.append(.init(id: "prefix.mono", status: .warn,
                                title: "prefix wine-mono — missing",
                                remedy: "gx runtime mono"))
        }

        // Override dxvk nel registry: la loro assenza è la causa nota della UI
        // Steam NERA (`DEC-137`). Per il gioco dxmf l'override è `=b` a runtime.
        let overrides = dxvkOverrides(in: record.url)
        let hasD3D11 = hasNativeOverride("d3d11", in: overrides)
        let hasDXGI = hasNativeOverride("dxgi", in: overrides)
        if hasD3D11 && hasDXGI {
            checks.append(.init(
                id: "prefix.dxvk", status: .ok,
                title: "prefix dxvk overrides — d3d11 and dxgi native",
                detail: "\(record.url.path)/user.reg [Software\\\\Wine\\\\DllOverrides]"))
        } else {
            var missing: [String] = []
            if !hasD3D11 { missing.append("d3d11") }
            if !hasDXGI { missing.append("dxgi") }
            let detail = "missing native override for \(missing.joined(separator: ", ")) — "
                + "the Steam UI composes in D3D11 and opens BLACK (DEC-137)"
            if record.hasSteam {
                checks.append(.init(id: "prefix.dxvk", status: .fail,
                                    title: "prefix dxvk overrides — missing", detail: detail,
                                    remedy: depsRemedy))
            } else {
                checks.append(.init(id: "prefix.dxvk", status: .warn,
                                    title: "prefix dxvk overrides — not set", detail: detail,
                                    remedy: depsRemedy))
            }
        }

        // Verb winetricks essenziali: si usano le sentinelle di `Deps`.
        let detected = Set(Deps.detectBySentinel(in: record))
        let missingVerbs = requiredVerbs.filter { !detected.contains($0) }
        if missingVerbs.isEmpty {
            checks.append(.init(
                id: "prefix.verbs", status: .ok,
                title: "prefix winetricks — d3dcompiler_47, vcrun2022 present"))
        } else {
            checks.append(.init(
                id: "prefix.verbs", status: .fail,
                title: "prefix winetricks — missing \(missingVerbs.joined(separator: ", "))",
                remedy: depsRemedy))
        }
    }

    /// Override del registry nella sezione `[Software\\Wine\\DllOverrides]` di
    /// `user.reg`. Chiave normalizzata senza `*` iniziale.
    static func dxvkOverrides(in prefix: URL) -> [String: String] {
        let url = prefix.appendingPathComponent("user.reg")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var inSection = false
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSection = line.contains("DllOverrides")
                continue
            }
            guard inSection, let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<eq]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if key.hasPrefix("*") { key.removeFirst() }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    static func hasNativeOverride(_ dll: String, in overrides: [String: String]) -> Bool {
        overrides[dll]?.contains("native") ?? false
    }
}
