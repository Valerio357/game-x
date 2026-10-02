import Foundation

/// Feature dichiarate/rilevate di un runtime auto-consistente.
///
/// Se il `manifest.json` del runtime contiene un blocco `"features": { "sdl2": true, … }`
/// lo usiamo (fonte autorevole); altrimenti facciamo un probe del filesystem.
/// SDL2 è ciò che dà il **controller/gamepad** a Wine: se manca, `gx doctor` avvisa.
public enum RuntimeFeatures {

    public struct Report: Sendable, Equatable {
        public let sdl2: Bool
        public let vulkan: Bool
        public let mono: Bool
        public let source: String     // "manifest" oppure "probe"

        public var missing: [String] {
            var m: [String] = []
            if !sdl2 { m.append("sdl2") }
            if !vulkan { m.append("vulkan") }
            if !mono { m.append("mono") }
            return m
        }
    }

    /// Legge le feature di un runtime dalla sua cartella (`manifest.json` + probe).
    public static func probe(runtimeRoot: URL) -> Report {
        if let fromManifest = readManifest(runtimeRoot) { return fromManifest }
        return probeFilesystem(runtimeRoot)
    }

    static func readManifest(_ root: URL) -> Report? {
        let url = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feats = obj["features"] as? [String: Any] else { return nil }
        func flag(_ key: String) -> Bool {
            if let b = feats[key] as? Bool { return b }
            if let s = feats[key] as? String { return s == "true" || s == "yes" || s == "1" }
            return false
        }
        return Report(sdl2: flag("sdl2"), vulkan: flag("vulkan"), mono: flag("mono"), source: "manifest")
    }

    static func probeFilesystem(_ root: URL) -> Report {
        let fm = FileManager.default
        let deps = root.appendingPathComponent("x64deps")

        let sdl2File = fm.fileExists(atPath: deps.appendingPathComponent("libSDL2.dylib").path)
            || fm.fileExists(atPath: deps.appendingPathComponent("libSDL2-2.0.0.dylib").path)
        let sdl2 = sdl2File || winebusReferencesSDL2(root: root)

        let vulkan = fm.fileExists(atPath: deps.appendingPathComponent("libvulkan.dylib").path)
            || fm.fileExists(atPath: deps.appendingPathComponent("libvulkan.1.dylib").path)
            || fm.fileExists(atPath: deps.appendingPathComponent("libMoltenVK.dylib").path)

        var mono = false
        let monoDir = root.appendingPathComponent("share/wine/mono")
        if let items = try? fm.contentsOfDirectory(atPath: monoDir.path) {
            mono = items.contains { $0.hasPrefix("wine-mono-") && $0.hasSuffix(".msi") }
        }

        return Report(sdl2: sdl2, vulkan: vulkan, mono: mono, source: "probe")
    }

    /// `winebus.so` fa `dlopen("libSDL2.dylib")`: se il simbolo c'è, la feature è compilata.
    static func winebusReferencesSDL2(root: URL) -> Bool {
        let so = root.appendingPathComponent("lib/wine/x86_64-unix/winebus.so")
        guard let data = try? Data(contentsOf: so, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("libSDL2".utf8)) != nil
    }
}
