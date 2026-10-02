import Foundation
import SwiftUI
import GameXCore

/// App state and actions, on top of the shared `GameXCore`.
///
/// Important: **views must not run processes**. Anything that spawns a process or
/// scans the filesystem heavily (`wine --version`, box size, Steam status) is
/// computed here in the background and published as ready data. Doing it inside a
/// SwiftUI `body` causes runloop re-entrancy and crashes (`AG::Graph::value_set`).
@MainActor
final class AppModel: ObservableObject {
    @Published var config: Config = .resolve()
    @Published var gpu: GPUInfo = .detect()
    @Published var runtime: ResolvedRuntime?
    @Published var doctor: Doctor.Report?
    @Published var prefixes: [PrefixRecord] = []
    @Published var logs: [URL] = []
    @Published var setupComponents: [Setup.ComponentStatus] = []

    // Precomputed, read-only data for the views
    @Published var runtimeLabels: [String: String] = [:]
    @Published var supportsSteam: [String: Bool] = [:]
    @Published var prefixSizes: [String: String] = [:]
    @Published var steamBadges: [String: SteamBadge] = [:]

    @Published var busy = false
    @Published var message = ""

    // New box form: nome + runtime scelto fra quelli installati
    // (i runtime Game-X sono auto-consistenti; "auto" = il migliore disponibile)
    @Published var newPrefixName = ""
    @Published var newPrefixRuntime = ""            // "" = auto (miglior runtime)
    @Published var runtimeChoices: [RuntimeChoice] = []

    // Run Program sheet
    @Published var runProgramBox: PrefixRecord?
    @Published var runProgramCommand = ""
    @Published var runProgramOutput = ""
    @Published var runProgramRunning = false

    // Logs
    @Published var selectedLog: URL?
    @Published var logText = ""

    var paths: Paths { config.resolvedPaths() }
    /// Componenti mancanti che servono davvero (gli opzionali come Wine Staging/GPTK no).
    var missingComponents: [Setup.ComponentStatus] { setupComponents.filter { !$0.installed && !$0.optional } }
    /// Componenti opzionali mancanti (mostrati a parte, non bloccanti).
    var optionalComponents: [Setup.ComponentStatus] { setupComponents.filter { !$0.installed && $0.optional } }

    struct SteamBadge: Sendable, Equatable {
        let installed: Bool
        let shim: Bool
    }

    // MARK: - Refresh

    func refresh() async {
        let cfg = config
        let data = await Task.detached { () -> Snapshot in
            let paths = cfg.resolvedPaths()
            let runtimes = Runtime.list(config: cfg)
            let choices = Runtime.choices(config: cfg)
            let boxes = Prefix.list(paths: paths)

            var labels: [String: String] = [:]
            var supports: [String: Bool] = [:]
            var sizes: [String: String] = [:]
            var badges: [String: SteamBadge] = [:]
            for b in boxes {
                let rt = Runtime.forPrefix(b, config: cfg, knownRuntimes: runtimes)
                labels[b.name] = rt?.summary ?? "?"
                supports[b.name] = rt?.supportsModernSteam ?? false
                sizes[b.name] = ByteFormat.human(b.sizeBytes())
                switch Steam.status(in: b) {
                case .notInstalled:
                    badges[b.name] = SteamBadge(installed: false, shim: false)
                case .installed(let shim):
                    badges[b.name] = SteamBadge(installed: true, shim: shim)
                }
            }

            return Snapshot(
                choices: choices,
                runtime: Runtime.resolve(config: cfg),
                doctor: Doctor.run(config: cfg),
                boxes: boxes,
                logs: Logs.list(config: cfg),
                setup: Setup.status(config: cfg),
                labels: labels, supports: supports, sizes: sizes, badges: badges)
        }.value

        runtimeChoices = data.choices
        if newPrefixRuntime.isEmpty { newPrefixRuntime = data.choices.first?.id ?? "" }
        runtime = data.runtime
        doctor = data.doctor
        prefixes = data.boxes
        logs = data.logs
        setupComponents = data.setup
        runtimeLabels = data.labels
        supportsSteam = data.supports
        prefixSizes = data.sizes
        steamBadges = data.badges
        busy = false
    }

    private struct Snapshot: Sendable {
        let choices: [RuntimeChoice]
        let runtime: ResolvedRuntime?
        let doctor: Doctor.Report?
        let boxes: [PrefixRecord]
        let logs: [URL]
        let setup: [Setup.ComponentStatus]
        let labels: [String: String]
        let supports: [String: Bool]
        let sizes: [String: String]
        let badges: [String: SteamBadge]
    }

    // Read-only accessors (no processes)
    func runtimeLabel(_ b: PrefixRecord) -> String { runtimeLabels[b.name] ?? "?" }
    func prefixSupportsSteam(_ b: PrefixRecord) -> Bool { supportsSteam[b.name] ?? false }
    func prefixSize(_ b: PrefixRecord) -> String { prefixSizes[b.name] ?? "—" }
    func badge(_ b: PrefixRecord) -> SteamBadge { steamBadges[b.name] ?? .init(installed: false, shim: false) }

    // MARK: - Boxes

    func createPrefix() async {
        let name = newPrefixName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let cfg = config
        let selector = newPrefixRuntime.isEmpty ? nil : newPrefixRuntime
        busy = true
        message = "Creating box '\(name)'…"
        let outcome = await Task.detached { () -> String in
            let rt: ResolvedRuntime?
            if let selector, !selector.isEmpty {
                rt = Runtime.select(selector, config: cfg)
            } else {
                rt = Runtime.resolveForSteam(config: cfg)
            }
            guard let rt else {
                return "Runtime '\(selector ?? D3DMetal.defaultName)' not found. Build it with `gx runtime build-gptk` (or `gx setup`)."
            }
            do {
                let b = try Prefix.create(name, config: cfg, runtime: rt)
                return "Box '\(b.name)' created (\(rt.summary))"
            } catch { return "Error: \(error)" }
        }.value
        message = outcome
        newPrefixName = ""
        await refresh()
    }

    func removePrefix(_ box: PrefixRecord) async {
        let cfg = config
        busy = true
        let outcome = await Task.detached { () -> String in
            if let rt = Runtime.forPrefix(box, config: cfg) { Prefix.kill(box, runtime: rt) }
            do {
                let dest = try Prefix.remove(box, paths: cfg.resolvedPaths())
                return "Box moved to internal trash: \(dest.lastPathComponent)"
            } catch { return "Error: \(error)" }
        }.value
        message = outcome
        await refresh()
    }

    func openPrefix(_ box: PrefixRecord) { NSWorkspace.shared.open(box.driveC) }

    func purgeTrash() async {
        let cfg = config
        let trash = cfg.resolvedPaths().prefixRoot.appendingPathComponent(".trash")
        let items = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
        for item in items { try? Prefix.purge(trash.appendingPathComponent(item)) }
        message = "\(items.count) items deleted from trash"
        await refresh()
    }

    // MARK: - Steam

    func installSteam(into box: PrefixRecord) async {
        let cfg = config
        guard let rt = Runtime.forPrefix(box, config: cfg) ?? Runtime.resolveForSteam(config: cfg) else {
            message = "No runtime found"; return
        }
        busy = true
        message = "Installing Steam in '\(box.name)' (online download)…"
        let outcome = await Task.detached { () -> String in
            do {
                return try Steam.install(prefix: box, config: cfg, runtime: rt,
                                         setupDownload: true, waitForUpdate: true,
                                         progress: { Log.shared.info($0) })
            } catch { return "Error: \(error)" }
        }.value
        message = outcome
        await refresh()
    }

    func repairSteam(_ box: PrefixRecord) async {
        let cfg = config
        guard let rt = Runtime.forPrefix(box, config: cfg) ?? Runtime.resolveForSteam(config: cfg) else {
            message = "No runtime found"; return
        }
        busy = true
        message = "Repairing shim in '\(box.name)'…"
        let outcome = await Task.detached { () -> String in
            do { return try Steam.repair(prefix: box, config: cfg, runtime: rt) }
            catch { return "Error: \(error)" }
        }.value
        message = outcome
        await refresh()
    }

    func runSteam(_ box: PrefixRecord) {
        let cfg = config
        guard let rt = Runtime.forPrefix(box, config: cfg) ?? Runtime.resolveForSteam(config: cfg) else {
            message = "No runtime found"; return
        }
        message = "Starting Steam in '\(box.name)'…"
        Task.detached { [weak self] in
            do {
                _ = try Steam.run(prefix: box, config: cfg, runtime: rt)
                await MainActor.run { self?.message = "Steam closed in '\(box.name)'" }
            } catch {
                // Mai inghiottire l'errore: se il runtime non parte (es. renderer non
                // inizializzato, processi esauriti, Wine troppo vecchio) va mostrato.
                await MainActor.run { self?.message = "Steam failed to start in '\(box.name)': \(error)" }
                Log.shared.error("steam run failed: \(error)")
            }
        }
    }

    /// Uccide eventuali debugger Wine rimasti appesi (vedi `Prefix.killStaleDebuggers`).
    func cleanStaleDebuggers() {
        Task.detached { Prefix.killStaleDebuggers() }
        message = "Cleaning up stale Wine debuggers…"
    }

    func stopSteam(_ box: PrefixRecord) {
        let cfg = config
        if let rt = Runtime.forPrefix(box, config: cfg) ?? Runtime.resolveForSteam(config: cfg) {
            Steam.stop(prefix: box, runtime: rt)
            message = "Steam stopped in '\(box.name)'"
        }
    }

    // MARK: - Setup

    func installMissing() async {
        let cfg = config
        busy = true
        message = "Installing missing components…"
        let outcome = await Task.detached { () -> String in
            var lines: [String] = []
            let count = Setup.installMissing(config: cfg) { lines.append($0) }
            return "\(count) components installed. " + lines.suffix(3).joined(separator: " | ")
        }.value
        message = outcome
        await refresh()
    }

    /// Install a single component (e.g. from a diagnostics row).
    func installComponent(_ component: Setup.ComponentStatus) async {        let cfg = config
        guard component.installable else {
            message = "\(component.title) must be installed manually: \(component.manualURL ?? "-")"
            return
        }
        busy = true
        message = "Installing \(component.title)…"
        let outcome = await Task.detached { () -> String in
            do {
                let code = try Setup.install(component, config: cfg)
                return code == 0 ? "\(component.title) installed" : "\(component.title) failed (exit \(code))"
            } catch { return "\(component.title) error: \(error)" }
        }.value
        message = outcome
        await refresh()
    }

    /// Install a `Setup` component by id (used by the Diagnostics buttons).
    func installComponent(id: String) async {
        guard let component = setupComponents.first(where: { $0.id == id }) else {
            message = "Component '\(id)' not found"; return
        }
        await installComponent(component)
    }

    /// Path of the `gx` CLI bundled inside the app (`Contents/MacOS/gx`).
    static func bundledGXPath() -> String? {
        let inApp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/gx").path
        if FileManager.default.isExecutableFile(atPath: inApp) { return inApp }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("gx").path,
           FileManager.default.isExecutableFile(atPath: exe) { return exe }
        return nil
    }

    /// Builds the `wine-gptk` runtime with the bundled `gx` CLI.
    func buildRuntime() async {
        guard let gx = Self.bundledGXPath() else {
            message = "Bundled `gx` not found — rebuild the app with scripts/build-app.sh"
            return
        }
        let cfg = config
        busy = true
        message = "Building the wine-gptk runtime… (downloads the Wine base; uses Apple's GPTK 4 DMG for D3DMetal)"
        let outcome = await Task.detached { () -> String in
            let log = cfg.resolvedPaths().cacheRoot.appendingPathComponent("build-runtime.log")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            do {
                let code = try ProcessRunner.runStreaming(gx, ["runtime", "build-gptk"], logFile: log)
                return code == 0
                    ? "wine-gptk runtime built. Log: \(log.path)"
                    : "Build failed (exit \(code)). See log: \(log.path)"
            } catch { return "Build error: \(error)" }
        }.value
        message = outcome
        await refresh()
    }

    // MARK: - Run program

    /// Runs an arbitrary Windows command inside a box (detached, output captured).
    func runProgram(in box: PrefixRecord, command: String) async {
        let tokens = CommandLineTokens.split(command)
        guard !tokens.isEmpty else { return }
        let cfg = config
        guard let rt = Runtime.forPrefix(box, config: cfg) else {
            runProgramOutput = "No runtime for this box"; return
        }
        runProgramRunning = true
        runProgramOutput = "Running \(tokens.joined(separator: " "))…"
        let result = await Task.detached { () -> String in
            do {
                let r = try Prefix.exec(box, command: tokens, config: cfg, runtime: rt)
                var out = r.stdout
                if !r.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + r.stderr }
                return out.isEmpty ? "(no output, exit \(r.exitCode))" : out + "\n[exit \(r.exitCode)]"
            } catch { return "Error: \(error)" }
        }.value
        runProgramOutput = result
        runProgramRunning = false
    }

    // MARK: - Logs

    func loadLog(_ url: URL) {
        selectedLog = url
        logText = Logs.tail(url, lines: 500).joined(separator: "\n")
    }

    func reloadSelectedLog() {
        if let url = selectedLog { loadLog(url) }
    }
}
