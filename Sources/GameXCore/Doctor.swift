import Foundation

/// Environment diagnostics (DESIGN §13).
public enum Doctor {

    public enum Status: String, Codable, Sendable {
        case ok = "OK"
        case warn = "WARN"
        case fail = "FAIL"
    }

    public struct Check: Codable, Sendable {
        public let status: Status
        public let title: String
        public let detail: String?
        public let remedy: String?
        /// Azione che la GUI può offrire (nil = solo testo).
        public let action: Action?
        /// Id del componente `Setup` collegato (per `.installComponent`).
        public let componentID: String?

        public init(status: Status, title: String, detail: String? = nil, remedy: String? = nil,
                    action: Action? = nil, componentID: String? = nil) {
            self.status = status
            self.title = title
            self.detail = detail
            self.remedy = remedy
            self.action = action
            self.componentID = componentID
        }
    }

    /// Cosa può fare la Dashboard su questo check.
    public enum Action: String, Codable, Sendable {
        case installComponent      // installa il componente `Setup` in `componentID`
        case buildRuntime          // esegue `gx runtime build-gptk`
        case openAccessibility     // apre Privacy → Accessibilità
        case openInputMonitoring   // apre Privacy → Monitoraggio input
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

    static let compilerPath = "/opt/homebrew/bin/x86_64-w64-mingw32-gcc"
    static let cabextractPath = "/opt/homebrew/bin/cabextract"

    public static func run(config: Config) -> Report {
        let paths = config.resolvedPaths()
        var checks: [Check] = []
        let resolved = Runtime.resolve(config: config)

        // System
        let gpu = GPUInfo.detect()
        var systemDetail = [gpu.chip ?? "?", gpu.gpuCores.map { "\($0) GPU cores" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        if !gpu.isAppleSilicon { systemDetail += " — not Apple Silicon" }
        checks.append(.init(
            status: gpu.isAppleSilicon ? .ok : .warn,
            title: "macOS \(gpu.macOSVersion) (\(gpu.architecture))",
            detail: systemDetail.isEmpty ? nil : systemDetail))

        // Rosetta
        checks.append(Runtime.rosettaAvailable()
            ? .init(status: .ok, title: "Rosetta 2")
            : .init(status: .fail, title: "Rosetta 2 missing",
                    remedy: "softwareupdate --install-rosetta",
                    action: .installComponent, componentID: "rosetta"))

        // Permessi TCC (input): causa misurata di tastiera/pad che non arrivano al gioco.
        let appHint = resolved?.runtimeRoot.map { "\($0)/bin/wine" }
            ?? "the runtime's wine binary"
        let ax = Permissions.accessibility()
        checks.append(.init(
            status: ax.isGranted ? .ok : .warn,
            title: "Accessibility (keyboard/mouse)",
            detail: ax.isGranted ? nil : "grant to GameX.app/Terminal and to \(appHint)",
            remedy: ax.isGranted ? nil : "System Settings → Privacy & Security → Accessibility → add GameX.app + \(appHint)",
            action: ax.isGranted ? nil : .openAccessibility))
        let im = Permissions.inputMonitoring()
        checks.append(.init(
            status: im.isGranted ? .ok : .warn,
            title: "Input Monitoring (gamepad)",
            detail: im.isGranted ? nil : "winebus/IOKit needs it for controllers",
            remedy: im.isGranted ? nil : "System Settings → Privacy & Security → Input Monitoring → add GameX.app + \(appHint)",
            action: im.isGranted ? nil : .openInputMonitoring))

        // Xcode Command Line Tools: servono per compilare Wine (wine-cx) e lo shim.
        let cltResult = try? ProcessRunner.run("/usr/bin/xcode-select", ["-p"])
        let cltOK = cltResult?.success == true
        checks.append(.init(
            status: cltOK ? .ok : .fail,
            title: cltOK ? "Xcode Command Line Tools" : "Xcode Command Line Tools missing",
            detail: cltOK ? cltResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : "needed to build the runtime and the Steam shim",
            remedy: cltOK ? nil : "xcode-select --install",
            action: cltOK ? nil : .installComponent, componentID: "xcode-clt"))

        // Homebrew: fonte di winetricks / mingw-w64 / cabextract.
        if let brew = Setup.brewPath {
            checks.append(.init(status: .ok, title: "Homebrew", detail: brew))
        } else {
            checks.append(.init(status: .warn, title: "Homebrew missing",
                                remedy: "install from https://brew.sh (needed for winetricks, mingw-w64, cabextract)",
                                action: .installComponent, componentID: "homebrew"))
        }

        // Runtime
        if let rt = resolved {
            checks.append(.init(status: .ok, title: "Runtime: \(rt.summary)"))
            if rt.kind == .gptkWine {
                checks.append(rt.hasD3DMetal
                    ? .init(status: .ok, title: "D3DMetal present")
                    : .init(status: .warn, title: "D3DMetal not detected in GPTK",
                            remedy: "update GPTK from developer.apple.com"))
            }
            if !rt.supportsModernSteam {
                checks.append(.init(status: .warn,
                                    title: "Runtime too old for the Steam UI (\(rt.version))",
                                    remedy: "use the wine-gptk runtime (Wine ≥ 8)"))
            }
        } else {
            checks.append(.init(status: .fail, title: "No Wine runtime found",
                                detail: "build the wine-gptk runtime (Wine CodeWeavers + D3DMetal)",
                                remedy: "gx runtime build-gptk",
                                action: .buildRuntime))
        }

        // Runtime auto-consistente wine-gptk (D3DMetal): è il default supportato.
        if let d3dm = Runtime.d3dmetalRuntimes(config: config).first {
            checks.append(.init(status: .ok, title: "Runtime wine-gptk (D3DMetal) — default",
                                detail: d3dm.summary))
        } else {
            // The Wine base is downloaded automatically; the manual piece is D3DMetal,
            // which comes from Apple's Game Porting Toolkit DMG.
            let hasDMG = gptkDMG() != nil
            let wineBase = WineBase.isInstalled()
            var notes: [String] = []
            if !hasDMG { notes.append("Apple Game Porting Toolkit 4 DMG (developer.apple.com)") }
            if !wineBase { notes.append("Wine base — will be downloaded automatically") }
            checks.append(.init(
                status: .fail, title: "Runtime wine-gptk (D3DMetal) not installed",
                detail: notes.isEmpty ? "prerequisites look present — press Build runtime"
                                      : "needed: " + notes.joined(separator: ", "),
                remedy: hasDMG ? "press Build runtime"
                               : "download Apple's GPTK 4 DMG, then press Build runtime",
                action: .buildRuntime))
        }

        // Feature del runtime (SDL2 = controller/gamepad, mono = UI di Steam).
        if let root = resolved?.runtimeRoot {
            let feats = RuntimeFeatures.probe(runtimeRoot: URL(fileURLWithPath: root))
            let flag = { (v: Bool) in v ? "✓" : "✗" }
            var detail = "source: \(feats.source)"
            if !feats.sdl2 { detail += " — SDL2 missing: controllers/gamepads will NOT work" }
            if !feats.mono { detail += " — wine-mono missing: the Steam UI may not start" }
            checks.append(.init(
                status: feats.sdl2 ? .ok : .warn,
                title: "Runtime features  sdl2=\(flag(feats.sdl2)) vulkan=\(flag(feats.vulkan)) mono=\(flag(feats.mono))",
                detail: detail,
                remedy: feats.sdl2 ? nil : "rebuild the runtime with SDL2",
                action: feats.sdl2 ? nil : .buildRuntime))
        }

        // GPTK di sistema: non serve se abbiamo già un runtime auto-consistente.
        let gptkInstalls = GPTK.discover(config: config)
        let macOSMajor = gpu.macOSMajor ?? 26
        let hasSelfContained = !Runtime.dxmtRuntimes(config: config).isEmpty
            || !Runtime.d3dmetalRuntimes(config: config).isEmpty
        if hasSelfContained {
            checks.append(.init(status: .ok, title: "System GPTK not required",
                                detail: "self-contained Game-X runtime installed"
                                    + (gptkInstalls.isEmpty ? "" : " (\(gptkInstalls.count) system GPTK install(s) ignored)")))
        } else {
            let verdict = GPTK.verdict(installs: gptkInstalls, macOSMajor: macOSMajor)
            checks.append(.init(status: verdict.status, title: verdict.message,
                                remedy: verdict.status == .warn ? GPTK.installHint(for: macOSMajor) : nil))
        }

        // External tools
        checks.append(toolCheck(config.winetricks, name: "winetricks",
                                versionArgs: ["--version"], remedy: "brew install winetricks",
                                componentID: "winetricks"))
        checks.append(toolCheck(compilerPath, name: "mingw-w64",
                                versionArgs: ["--version"],
                                remedy: "brew install mingw-w64 (for `gx steam repair`)",
                                componentID: "mingw"))
        checks.append(toolCheck(cabextractPath, name: "cabextract",
                                versionArgs: ["--version"],
                                remedy: "brew install cabextract (for winetricks)",
                                componentID: "cabextract"))

        // Boxes (prefixes)
        let boxes = Prefix.list(paths: paths)
        if boxes.isEmpty {
            checks.append(.init(status: .ok, title: "No boxes yet (create one with `gx prefix create`)"))
        } else {
            let steamBoxes = boxes.filter { $0.hasSteam }
            checks.append(.init(status: .ok, title: "\(boxes.count) boxes, \(steamBoxes.count) with Steam",
                                detail: boxes.map { $0.name }.joined(separator: ", ")))
            for b in steamBoxes {
                let shimOK = Shim.isInstalled(in: b)
                checks.append(.init(
                    status: shimOK ? .ok : .warn,
                    title: "Steam in '\(b.name)': shim \(shimOK ? "ok" : "needs repair")",
                    remedy: shimOK ? nil : "gx steam repair \(b.name)"))
            }
        }

        // Disk space (runtime ~2 GB + box ~20-25 GB with a game)
        if let free = freeDiskBytes(at: paths.prefixRoot) {
            let gb = Double(free) / 1_073_741_824
            checks.append(.init(status: gb < 30 ? .warn : .ok,
                                title: String(format: "Free disk space: %.1f GB", gb),
                                remedy: gb < 30 ? "free up space: runtime (~2 GB) + box (~20-25 GB with a game)" : nil))
        }

        // Metal 4: la versione che conta è il D3DMetal del runtime in uso.
        let runtimeD3D = resolved?.d3dmetal?.d3dmetalVersion
        let gptkVersion = runtimeD3D.map { "D3DMetal \($0)" }
            ?? resolved.flatMap { $0.kind == .gptkWine ? "GPTK \($0.version)" : nil }
        let metal4 = gpu.metal4Verdict(gptkVersion: gptkVersion)
        checks.append(.init(status: metal4.hasPrefix("Metal 4 available") ? .ok : .warn,
                            title: metal4,
                            remedy: metal4.hasPrefix("Metal 4 unavailable") ? "Metal 4 is only needed by DX12/Metal 4 games; DX11 games use Metal 3" : nil))

        // Missing components (solo non opzionali: Wine Staging/GPTK di sistema non servono)
        let missing = Setup.status(config: config).filter { !$0.installed && !$0.optional }
        if !missing.isEmpty {
            let installable = missing.filter { $0.installable }
            checks.append(.init(
                status: .warn,
                title: "\(missing.count) missing components: \(missing.map { $0.title }.joined(separator: ", "))",
                remedy: installable.isEmpty ? "install manually" : "gx setup (or 'Install missing' in the app)"))
        }

        return Report(checks: checks)
    }

    static func toolCheck(_ path: String, name: String, versionArgs: [String], remedy: String,
                          componentID: String? = nil) -> Check {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Check(status: .warn, title: "\(name) not found", detail: path, remedy: remedy,
                         action: componentID == nil ? nil : .installComponent, componentID: componentID)
        }
        let version = ProcessRunner.firstLine(path, versionArgs) ?? "present"
        return Check(status: .ok, title: "\(name): \(version)")
    }

    /// Apple's "Evaluation environment for Windows games" DMG (Game Porting Toolkit 4),
    /// looked up in ~/Downloads — the D3DMetal source used by `gx runtime build-gptk`.
    static func gptkDMG() -> String? {
        let dir = "\(NSHomeDirectory())/Downloads"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let match = items.filter {
            $0.hasPrefix("Evaluation_environment_for_Windows_games") && $0.hasSuffix(".dmg")
        }.sorted().last
        return match.map { "\(dir)/\($0)" }
    }

    static func freeDiskBytes(at url: URL) -> Int64? {
        let path = FileManager.default.fileExists(atPath: url.path) ? url.path : NSHomeDirectory()
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? Int64 else { return nil }
        return free
    }
}
