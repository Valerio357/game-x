import Foundation

/// Accesso alle **risorse incluse nel bundle** `GameXCore`
/// (bundle SwiftPM `game-x_GameXCore.bundle`).
///
/// Perché non `Bundle.module`: l'accessor generato da SwiftPM cerca il bundle
/// **solo** in `Bundle.main.bundleURL/game-x_GameXCore.bundle` (radice dell'app)
/// e in un path di build assoluto; fuori dal checkout del repo il fallback non
/// esiste → `fatalError`. Qui cerchiamo in tutti i posti plausibili, così
/// funziona dentro `GameX.app`, quando l'app lancia `gx`, e con App Translocation.
public enum BundledResources {

    public static let bundleName = "game-x_GameXCore"

    /// URL di una risorsa (nil se non trovata). Cerca, nell'ordine:
    /// bundle accanto all'eseguibile, `Contents/{MacOS,Resources}`, radice
    /// dell'app, `Bundle.main.resourceURL`, e infine il checkout sorgente.
    public static func url(_ name: String, ext: String) -> URL? {
        let fm = FileManager.default
        let file = "\(name).\(ext)"
        let bundleDir = bundleName + ".bundle"
        var roots: [URL] = []

        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let macos = exe.deletingLastPathComponent()
            let contents = macos.deletingLastPathComponent()
            // build dir di SwiftPM / `swift run`: bundle accanto all'eseguibile
            roots.append(macos.appendingPathComponent(bundleDir))
            roots.append(macos)                                              // risorsa piatta
            // layout .app: Contents/MacOS/… e Contents/Resources/…
            roots.append(contents.appendingPathComponent("Resources/\(bundleDir)"))
            roots.append(contents.appendingPathComponent("Resources"))
        }

        let app = Bundle.main.bundleURL
        roots.append(app.appendingPathComponent(bundleDir))                  // ciò che cerca l'accessor SwiftPM
        roots.append(app.appendingPathComponent("Contents/Resources/\(bundleDir)"))
        if let res = Bundle.main.resourceURL {
            roots.append(res.appendingPathComponent(bundleDir))
            roots.append(res)
        }

        // Sviluppo: risorse grezze nel checkout sorgente.
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources"))

        for root in roots {
            let candidate = root.appendingPathComponent(file)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Path dello script `build-runtime-gptk.sh` (nil se assente).
    public static var buildRuntimeScript: String? {
        url("build-runtime-gptk", ext: "sh")?.path
    }

    /// Path del sorgente C dello shim `steamwebhelper`.
    public static var shimSource: URL? {
        url("steamwebhelper_shim", ext: "c")
    }
}
