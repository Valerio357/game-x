import Foundation
import GameXCore

/// F010: shim (due file identici ≠ shim), provenienza dello stage (confronto
/// per contenuto) e sessione Steam. Tutto ermetico: box e repo finti in una
/// tmpdir, nessun Wine eseguito, nessuna box reale toccata.
func runF010Checks(_ h: Harness) {
    print("F010: shim status, stage provenance, steam session")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-f010-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let prefixRoot = root.appendingPathComponent("boxes")
    try? fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
    let config = Config(prefixRoot: prefixRoot.path,
                        cacheRoot: root.appendingPathComponent("cache").path,
                        dxmfWineRoot: root.appendingPathComponent("no-host").path,
                        dxmfStage: "")

    func makeSteamBox(_ name: String) -> PrefixRecord {
        let box = PrefixRecord(name: name, url: prefixRoot.appendingPathComponent(name))
        let exe = box.driveC.appendingPathComponent("Program Files (x86)/Steam/Steam.exe")
        try? fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data([0x4d, 0x5a]).write(to: exe)
        return box
    }
    func cefDir(_ box: PrefixRecord, _ name: String = "cef.win64") -> URL {
        let dir = box.driveC.appendingPathComponent("Program Files (x86)/Steam/bin/cef/\(name)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // (a) il caso del CEO: due file IDENTICI ⇒ NON e' lo shim.
    do {
        let box = makeSteamBox("f010-identical")
        let dir = cefDir(box)
        let bytes = Data(repeating: 0x41, count: 4096)
        try? bytes.write(to: dir.appendingPathComponent("steamwebhelper.exe"))
        try? bytes.write(to: dir.appendingPathComponent("steamwebhelper_real.exe"))

        let status = Shim.status(in: box)
        h.equal(status.kind, .ambiguous, "two identical webhelpers → ambiguous")
        h.check(!status.isShimmed, "identical files are not a shim")
        h.check(status.detail.contains("real helper"), "ambiguous detail says it is the real helper")
        h.check(status.detail.contains("4.0 KB"), "ambiguous detail reports the shared size")
        h.check(!Shim.isInstalled(in: box), "isInstalled == false for identical files")

        switch Steam.status(in: box) {
        case .installed(let shim):
            h.check(!shim.isShimmed,
                    "Steam.status uses the same Shim.status (identical → not shimmed)")
        case .notInstalled:
            h.check(false, "Steam.status sees the box")
        }

        let report = DXMFDoctor.run(config: config, box: box.name)
        let steam = report.checks.first { $0.id == "prefix.steam" }
        h.equal(steam?.status, .fail, "identical webhelpers → prefix.steam FAIL")
        h.check((steam?.title ?? "").contains("IDENTICAL"), "the FAIL names the identical case")
        h.equal(steam?.remedy, "gx steam repair \(box.name)", "remedy is gx steam repair")
    }

    // (b) shim vero: file diverso + marker ⇒ OK.
    do {
        let box = makeSteamBox("f010-shimmed")
        let dir = cefDir(box)
        try? Data("game-x-steamwebhelper-shim-v2".utf8).write(
            to: dir.appendingPathComponent("steamwebhelper.exe"))
        try? Data(repeating: 0x42, count: 8192).write(
            to: dir.appendingPathComponent("steamwebhelper_real.exe"))

        let status = Shim.status(in: box)
        h.equal(status.kind, .shimmed, "marker + distinct real → shimmed")
        h.check(Shim.isInstalled(in: box), "isInstalled delegates to status")
        let report = DXMFDoctor.run(config: config, box: box.name)
        h.equal(report.checks.first { $0.id == "prefix.steam" }?.status, .ok,
                "real shim → prefix.steam OK")
    }

    // (d) sessione assente ⇒ WARN (mai FAIL); con ssfn* ⇒ OK.
    do {
        let box = makeSteamBox("f010-session")
        let dir = cefDir(box)
        try? Data("game-x-steamwebhelper-shim-v2".utf8).write(
            to: dir.appendingPathComponent("steamwebhelper.exe"))

        let before = DXMFDoctor.run(config: config, box: box.name)
        let session = before.checks.first { $0.id == "prefix.session" }
        h.equal(session?.status, .warn, "no ssfn* → session WARN, not FAIL")
        h.check((session?.title ?? "").contains("human login once"),
                "the WARN says a human login is needed once")
        h.check(!before.checks.contains { $0.id == "prefix.session" && $0.status == .fail },
                "the session check is never a FAIL")

        try? Data().write(to: box.driveC.appendingPathComponent(
            "Program Files (x86)/Steam/ssfn1234"))
        let after = DXMFDoctor.run(config: config, box: box.name)
        h.equal(after.checks.first { $0.id == "prefix.session" }?.status, .ok,
                "ssfn* present → session OK")
    }

    // (c) provenienza dello stage: repo finto, confronto per contenuto.
    do {
        let repo = root.appendingPathComponent("repo")
        let stage = repo.appendingPathComponent("build/game-stage/wine")
        let peBuild = repo.appendingPathComponent("build/pe/bin")
        let unixBuild = repo.appendingPathComponent("build/host/lib")
        for dir in [stage.appendingPathComponent("x86_64-windows"),
                    stage.appendingPathComponent("x86_64-unix"), peBuild, unixBuild] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? Data("PE-d3d11".utf8).write(to: peBuild.appendingPathComponent("d3d11.dll"))
        try? Data("UNIX-d3d11".utf8).write(to: unixBuild.appendingPathComponent("d3d11.so"))
        try? Data("PE-d3d11".utf8).write(
            to: stage.appendingPathComponent("x86_64-windows/d3d11.dll"))
        try? Data("UNIX-d3d11".utf8).write(
            to: stage.appendingPathComponent("x86_64-unix/d3d11.so"))

        let ok = StageProvenance.inspect(stageRoot: stage, environment: [:])
        h.equal(ok.status, .ok, "staged == build output → OK")
        h.check(ok.detail.contains("d3d11 PE"), "OK detail lists the abbreviated hashes")
        h.equal(ok.modules.count, 2, "one check per half")
        h.check(ok.modules.allSatisfy { $0.matches }, "both halves match")
        h.check(ok.remedy?.contains("stage-wine-runtime.sh") == true,
                "the remedy names the stage script")

        // Un host finto fa girare anche il check del doctor.
        let host = root.appendingPathComponent("host")
        try? fm.createDirectory(at: host.appendingPathComponent("bin"),
                                withIntermediateDirectories: true)
        let wine = host.appendingPathComponent("bin/wine")
        try? "#!/bin/sh\necho wine-11.10\n".write(to: wine, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try? "{\"wineVersion\":\"wine-11.10\"}".write(
            to: host.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let hostConfig = Config(prefixRoot: prefixRoot.path,
                                cacheRoot: root.appendingPathComponent("cache2").path,
                                dxmfWineRoot: host.path, dxmfStage: stage.path)
        let okReport = DXMFDoctor.run(config: hostConfig)
        h.equal(okReport.checks.first { $0.id == "stage.provenance" }?.status, .ok,
                "doctor: matching provenance → OK")

        // Falsificazione: un byte diverso nello stage ⇒ STALE (anche nel doctor).
        try? Data("PE-d3d11-STALE".utf8).write(
            to: stage.appendingPathComponent("x86_64-windows/d3d11.dll"))
        let stale = StageProvenance.inspect(stageRoot: stage, environment: [:])
        h.equal(stale.status, .stale, "a changed staged module → STALE")
        h.check(stale.detail.contains("differs"), "STALE detail says it differs")
        let staleReport = DXMFDoctor.run(config: hostConfig)
        let staleCheck = staleReport.checks.first { $0.id == "stage.provenance" }
        h.equal(staleCheck?.status, .warn, "doctor: stale provenance → WARN")
        h.check((staleCheck?.title ?? "").contains("STALE"), "the WARN names STALE")
        h.check((staleCheck?.remedy ?? "").contains("stage-wine-runtime.sh"),
                "the WARN carries the stage remedy")

        // Output di build assente ⇒ UNKNOWN, mai OK.
        try? fm.removeItem(at: peBuild.appendingPathComponent("d3d11.dll"))
        try? fm.removeItem(at: unixBuild.appendingPathComponent("d3d11.so"))
        let unknown = StageProvenance.inspect(stageRoot: stage, environment: [:])
        h.equal(unknown.status, .unknown, "absent build output → UNKNOWN")
        h.check(unknown.status != .ok, "absence is never OK")
        let unknownReport = DXMFDoctor.run(config: hostConfig)
        h.equal(unknownReport.checks.first { $0.id == "stage.provenance" }?.status, .unknown,
                "doctor: unknown provenance → [ ? ]")
        h.check(unknownReport.checks.first { $0.id == "stage.provenance" }?.status != .fail,
                "provenance UNKNOWN is not a FAIL")
    }
}
