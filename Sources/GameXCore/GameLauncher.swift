import Foundation

/// Launching a registered game (M4).
public enum GameLauncher {

    public enum LaunchError: Error, CustomStringConvertible {
        case notFound(String)
        case prefixMissing(String, String)
        case noTarget(String)
        case steamMissing(String)

        public var description: String {
            switch self {
            case .notFound(let n): return "game '\(n)' is not in the registry"
            case .prefixMissing(let g, let p): return "box '\(p)' for game '\(g)' not found"
            case .noTarget(let n): return "game '\(n)' has neither appid nor exe"
            case .steamMissing(let p): return "Steam is not installed in box '\(p)' (required for appid)"
            }
        }
    }

    /// The command/action that would run (for `game show` / dry-run).
    public struct Plan: Sendable {
        public let prefixName: String
        public let wineBinary: String
        public let args: [String]
        public let env: [String: String]
    }

    /// Computes the launch plan without running it.
    public static func plan(
        for entry: GameEntry,
        config: Config,
        paths: Paths,
        runtime: ResolvedRuntime
    ) throws -> Plan {
        guard let prefix = Prefix.find(entry.prefix, paths: paths) else {
            throw LaunchError.prefixMissing(entry.name, entry.prefix)
        }

        if let appid = entry.appid {
            guard prefix.hasSteam else { throw LaunchError.steamMissing(prefix.name) }
            return Plan(prefixName: prefix.name, wineBinary: runtime.wineBinary,
                        args: [prefix.steamExe.path, "-applaunch", String(appid)] + entry.args,
                        env: entry.env)
        }

        guard let exe = entry.exe else { throw LaunchError.noTarget(entry.name) }
        return Plan(prefixName: prefix.name, wineBinary: runtime.wineBinary,
                    args: [exe] + entry.args, env: entry.env)
    }

    /// Launches a registered game.
    @discardableResult
    public static func launch(
        _ entry: GameEntry,
        config: Config,
        paths: Paths,
        runtime: ResolvedRuntime
    ) throws -> ProcessResult {
        let plan = try plan(for: entry, config: config, paths: paths, runtime: runtime)
        guard let prefix = Prefix.find(plan.prefixName, paths: paths) else {
            throw LaunchError.prefixMissing(entry.name, entry.prefix)
        }
        return try Prefix.exec(
            prefix,
            command: plan.args,
            config: config,
            runtime: runtime,
            extraEnv: plan.env
        )
    }
}
