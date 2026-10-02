import Foundation

/// Registro dei giochi (DESIGN §12).
public struct GameEntry: Codable, Sendable, Identifiable {
    public var name: String
    public var prefix: String
    public var appid: Int?
    public var exe: String?
    public var args: [String]
    public var env: [String: String]
    public var notes: String?

    public var id: String { name }

    public init(
        name: String,
        prefix: String,
        appid: Int? = nil,
        exe: String? = nil,
        args: [String] = [],
        env: [String: String] = [:],
        notes: String? = nil
    ) {
        self.name = name
        self.prefix = prefix
        self.appid = appid
        self.exe = exe
        self.args = args
        self.env = env
        self.notes = notes
    }
}

/// Persistenza del registro giochi su `registry.json`.
public struct GameRegistry: Codable, Sendable {
    public var version: Int
    public var games: [GameEntry]

    public init(version: Int = 1, games: [GameEntry] = []) {
        self.version = version
        self.games = games
    }

    public static func url(gamesRoot: URL) -> URL {
        gamesRoot.appendingPathComponent("registry.json")
    }

    public static func load(gamesRoot: URL) -> GameRegistry {
        let url = Self.url(gamesRoot: gamesRoot)
        guard let data = try? Data(contentsOf: url),
              let registry = try? JSONDecoder().decode(GameRegistry.self, from: data) else {
            return GameRegistry()
        }
        return registry
    }

    public static func load(config: Config) -> GameRegistry {
        load(gamesRoot: config.resolvedPaths().gamesRoot)
    }

    public func save(gamesRoot: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: gamesRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.url(gamesRoot: gamesRoot))
    }

    public func save(config: Config) throws {
        try save(gamesRoot: config.resolvedPaths().gamesRoot)
    }

    // MARK: - Mutazioni

    public func find(_ name: String) -> GameEntry? {
        games.first { $0.name == name }
    }

    /// Aggiunge o sostituisce una entry (per nome).
    public mutating func upsert(_ entry: GameEntry) {
        if let index = games.firstIndex(where: { $0.name == entry.name }) {
            games[index] = entry
        } else {
            games.append(entry)
        }
        games.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public mutating func remove(_ name: String) -> Bool {
        let before = games.count
        games.removeAll { $0.name == name }
        return games.count != before
    }
}
