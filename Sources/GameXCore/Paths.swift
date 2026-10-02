import Foundation

/// Risoluzione dei percorsi di Game-X.
///
/// Precedenza: variabili d'ambiente `GX_*` → `config.toml` → default.
/// Questa struct non legge il file: riceve i valori già risolti da `Config`.
public struct Paths: Sendable {
    public let prefixRoot: URL
    public let gamesRoot: URL
    public let logsRoot: URL
    public let cacheRoot: URL
    public let gptkApp: URL
    public let wineBinaryOverride: String?
    public let winetricks: String
    public let shimExecutable: URL?

    public init(
        prefixRoot: URL,
        gamesRoot: URL,
        logsRoot: URL,
        cacheRoot: URL,
        gptkApp: URL,
        wineBinaryOverride: String?,
        winetricks: String,
        shimExecutable: URL?
    ) {
        self.prefixRoot = prefixRoot
        self.gamesRoot = gamesRoot
        self.logsRoot = logsRoot
        self.cacheRoot = cacheRoot
        self.gptkApp = gptkApp
        self.wineBinaryOverride = wineBinaryOverride
        self.winetricks = winetricks
        self.shimExecutable = shimExecutable
    }

    public static func expand(_ raw: String) -> String {
        (raw as NSString).expandingTildeInPath
    }

    public static func url(_ raw: String) -> URL {
        URL(fileURLWithPath: expand(raw), isDirectory: true)
    }
}

/// Default usati quando config e ambiente non specificano nulla.
public enum DefaultPaths {
    public static let prefixRoot = "~/WinePrefixes"
    public static let gamesRoot = "~/Library/Application Support/game-x/games"
    public static let logsRoot = "~/Library/Logs/game-x"
    public static let cacheRoot = "~/Library/Caches/game-x"
    public static let gptkApp = "/Applications/Game Porting Toolkit.app"
    public static let wineStagingApp = "/Applications/Wine Staging.app"
    public static let winetricks = "/opt/homebrew/bin/winetricks"
    public static let homebrewWine = "/opt/homebrew/bin/wine64"

    public static var configFile: URL {
        Paths.url("~/.config/game-x/config.toml")
    }

    public static var wineStagingBinary: String {
        "\(wineStagingApp)/Contents/Resources/wine/bin/wine"
    }

    public static var gptkWineBinary: String {
        "\(gptkApp)/Contents/Resources/wine/bin/wine64"
    }
}
