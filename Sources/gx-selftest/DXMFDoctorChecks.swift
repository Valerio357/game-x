import Foundation
import GameXCore

/// F008: `gx dxmf doctor`. Tutto ermetico: host finto (`bin/wine` che dichiara
/// la versione via `manifest.json`), marker delle patch, stage con d3d11/dxgi,
/// box finta. Nessun Wine eseguito, nessuna box vera.
func runDXMFDoctorChecks(_ h: Harness) {
    print("F008: gx dxmf doctor")

    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("gx-dxmf-doctor-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }

    /// Host finto: `bin/wine` eseguibile, versione dichiarata accanto all'host
    /// (così `discover` non esegue Wine), marker delle due patch, librerie.
    func makeHost(_ name: String, declared: String, patched: Bool, libs: Bool) -> URL {
        let host = root.appendingPathComponent(name)
        let bin = host.appendingPathComponent("bin")
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let wine = bin.appendingPathComponent("wine")
        try? "#!/bin/sh\necho \(declared)\n".write(to: wine, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let unix = host.appendingPathComponent("lib/wine/x86_64-unix")
        try? fm.createDirectory(at: unix, withIntermediateDirectories: true)
        try? "\(patched ? "WINEDLLPATH_PREPEND" : "no-dllpath")\n".write(
            to: unix.appendingPathComponent("ntdll.so"), atomically: true, encoding: .utf8)
        try? "\(patched ? "macdrv_functions" : "no-macdrv")\n".write(
            to: unix.appendingPathComponent("winemac.so"), atomically: true, encoding: .utf8)
        if libs {
            let external = host.appendingPathComponent("lib/external")
            try? fm.createDirectory(at: external, withIntermediateDirectories: true)
            for lib in ["libfreetype.6.dylib", "libMoltenVK.dylib", "libgnutls.30.dylib"] {
                try? Data([0xca, 0xfe]).write(to: external.appendingPathComponent(lib))
            }
        }
        try? "{\"wineVersion\":\"\(declared)\"}".write(
            to: host.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        return host
    }

    let stage = root.appendingPathComponent("stage/wine")
    for module in ["d3d11", "dxgi"] {
        for (dir, ext) in [("x86_64-windows", "dll"), ("x86_64-unix", "so")] {
            let file = stage.appendingPathComponent("\(dir)/\(module).\(ext)")
            try? fm.createDirectory(at: file.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? Data([0x7f, 0x45]).write(to: file)
        }
    }
    try? "{\"pinnedVersion\":\"11.10\"}".write(
        to: stage.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

    let prefixRoot = root.appendingPathComponent("boxes")
    try? fm.createDirectory(at: prefixRoot, withIntermediateDirectories: true)
    let boxURL = prefixRoot.appendingPathComponent("gxdxmf-doctor")
    try? fm.createDirectory(at: boxURL.appendingPathComponent("drive_c/windows/system32"),
                            withIntermediateDirectories: true)

    let host = makeHost("wine-good", declared: "wine-11.10", patched: true, libs: true)
    let config = Config(prefixRoot: prefixRoot.path,
                        cacheRoot: root.appendingPathComponent("cache").path,
                        dxmfWineRoot: host.path, dxmfStage: stage.path)

    // Global parts on a complete host: no FAIL.
    let global = DXMFDoctor.run(config: config)
    h.check(!global.hasFailures, "global doctor on a complete host has no FAIL")
    h.check(global.checks.contains { $0.id == "runtime" && $0.status == .ok },
            "runtime coherent → OK")
    h.check(global.checks.contains { $0.id == "module.d3d11" && $0.status == .ok },
            "module d3d11 PE + unix → OK")
    h.check(global.checks.contains { $0.id == "module.dxgi" && $0.status == .ok },
            "module dxgi PE + unix → OK")
    h.check(global.checks.contains { $0.id == "capabilities.patches" && $0.status == .ok },
            "both CodeWeavers patches → OK")
    h.check(global.checks.contains { $0.id == "capabilities.libraries" && $0.status == .ok },
            "system libraries in the host → OK")
    h.check(global.checks.contains { $0.id == "x64deps" && $0.status == .ok }, "x64deps → OK")
    h.check(!global.checks.contains { $0.id == "lock" }, "no lock check without a box")
    h.check(global.checks.contains { $0.id == "orphans" }, "orphans are always checked")

    // A bare box (no Steam/mono/overrides/verbs): prefix deps must FAIL and say
    // what to do — this is the check that would have caught the black box.
    let bare = DXMFDoctor.run(config: config, box: "gxdxmf-doctor")
    h.check(bare.hasFailures, "a bare box exits non-zero (something is missing)")
    h.check(bare.checks.contains { $0.id == "prefix.verbs" && $0.status == .fail },
            "missing d3dcompiler_47/vcrun2022 → FAIL")
    h.check(bare.checks.contains { $0.id == "prefix.verbs" },
            "the verb FAIL carries a remedy")
    h.check(bare.checks.contains { $0.id == "lock" }, "lock is checked for a box")
    h.check(bare.checks.first { $0.id == "prefix.verbs" }?.remedy?.contains("gx deps install") == true,
            "the remedy is the exact `gx deps install <box> ...` line")

    // Fill the prefix: Steam + shim, wine-mono, dxvk overrides, winetricks sentinels.
    let steamExe = boxURL.appendingPathComponent("drive_c/Program Files (x86)/Steam/Steam.exe")
    try? fm.createDirectory(at: steamExe.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    try? Data([0x4d, 0x5a]).write(to: steamExe)
    for cef in ["cef.win64", "cef.win7x64"] {
        let dir = boxURL.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/bin/cef/\(cef)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("game-x-steamwebhelper-shim-v2".utf8).write(
            to: dir.appendingPathComponent("steamwebhelper.exe"))
    }
    try? fm.createDirectory(at: boxURL.appendingPathComponent("drive_c/windows/mono/mono-2.0"),
                            withIntermediateDirectories: true)
    for verb in DXMFDoctor.requiredVerbs {
        guard let sentinel = Deps.info(for: verb)?.sentinel else { continue }
        try? Data([0x4d, 0x5a]).write(to: boxURL.appendingPathComponent(sentinel))
    }
    let userReg = """
    WINE REGISTRY Version 2
    [Software\\\\Wine\\\\DllOverrides] 1700000000
    "*d3d11"="native"
    "*dxgi"="native"
    """
    try? userReg.write(to: boxURL.appendingPathComponent("user.reg"),
                       atomically: true, encoding: .utf8)

    let fixed = DXMFDoctor.run(config: config, box: "gxdxmf-doctor")
    h.check(fixed.checks.contains { $0.id == "prefix.steam" && $0.status == .ok },
            "Steam + shim → OK")
    h.check(fixed.checks.contains { $0.id == "prefix.mono" && $0.status == .ok },
            "wine-mono → OK")
    h.check(fixed.checks.contains { $0.id == "prefix.dxvk" && $0.status == .ok },
            "dxvk overrides in user.reg → OK")
    h.check(fixed.checks.contains { $0.id == "prefix.verbs" && $0.status == .ok },
            "winetricks sentinels → OK")
    h.check(!fixed.checks.contains { $0.id.hasPrefix("prefix.") && $0.status == .fail },
            "no prefix FAIL once the box has its dependencies")

    // Version mismatch → runtime FAIL, non-zero.
    let badHost = makeHost("wine-bad", declared: "wine-7.7", patched: true, libs: true)
    let badConfig = Config(prefixRoot: prefixRoot.path, cacheRoot: config.cacheRoot,
                           dxmfWineRoot: badHost.path, dxmfStage: stage.path)
    let bad = DXMFDoctor.run(config: badConfig)
    h.check(bad.hasFailures, "a version mismatch exits non-zero")
    h.check(bad.checks.contains { $0.id == "runtime" && $0.status == .fail },
            "version mismatch → runtime FAIL")

    // Missing module half → module FAIL.
    try? fm.removeItem(at: stage.appendingPathComponent("x86_64-unix/dxgi.so"))
    let broken = DXMFDoctor.run(config: config)
    h.check(broken.checks.contains { $0.id == "module.dxgi" && $0.status == .fail },
            "a missing unix half → module FAIL")
    h.check(broken.hasFailures, "a missing module exits non-zero")
}
