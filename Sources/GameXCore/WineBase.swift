import Foundation

/// Base **Wine dai sorgenti CodeWeavers** (schema TEB-in-TSD) usata dal runtime
/// `wine-gptk`. Costruirla richiede ~40-60 min, quindi la trattiamo come un
/// artefatto scaricabile: se manca, la scarichiamo dal release GitHub (`wine-cx`
/// + `x64deps`, senza D3DMetal che non è ridistribuibile).
public enum WineBase {

    /// Cartella attesa da `build-runtime-gptk.sh` per default.
    public static var defaultRoot: String { "\(NSHomeDirectory())/wine-cx" }

    /// Asset stabile del release (GitHub redirige all'ultimo release pubblicato).
    public static let assetName = "wine-cx-macos-x86_64.tar.xz"
    public static let downloadURLString =
        "https://github.com/Valerio357/game-x/releases/latest/download/\(assetName)"

    public static func isInstalled(root: String = defaultRoot) -> Bool {
        FileManager.default.isExecutableFile(atPath: "\(root)/bin/wine")
    }

    /// Se la base manca, la scarica (o usa `--wine-tar`) e la estrae; ritorna il
    /// wine-root da passare a `build-runtime-gptk.sh`.
    @discardableResult
    public static func ensure(root: String = defaultRoot, tar: String? = nil,
                              progress: (String) -> Void = { _ in }) throws -> String {
        if isInstalled(root: root) { return root }

        let archive: URL
        if let tar, !tar.isEmpty {
            if tar.hasPrefix("http://") || tar.hasPrefix("https://") {
                guard let url = URL(string: tar) else { throw WineBaseError.badURL(tar) }
                archive = try download(url, progress: progress)
            } else {
                archive = URL(fileURLWithPath: (tar as NSString).expandingTildeInPath)
            }
        } else {
            archive = try download(URL(string: downloadURLString)!, progress: progress)
        }

        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw WineBaseError.archiveMissing(archive.path)
        }

        // L'archivio contiene `wine-cx/` alla radice: estraiamo nel genitore del root.
        let parent = URL(fileURLWithPath: root).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        progress("Extracting \(archive.lastPathComponent)…")
        let extract = try ProcessRunner.run("/usr/bin/tar", ["-xJf", archive.path, "-C", parent.path])
        guard extract.success else { throw WineBaseError.extractFailed(extract.stderr) }
        guard isInstalled(root: root) else {
            throw WineBaseError.extractFailed("bin/wine not found after extracting into \(parent.path)")
        }
        return root
    }

    static func download(_ url: URL, progress: (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let dest = fm.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }

        // 1) `gh` (autenticato): funziona anche se il repo è **privato**.
        if url.host == "github.com", let gh = ghPath() {
            let asset = url.lastPathComponent
            let dir = fm.temporaryDirectory.appendingPathComponent("gx-winebase-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            progress("Downloading \(asset) via gh…")
            let r = try? ProcessRunner.run(gh, ["release", "download", "-R", "Valerio357/game-x",
                                                "-p", asset, "-D", dir.path, "--clobber"])
            let file = dir.appendingPathComponent(asset)
            if r?.success == true, fm.fileExists(atPath: file.path) {
                try? fm.moveItem(at: file, to: dest)
                try? fm.removeItem(at: dir)
                return dest
            }
            try? fm.removeItem(at: dir)
        }

        // 2) curl anonimo (repo pubblico).
        progress("Downloading \(url.lastPathComponent) (can be ~137 MB)…")
        let result = try ProcessRunner.run("/usr/bin/curl", ["-fL", url.absoluteString, "-o", dest.path])
        guard result.success, fm.fileExists(atPath: dest.path) else {
            throw WineBaseError.downloadFailed(result.stderr.isEmpty ? "curl exit \(result.exitCode)" : result.stderr)
        }
        return dest
    }

    static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public enum WineBaseError: Error, LocalizedError {
        case badURL(String)
        case archiveMissing(String)
        case downloadFailed(String)
        case extractFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badURL(let u): return "invalid URL: \(u)"
            case .archiveMissing(let p): return "archive not found: \(p)"
            case .downloadFailed(let d):
                return "download failed: \(d)\n  If the repo is private: install `gh` (`brew install gh`) and run `gh auth login`,\n  or download the `wine-cx-macos-x86_64.tar.xz` asset manually and\n  extract it with: tar -xJf <file> -C \"$HOME\""
            case .extractFailed(let d): return "estrazione fallita: \(d)"
            }
        }
    }
}
