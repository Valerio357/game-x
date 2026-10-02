import Foundation

/// Runtime **Game-X Wine + D3DMetal**: Wine costruito dai sorgenti pubblici
/// CodeWeavers (schema **TEB-in-TSD**: `%gs` resta il TSD di macOS) + la
/// redist **D3DMetal** di Apple (dal Game Porting Toolkit).
///
/// **Perché serve una Wine CodeWeavers e non una Wine upstream.** L'glue
/// D3DMetal di Apple (`libd3dshared` = `d3d11.so`/`dxgi.so`) chiama funzioni
/// *Mach-O* **direttamente dal codice PE** (fast path `gGFXTDispatch+0x150` in
/// `dxgi.dll!Thunk_Thread`, `gGFXTDispatch+N` in ogni entry point). Quel codice
/// usa libc, quindi `%gs` deve essere il TSD macOS. Wine upstream mette il
/// **TEB Windows in `%gs`** → `%gs:0 == 0` → la prima chiamata libc
/// (`pthread_setname_np("D3DMetalWineThread")`) va in page fault su 0x0.
/// CodeWeavers invece non tocca `%gs` (`get_current_teb() = rsp & ~signal_stack_mask`,
/// campi TEB scritti dentro la pagina TSD): è la differenza che rende D3DMetal
/// funzionante. Vedi `~/Workspace/d3dmetal-wine/PLAN.md` §14.
///
/// Layout auto-consistente (tutto dentro la cartella del runtime):
///
///     <root>/bin/wine
///     <root>/lib/wine/x86_64-{unix,windows}/…   (D3DMetal: d3d11, dxgi, d3d12, …)
///     <root>/lib/external/{D3DMetal.framework, libd3dshared.dylib}
///     <root>/x64deps/*.dylib                    (MoltenVK, freetype… se servono)
///     <root>/manifest.json
public enum D3DMetal {

    // MARK: - Manifest

    public struct Manifest: Codable, Sendable, Equatable {
        public var name: String
        public var wineVersion: String?
        public var d3dmetalVersion: String?
        public var source: String?
        public var builtAt: String?

        public init(name: String, wineVersion: String? = nil, d3dmetalVersion: String? = nil,
                    source: String? = nil, builtAt: String? = nil) {
            self.name = name
            self.wineVersion = wineVersion
            self.d3dmetalVersion = d3dmetalVersion
            self.source = source
            self.builtAt = builtAt
        }
    }

    // MARK: - Info

    public struct Info: Sendable, Equatable {
        public let root: URL
        public let name: String
        public let wineBinary: String
        public let wineRoot: URL
        public let external: URL          // <root>/lib/external
        public let x64Deps: URL           // <root>/x64deps (può non esistere)
        public let manifest: Manifest?

        public var d3dmetalVersion: String { manifest?.d3dmetalVersion ?? "unknown" }
        public var wineVersion: String { manifest?.wineVersion ?? "unknown" }

        public var summary: String {
            "Game-X Wine+D3DMetal — \(wineVersion) / D3DMetal \(d3dmetalVersion)"
        }

        /// `<framework>/Versions/A/Resources`: lì vivono `libdxccontainer.dylib` e
        /// `libmetalirconverter.dylib` (le dipendenze `@rpath` del framework) → va
        /// messa nella `DYLD_LIBRARY_PATH`.
        public var frameworkResources: URL {
            external.appendingPathComponent("D3DMetal.framework/Versions/A/Resources")
        }

        public var framework: URL {
            external.appendingPathComponent("D3DMetal.framework")
        }

        /// Tutti i pezzi indispensabili ci sono?
        public var isUsable: Bool {
            let fm = FileManager.default
            return fm.isExecutableFile(atPath: wineBinary)
                && fm.fileExists(atPath: framework.path)
                && fm.fileExists(atPath: external.appendingPathComponent("libd3dshared.dylib").path)
                && fm.fileExists(atPath: wineRoot.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll").path)
        }
    }

    public static let defaultName = "wine-gptk"

    // MARK: - Discovery

    public static func runtimesRoot(config: Config) -> URL {
        DXMT.runtimesRoot(config: config)
    }

    /// Cerca tutti i runtime Wine+D3DMetal installati.
    public static func list(config: Config) -> [Info] {
        let root = runtimesRoot(config: config)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.compactMap { discover(root: $0) }.sorted { $0.name < $1.name }
    }

    /// Riconosce un runtime D3DMetal dalla sua cartella.
    public static func discover(root: URL) -> Info? {
        let fm = FileManager.default
        let candidates: [URL] = [root.appendingPathComponent("wine"), root]
        for base in candidates {
            let bin = base.appendingPathComponent("bin/wine")
            guard fm.isExecutableFile(atPath: bin.path) else { continue }
            let external = base.appendingPathComponent("lib/external")
            guard fm.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path)
            else { return nil }
            var manifest: Manifest?
            if let data = try? Data(contentsOf: root.appendingPathComponent("manifest.json")) {
                manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            }
            return Info(root: root, name: root.lastPathComponent, wineBinary: bin.path,
                        wineRoot: base, external: external,
                        x64Deps: base.appendingPathComponent("x64deps"), manifest: manifest)
        }
        return nil
    }

    // MARK: - Ambiente di lancio

    /// Ambiente necessario perché Wine carichi il D3DMetal *builtin* e trovi le dylib.
    ///
    /// - `WINEDLLOVERRIDES…=b`: le DLL D3DMetal hanno i **nomi builtin** di Wine
    ///   (`d3d11.dll`, `dxgi.dll`, …) e stanno in `<wine>/lib/wine/x86_64-*`. Se nella
    ///   box esistono copie *native* (residui DXMT/GPTK in `system32`) Wine le
    ///   preferirebbe e fallirebbe (`c0000135`) → forziamo i builtin.
    /// - `DYLD_LIBRARY_PATH`: `lib/external` (framework) + `Versions/A/Resources`
    ///   (dipendenze `@rpath`) + `x64deps` (MoltenVK/freetype…).
    /// - `DYLD_FRAMEWORK_PATH`: dove sta `D3DMetal.framework`.
    public static func environment(for info: Info) -> [String: String] {
        var env: [String: String] = [:]

        env["WINEDLLOVERRIDES"] = "d3d11,dxgi,d3d10,d3d10core,d3d12,nvapi64,nvngx,atidxx64,winemetal=b"

        var paths: [String] = []
        if FileManager.default.fileExists(atPath: info.x64Deps.path) {
            paths.append(info.x64Deps.path)
        }
        paths.append(info.external.path)
        if FileManager.default.fileExists(atPath: info.frameworkResources.path) {
            paths.append(info.frameworkResources.path)
        }
        if let existing = ProcessInfo.processInfo.environment["DYLD_LIBRARY_PATH"], !existing.isEmpty {
            paths.append(existing)
        }
        env["DYLD_LIBRARY_PATH"] = paths.joined(separator: ":")
        env["DYLD_FRAMEWORK_PATH"] = info.external.path

        return env
    }
}
