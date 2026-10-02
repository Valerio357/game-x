import Foundation

/// Un'installazione di Game Porting Toolkit trovata sul sistema.
public struct GPTKInstall: Sendable, Identifiable {
    public let appPath: String
    public let bundleVersion: String?   // Info.plist CFBundleShortVersionString
    public let wineVersion: String?     // `wine --version`
    public var id: String { appPath }

    public var displayVersion: String {
        if let bundleVersion { return "GPTK \(bundleVersion)" }
        if let wineVersion { return wineVersion }
        return "GPTK"
    }

    /// Major di GPTK dedotta dalla versione del bundle (es. "3.0-2" → 3).
    public var major: Int? {
        guard let bundleVersion else { return nil }
        var digits = ""
        for ch in bundleVersion {
            if ch.isNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
}

/// Rilevamento GPTK e mappatura macOS → versione raccomandata (M6b).
public enum GPTK {

    /// Cartelle dove cercare il bundle GPTK.
    public static let searchDirs = ["/Applications", "/Users/Shared"]

    /// Trova tutte le installazioni GPTK.
    public static func discover(config: Config) -> [GPTKInstall] {
        var paths = Set<String>()
        paths.insert(config.gptkApp)
        for dir in searchDirs {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for name in entries where name.contains("Porting Toolkit") && name.hasSuffix(".app") {
                    paths.insert("\(dir)/\(name)")
                }
            }
        }

        return paths.sorted().compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let plist = "\(path)/Contents/Info.plist"
            let bundle = ProcessRunner.firstLine("/usr/libexec/PlistBuddy",
                                                 ["-c", "Print :CFBundleShortVersionString", plist])
            let wine = "\(path)/Contents/Resources/wine/bin/wine64"
            let wineVersion = FileManager.default.isExecutableFile(atPath: wine)
                ? ProcessRunner.firstLine(wine, ["--version"]) : nil
            return GPTKInstall(appPath: path, bundleVersion: bundle, wineVersion: wineVersion)
        }
    }

    /// Versione GPTK raccomandata per una data major di macOS.
    public static func recommended(for macOSMajor: Int) -> Int {
        switch macOSMajor {
        case ..<13: return 1
        case 13, 14: return 2
        case 15, 16, 26: return 3
        default: return 4          // macOS 27+
        }
    }

    /// How to obtain the recommended version.
    public static func installHint(for macOSMajor: Int) -> String {
        let rec = recommended(for: macOSMajor)
        switch rec {
        case 4:
            return "GPTK 4: download from developer.apple.com/games/game-porting-toolkit (Apple ID required; not on Homebrew)"
        case 3:
            return "GPTK 3: `brew install --cask game-porting-toolkit` (Gcenx build) or developer.apple.com"
        default:
            return "GPTK \(rec): developer.apple.com/games/game-porting-toolkit"
        }
    }

    /// Compatibility verdict between installed GPTK and the current macOS.
    public static func verdict(installs: [GPTKInstall], macOSMajor: Int) -> (status: Doctor.Status, message: String) {
        guard let best = installs.compactMap({ $0.major }).max() else {
            return (.warn, "GPTK not installed (recommended: GPTK \(recommended(for: macOSMajor)))")
        }
        let rec = recommended(for: macOSMajor)
        if best < rec {
            return (.warn, "GPTK \(best) installed; macOS \(macOSMajor) recommends GPTK \(rec) (\(installHint(for: macOSMajor)))")
        }
        return (.ok, "GPTK \(best) compatible with macOS \(macOSMajor)")
    }
}
