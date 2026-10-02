import Foundation

enum Help {
    static func printUsage() {
        let text = """
        \(Out.bold("gx")) — Game-X: run Steam and Windows games on macOS via GPTK/Wine

        \(Out.bold("USAGE"))
          gx <command> [subcommand] [options]

        \(Out.bold("ENVIRONMENT"))
          gx info [--json]           Configuration and resolved runtime
          gx doctor [--json] [--fix] Full environment diagnostics (--fix installs missing components)
          gx gpu info [--json]       GPU/Metal capabilities and Metal 4 verdict
          gx runtime list            Available Wine runtimes
          gx runtime status          Details of the Game-X runtimes
          gx runtime install         Install Wine+DXMT (--tar FILE | --url URL | --from-source)
          gx runtime build-gptk      Build wine-gptk: Wine (CodeWeavers) + D3DMetal [default runtime]
                                     flags: [--wine-root DIR] [--wine-tar FILE|URL] [--gptk-dmg FILE]
                                            [--name N] [--dry-run]
                                     (if ~/wine-cx is missing, it downloads the Wine base;
                                      D3DMetal comes from Apple's GPTK 4 DMG)
          gx runtime mono            Ensure wine-mono is installed in the boxes

        \(Out.bold("BOXES"))
          gx box list [--trash]
          gx box create <name> [--runtime wine-gptk|dxmt|staging|gptk|homebrew|<path>] [--force]
                                 (default runtime: wine-gptk = Wine+D3DMetal)
          gx box info <name>
          gx box remove <name> --yes [--purge]
          gx box purge <entry> | --all
          gx box exec <name> [--runtime ...] -- <cmd...>   run any Windows program
          gx box run <name> [--runtime ...] -- <cmd...>    (alias of exec)
          gx box kill <name>
          gx box open <name>
          (alias: gx prefix ...)

        \(Out.bold("DEPENDENCIES"))
          gx deps list
          gx deps status  <box>
          gx deps install <box> <verb...> [--dry-run]
          gx deps remove  <box> <verb...>

        \(Out.bold("STEAM"))
          gx steam status  [box]
          gx steam install [box] [--setup <path>] [--runtime ...] [--force] [--no-update]
          gx steam repair  [box] [--runtime ...]
          gx steam run     [box]
          gx steam launch  <box> <appid>
          gx steam warmup  <box> <appid> [--stop]    compile shaders once, outside the game
          gx steam input   <box> [--check|--on]            physical pad (default) / Steam virtual pad (--on)
          gx steam stop    [box]

        \(Out.bold("GAMES"))   (also launchable from Steam itself)
          gx game list
          gx game add <name> --prefix <box> [--appid <id> | --exe <path>] [--arg <a>]* [--env K=V]* [--notes <t>]
          gx game show <name>
          gx game remove <name>
          gx game launch <name> [--runtime ...] [--dry-run]

        \(Out.bold("SETUP"))
          gx setup --list             Components and status
          gx setup [--dry-run]        Install missing components
          gx setup --only <id>        Install a single component

        \(Out.bold("LOGS"))
          gx log path                 CLI log file path
          gx log list                 List log files
          gx log tail [name] [--lines N]

        \(Out.bold("OTHER"))
          gx version | gx help

        \(Out.bold("GLOBAL FLAGS"))
          -v, --verbose, --debug      debug logging
          --quiet                     errors only (stderr and ~/Library/Logs/game-x/gx.log)

        \(Out.bold("CONFIG"))
          file: ~/.config/game-x/config.toml
          env:  GX_PREFIX_ROOT, GX_GPTK_APP, GX_WINE, GX_LOG_LEVEL, ...

        Precedence: CLI flags → GX_* env → config.toml → defaults.
        """
        Out.print(text)
    }
}
