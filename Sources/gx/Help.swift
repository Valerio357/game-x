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
          gx box list [--trash]                 (a box with a live lock is tagged (locked))
          gx box create <name> [--runtime wine-gptk|dxmf|dxmt|staging|gptk|homebrew|<path>] [--force]
                                 (default runtime: wine-gptk = Wine+D3DMetal;
                                  `--runtime dxmf` uses the patched host + the dxmf stage
                                  and refuses a host whose version does not match the
                                  modules, unless --force)
          gx box info <name>                    (prints the live/stale lock when present)
          gx box remove <name> --yes [--purge]
          gx box purge <entry> | --all
          gx box exec <name> [--runtime ...] -- <cmd...>   run any Windows program
          gx box run <name> [--runtime ...] -- <cmd...>    (alias of exec)
          gx box kill <name>
          gx box open <name>
          (alias: gx prefix ...)
          Mutating box commands take the per-box lock; --lock-wait SEC waits for it
          and --force breaks a live lock (naming the holder: pid, age, command, reason).

        \(Out.bold("THE LOCK IS FOR MUTATIONS, NOT FOR RUNS"))
          Mutations (box create/remove/purge, steam install/repair, deps install,
          steam stop/box kill) hold the lock while they mutate.
          RUNS (dxmf run, steam run, steam launch, box exec, game launch) do NOT
          hold it: Steam stays open, the game is launched next to it. That is the
          real sequence — Steam alive + game in the SAME box:
              gx steam run  <box> &
              gx dxmf run   <box> -- <game exe>
          A run only *checks* that no mutation is in progress: --lock-wait SEC
          waits for it, --no-lock (or --force) proceeds and says so.
          Recreating/removing a box that is IN USE is refused, naming the
          processes; --force overrides it.

        \(Out.bold("DXMF"))   (run a game under the dxmf D3D11/D3D9 modules)
          gx dxmf status [box]                  host+version, stage+modules, version pin+source,
                                                host capabilities, resolved deps folder and which
                                                of freetype/MoltenVK/gnutls it provides, default
                                                log cap, winedbg orphan count, and the box lock
                                                (exit 0 only if the modules load)
          gx dxmf modules [box]                 each module's PE and unix path + sha256
                                                (content proof for lsof)
          gx dxmf run <box> [flags] -- <cmd...> launch a game with the dxmf environment:
                                     --appid N          set SteamAppId/SteamGameId
                                     --winedebug SPEC   WINEDEBUG=SPEC (requires a finite log cap)
                                     --max-log-mb N     log cap in MB (default 512; 0 = unlimited,
                                                        with a loud warning; measured with du)
                                     --frame-log FILE   DXMF_FRAME_TIME (diagnostics, off by default)
                                     --lock-wait SEC    wait for the box lock
                                     --force            break a live lock / run when crowded
                                     --sweep            kill winedbg --auto orphans first
                                     --dry-run          print the plan and the environment, do not launch
                                     --verbose|--debug  turn dxmf diagnostics on (default: quiet)
                                     (without `--` the args after the box are the command)

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
          gx steam launch  <box> <appid> [--exe <path>] [--no-warmup]
                                     (with --runtime dxmf the game is launched directly with
                                      the dxmf contract + SteamAppId; --exe skips the resolution)
          gx steam warmup  <box> <appid> [--stop]    compile shaders once, outside the game
          gx steam input   <box> [--check|--on]            physical pad (default) / Steam virtual pad (--on)
          gx steam stop    [box]
          steam mutations take the box lock (--lock-wait/--force as above);
          Steam itself never carries the dxmf contract.

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
          env:  GX_PREFIX_ROOT, GX_GPTK_APP, GX_WINE, GX_LOG_LEVEL, GX_DXMF_STAGE, GX_DXMF_LOG_CAP_MB, ...

          dxmf log cap: GX_DXMF_LOG_CAP_MB / [dxmf] log_cap_mb (default 512 MB).
          The real size written is always measured with du; when the cap is hit the
          log is truncated and a marker line is appended, and the game keeps running.

        Precedence: CLI flags → GX_* env → config.toml → defaults.
        """
        Out.print(text)
    }
}
