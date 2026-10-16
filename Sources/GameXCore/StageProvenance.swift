import Foundation

/// Provenienza dello **stage**: il confronto per **contenuto** fra i moduli
/// staggati e l'output della build del repo dxmf.
///
/// Nota di design. La provenienza *vera* richiede che la **build/stage la
/// scriva**: una sha del sorgente piu' gli hash dei moduli accanto allo stage.
/// `gx` non puo' inventarla: la **legge se c'e'** e, per il resto, confronta per
/// contenuto con l'output della build corrente. Percio':
///
/// - se esiste un file di provenienza (`<stage>/../dxmf-stage.json`,
///   `<repo>/build/game-stage/*.json`) con una sha e/o gli hash, lo **usa**:
///   sha registrata ≠ `git rev-parse HEAD` ⇒ STALE; hash registrati ≠ hash su
///   disco ⇒ STALE. Se non esiste, lo **dichiara**;
/// - altrimenti la prova e' il confronto byte-per-byte con
///   `<repo>/build/pe/bin/<m>.dll` e `<repo>/build/host/lib/<m>.so`;
/// - l'output di build **assente** e' `UNKNOWN`, **mai** un `OK` per assenza di
///   dati;
/// - la **mtime non decide**: al massimo finisce in un `detail`.
///
/// Il file di provenienza che dxmf dovrebbe scrivere (proposta in una riga):
/// `<repo>/build/game-stage/dxmf-stage.json` con
/// `{"git":"<sha>","wineVersion":"11.10","modules":{"d3d11":{"pe_sha256":"…","unix_sha256":"…"},…}}`.
public enum StageProvenance {

    public enum Status: String, Sendable {
        case ok = "OK"
        case stale = "STALE"
        /// Dato assente (output di build o repo non localizzabile): mai OK.
        case unknown = "UNKNOWN"
    }

    /// Un confronto per **meta' modulo** (PE o unix).
    public struct ModuleCheck: Sendable, Equatable {
        public let module: String
        public let half: String            // "PE" | "unix"
        public let staged: URL
        public let build: URL?
        public let stagedHash: String?
        public let buildHash: String?
        public let buildMissing: Bool

        public var matches: Bool {
            !buildMissing && stagedHash != nil && stagedHash == buildHash
        }
    }

    public struct Report: Sendable {
        public let status: Status
        public let repo: URL?
        public let shortSHA: String?
        public let dirtyCount: Int?
        public let gitNote: String?
        public let manifestPath: URL?
        public let manifestSHA: String?
        public let modules: [ModuleCheck]
        public let detail: String
        public let remedy: String?
    }

    // MARK: - Ispezione

    public static func inspect(
        stageRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Report {
        let repo = resolveRepo(stageRoot: stageRoot, environment: environment)
        let (shortSHA, fullSHA, dirty, gitNote) = repo.map(gitFacts) ?? (nil, nil, nil, "no dxmf repo located")

        let modules = moduleChecks(stageRoot: stageRoot, repo: repo)
        let manifest = findManifest(stageRoot: stageRoot, repo: repo)
        let parsed = manifest.map(parseManifest) ?? (sha: nil, hashes: [:])

        // 1) output di build assente ovunque ⇒ UNKNOWN, mai OK.
        let anyBuildPresent = modules.contains { !$0.buildMissing }
        let allMatch = !modules.isEmpty && modules.allSatisfy { $0.matches }
        let anyMismatch = modules.contains { !$0.buildMissing && !$0.matches }

        // 2) il file di provenienza, se c'e', puo' forzare STALE.
        var manifestStaleReasons: [String] = []
        if let registered = parsed.sha {
            if let fullSHA {
                if !shaMatches(registered: registered, full: fullSHA, short: shortSHA) {
                    manifestStaleReasons.append(
                        "the provenance file registers sha \(abbrev(registered)), "
                            + "the repo is at \(shortSHA ?? fullSHA)")
                }
            } else {
                manifestStaleReasons.append(
                    "the provenance file registers sha \(abbrev(registered)) but git is unavailable "
                        + "to compare it")
            }
        }
        for (key, registered) in parsed.hashes {
            guard let check = matchRegisteredHash(key: key, registered: registered, modules: modules) else {
                continue
            }
            if !check {
                manifestStaleReasons.append(
                    "the provenance file registers a hash for \(key) that does not match the module on disk")
            }
        }

        let status: Status
        if repo == nil {
            status = .unknown
        } else if modules.isEmpty {
            status = .unknown
        } else if !anyBuildPresent {
            status = .unknown
        } else if anyMismatch || !manifestStaleReasons.isEmpty {
            status = .stale
        } else if allMatch {
            status = .ok
        } else {
            // Alcune meta' hanno output di build, altre no: dato parziale ⇒ UNKNOWN.
            status = .unknown
        }

        let detail = composeDetail(
            status: status, repo: repo, shortSHA: shortSHA, dirty: dirty, gitNote: gitNote,
            manifest: manifest, manifestSHA: parsed.sha, modules: modules,
            manifestStaleReasons: manifestStaleReasons, stageRoot: stageRoot)

        let remedy = repo.map {
            "DXMF_STAGE=\(stageRoot.deletingLastPathComponent().path) "
                + "bash \($0.path)/scripts/stage-wine-runtime.sh --renderer \(stageRoot.path)"
        }

        return Report(
            status: status, repo: repo, shortSHA: shortSHA, dirtyCount: dirty,
            gitNote: gitNote, manifestPath: manifest, manifestSHA: parsed.sha,
            modules: modules, detail: detail, remedy: remedy)
    }

    // MARK: - Repo

    /// `GX_DXMF_REPO` vince; altrimenti si deriva dal layout canonico
    /// `<repo>/build/game-stage/wine`.
    static func resolveRepo(stageRoot: URL, environment: [String: String]) -> URL? {
        let fm = FileManager.default
        if let raw = environment["GX_DXMF_REPO"], !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let candidate = stageRoot
            .deletingLastPathComponent()   // game-stage
            .deletingLastPathComponent()   // build
            .deletingLastPathComponent()   // <repo>
        return fm.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Fatti git, di sola lettura: `rev-parse` (sha piena + breve) e il numero di
    /// file in `status --porcelain`. Se `git` non c'e', lo dichiara.
    static func gitFacts(repo: URL) -> (short: String?, full: String?, dirty: Int?, note: String?) {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else {
            return (nil, nil, nil, "git not found at \(git)")
        }
        guard let full = try? ProcessRunner.run(git, ["-C", repo.path, "rev-parse", "HEAD"]),
              full.success else {
            return (nil, nil, nil, "not a git repository (or git rev-parse failed): \(repo.path)")
        }
        let fullSHA = full.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = (try? ProcessRunner.run(git, ["-C", repo.path, "rev-parse", "--short", "HEAD"]))
            .flatMap { $0.success ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        let dirty = (try? ProcessRunner.run(git, ["-C", repo.path, "status", "--porcelain"]))
            .flatMap { $0.success ? $0.stdout.split(separator: "\n").filter { !$0.isEmpty }.count : nil }
        return (short?.isEmpty == false ? short : String(fullSHA.prefix(7)),
                fullSHA.isEmpty ? nil : fullSHA, dirty, nil)
    }

    // MARK: - Moduli

    static func moduleChecks(stageRoot: URL, repo: URL?) -> [ModuleCheck] {
        let fm = FileManager.default
        let peDir = stageRoot.appendingPathComponent("x86_64-windows")
        let unixDir = stageRoot.appendingPathComponent("x86_64-unix")
        let names = ((try? fm.contentsOfDirectory(at: peDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "dll" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        var checks: [ModuleCheck] = []
        for name in names {
            checks.append(compare(
                module: name, half: "PE",
                staged: peDir.appendingPathComponent("\(name).dll"),
                build: repo?.appendingPathComponent("build/pe/bin/\(name).dll")))
            checks.append(compare(
                module: name, half: "unix",
                staged: unixDir.appendingPathComponent("\(name).so"),
                build: repo?.appendingPathComponent("build/host/lib/\(name).so")))
        }
        return checks
    }

    static func compare(module: String, half: String, staged: URL, build: URL?) -> ModuleCheck {
        let fm = FileManager.default
        let stagedExists = fm.fileExists(atPath: staged.path)
        let buildExists = build.map { fm.fileExists(atPath: $0.path) } ?? false
        let stagedHash = stagedExists ? (try? DXMT.fileSHA256(staged)) : nil
        let buildHash = buildExists ? (try? DXMT.fileSHA256(build!)) : nil
        return ModuleCheck(
            module: module, half: half, staged: staged,
            build: buildExists ? build : nil,
            stagedHash: stagedHash, buildHash: buildHash,
            buildMissing: !buildExists)
    }

    // MARK: - File di provenienza

    /// Candidati: `<stage>/../dxmf-stage.json` (e nomi affini), poi i `*.json`
    /// in `<repo>/build/game-stage`. **Mai** `<stage>/manifest.json`, che e' il
    /// pin di versione, non la provenienza.
    static func findManifest(stageRoot: URL, repo: URL?) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        let parent = stageRoot.deletingLastPathComponent()
        for name in ["dxmf-stage.json", "stage-provenance.json", "provenance.json"] {
            candidates.append(parent.appendingPathComponent(name))
        }
        if let repo {
            let gs = repo.appendingPathComponent("build/game-stage")
            if let files = try? fm.contentsOfDirectory(at: gs, includingPropertiesForKeys: nil) {
                candidates.append(contentsOf: files
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent })
            }
        }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Legge una sha e gli hash dei moduli da un file di provenienza, con nomi
    /// accettati (il formato non e' ancora congelato: se c'e', lo si usa).
    static func parseManifest(_ url: URL) -> (sha: String?, hashes: [String: String]) {
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return (nil, [:])
        }
        var sha: String?
        for key in ["sha", "gitSha", "git_sha", "commit", "head", "revision", "sourceSha", "source_sha"] {
            if let value = object[key] as? String, !value.isEmpty { sha = value; break }
        }
        var hashes: [String: String] = [:]
        if let modules = object["modules"] as? [String: Any] {
            for (name, value) in modules {
                if let s = value as? String, !s.isEmpty { hashes[name] = s; continue }
                guard let fields = value as? [String: Any] else { continue }
                for (field, raw) in fields {
                    guard let s = raw as? String, !s.isEmpty else { continue }
                    let lower = field.lowercased()
                    if lower.contains("pe") { hashes["\(name).pe"] = s }
                    else if lower.contains("unix") { hashes["\(name).unix"] = s }
                    else { hashes[name] = s }
                }
            }
        }
        if let flat = object["hashes"] as? [String: Any] {
            for (name, raw) in flat { if let s = raw as? String, !s.isEmpty { hashes[name] = s } }
        }
        return (sha, hashes)
    }

    /// `true` se l'hash registrato combacia con il modulo su disco. `nil` se la
    /// chiave non nomina un modulo noto (nulla da verificare).
    static func matchRegisteredHash(key: String, registered: String, modules: [ModuleCheck]) -> Bool? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        let module = parts[0]
        let half = parts.count > 1 ? parts[1].lowercased() : nil
        let relevant = modules.filter { $0.module == module && (half == nil || $0.half.lowercased() == half) }
        guard !relevant.isEmpty else { return nil }
        return relevant.contains { $0.stagedHash == registered }
    }

    static func shaMatches(registered: String, full: String, short: String?) -> Bool {
        let r = registered.lowercased()
        let f = full.lowercased()
        if f == r || f.hasPrefix(r) { return true }
        if let short, r.hasPrefix(short.lowercased()) { return true }
        return false
    }

    // MARK: - Messaggio

    static func abbrev(_ hash: String?) -> String {
        guard let hash, !hash.isEmpty else { return "<unreadable>" }
        return String(hash.prefix(12))
    }

    static func composeDetail(
        status: Status, repo: URL?, shortSHA: String?, dirty: Int?, gitNote: String?,
        manifest: URL?, manifestSHA: String?, modules: [ModuleCheck],
        manifestStaleReasons: [String], stageRoot: URL
    ) -> String {
        var parts: [String] = []
        let shaText: String
        if let shortSHA {
            shaText = "repo \(shortSHA)\(dirty.map { " (\($0) uncommitted)" } ?? "")"
        } else {
            shaText = "repo sha UNKNOWN — \(gitNote ?? "git unavailable")"
        }
        parts.append(shaText)
        parts.append("stage \(stageRoot.path)")

        switch status {
        case .ok:
            let hashes = modules.map { "\($0.module) \($0.half) \(abbrev($0.stagedHash))" }
            parts.append(hashes.joined(separator: ", "))
            if let repo { parts.append("build \(repo.path)/build") }
        case .stale:
            let differs = modules.filter { !$0.buildMissing && !$0.matches }
            if !differs.isEmpty {
                let names = Set(differs.map { $0.module }).sorted()
                parts.append("staged \(names.joined(separator: ", ")) differs from the build output")
                for check in differs {
                    parts.append("\(check.module) \(check.half): staged \(abbrev(check.stagedHash)) "
                        + "vs build \(abbrev(check.buildHash))")
                }
            }
            parts.append(contentsOf: manifestStaleReasons)
        case .unknown:
            let missing = modules.filter { $0.buildMissing }.map { "\($0.module) \($0.half)" }
            if modules.isEmpty {
                parts.append("no staged module found — nothing to compare")
            } else if missing.count == modules.count {
                parts.append("build output absent for every module: "
                    + Set(modules.map { $0.module }).sorted().joined(separator: ", ")
                    + " — declared UNKNOWN, never OK")
            } else {
                parts.append("build output absent for: " + missing.joined(separator: ", "))
            }
        }

        if let manifest {
            parts.append("provenance file \(manifest.path)"
                + (manifestSHA.map { ", sha \(abbrev($0))" } ?? ", no sha field"))
        } else {
            parts.append("no provenance file next to the stage or in <repo>/build/game-stage "
                + "(the real fix is for the build/stage to write one)")
        }
        if let mtime = (try? FileManager.default.attributesOfItem(atPath: stageRoot.path)[.modificationDate]) as? Date {
            parts.append("stage mtime \(ISO8601DateFormatter().string(from: mtime)) (informational only)")
        }
        return parts.joined(separator: "; ")
    }
}
