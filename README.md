# Game-X

Swift CLI + core to run **Steam** and Windows games on macOS through
**Apple Game Porting Toolkit (GPTK)** / **Wine** / **winetricks**, with a
DirectX → D3DMetal → Metal rendering path.

> Personal, unofficial project. Not affiliated with Valve, Apple or CodeWeavers.
> It does not redistribute Valve binaries or Apple D3DMetal/GPTK. See `DESIGN.md` §15.

## Status

- **M0** — core + CLI skeleton: `gx info`, `gx doctor`, runtime discovery. ✅
- **M1** — prefix management (create/list/info/exec/kill/remove/purge/open, per-prefix runtime). ✅
- **M2** — dependencies via winetricks (list/status/install/remove, reliable detection, log). ✅
- **M3** — Steam: working UI PoC + `gx steam install/repair/run` in the core (shim compiled from the bundle). ✅
- **M4** — game registry + launch (`game add/list/show/remove/launch`, appid and exe, per-game env). ✅
- **M5** — logging + advanced doctor + `gpu info`, with `--json` output. ✅
- **M6** — SwiftUI app `GameX` on the shared core (dashboard, prefixes, Steam, games, logs). ✅

Full design: [`DESIGN.md`](DESIGN.md).

## Requirements

The complete first-run path is in **[UX.md](UX.md)** (everything you need + happy
flow). In short:

- Apple Silicon Mac + Rosetta 2 (`softwareupdate --install-rosetta`)
- **Xcode Command Line Tools** (`xcode-select --install`) — to build Wine and the shim
- **Homebrew** (https://brew.sh) → `winetricks`, `mingw-w64`, `cabextract`
- **Game-X `wine-gptk` runtime** (default): Wine from CodeWeavers sources + Apple
  **D3DMetal**. Built with `gx runtime build-gptk`: it downloads the Wine base
  automatically and takes D3DMetal from Apple's **Game Porting Toolkit 4 DMG**
  (free, developer.apple.com). The **Steam UI requires Wine ≥ 8**.
- **macOS permissions** (Privacy & Security): *Accessibility* and *Input Monitoring*
  for `…/runtimes/wine-gptk/bin/wine` and for GameX.app — needed for keyboard and controller.
- A system runtime (GPTK/Wine Staging) is **optional**: `wine-gptk` is self-contained.

`gx doctor` checks all of the above (including TCC permissions and runtime features:
`sdl2`, `vulkan`, `mono`) and `gx setup` installs whatever can be automated.

## Build

```sh
swift build
swift run gx help
swift run gx-selftest      # core self-test (no XCTest dependency)
```

### macOS app (`GameX`)

```sh
scripts/build-app.sh release   # → dist/GameX.app (also bundles the `gx` CLI in Contents/MacOS)
open dist/GameX.app
```

On first launch (app not notarized): right-click the icon → **Open**. The GUI uses the same `GameXCore` as the CLI.

## Quick usage

```sh
gx doctor                  # environment diagnostics
gx info                    # configuration + resolved runtime
gx runtime list            # available Wine runtimes
gx gpu info                # Metal capabilities / Metal 4 verdict

gx prefix list
gx prefix create SteamStaging                   # boxes always use Wine Staging
gx prefix info SteamStaging
gx prefix exec SteamStaging -- cmd /c ver       # run any Windows program
gx prefix exec SteamStaging -- notepad
gx prefix kill SteamStaging
gx prefix remove SteamStaging --yes          # recoverable (internal trash)
gx prefix purge --all                        # empty the trash

gx doctor --fix                              # install missing components from diagnostics

gx steam status SteamStaging
gx steam install SteamStaging                  # downloads online: setup + first update + shim
gx steam repair SteamStaging                        # after an auto-update
gx steam run SteamStaging
gx steam launch SteamStaging 1245620   # by AppID

gx deps list
gx deps status SteamStaging
gx deps install SteamStaging vcrun2022
gx deps install SteamStaging corefonts d3dcompiler_47 --dry-run

gx game add elden-ring --prefix SteamStaging --appid 1245620
gx game launch elden-ring --dry-run
gx game list

gx doctor --json
gx gpu info --json
gx log tail --lines 20
```

## Configuration

`~/.config/game-x/config.toml` (see `Resources/default-config.toml`).

Precedence: **CLI flags → `GX_*` environment variables → `config.toml` → defaults**.
Variables: `GX_PREFIX_ROOT`, `GX_GAMES_ROOT`, `GX_GPTK_APP`, `GX_WINE`,
`GX_WINETRICKS`, `GX_LOG_LEVEL`.

## Game-X Wine + DXMT (Steam **and** D3D11 games → Metal)

A single runtime runs both **modern Steam** and **DirectX 10/11 games** on Apple Silicon:
our own Wine 11.10 x86_64 (CodeWeavers CW HACK 22435 patch + `winemetal` stub) with
the **DXMT** renderer (D3D11 → Metal). It is self-contained: one folder you can copy
to another machine and it works.

```sh
gx runtime install --tar game-x-wine-dxmt-11.10-macos-x86_64.tar.xz --sha256 <hash>
# or, building from source (~40-60 min):
gx runtime install --from-source

gx runtime status

# a box ready for Steam + D3D11 games
gx box create Steam --runtime dxmt
gx steam install Steam && gx steam run Steam
```

To create the package from an existing build: `./scripts/package-runtime.sh`
(writes `dist/game-x-wine-dxmt-<ver>-macos-x86_64.tar.xz` + sha256); to rebuild it
from scratch: `./scripts/build-wine-dxmt.sh`.

Full recipe, patches, environment variables, measured CEF flags and limits:
**[DESIGN-DXMT.md](DESIGN-DXMT.md)**.

## The Steam black-screen fix

On macOS/Wine the Steam UI is black because of **Wine bug #60263**
(`winemac.drv`: cross-process child window Metal swapchain not implemented).
The fix is a `steamwebhelper.exe` shim that injects
`--no-sandbox --disable-gpu --single-process`. It no longer uses `chflags uchg`
(which blocked Steam updates → fatal error): the shim is recognized via a marker and
reinstalled automatically.

On the **Game-X Wine+DXMT** runtime the `--disable-gpu --single-process` combination
is the one **measured** to work (0 GPU errors, complete UI); without
`--single-process` the window stays black because frames do not cross
the process boundary. See `DESIGN-DXMT.md`.

```sh
scripts/build-steamwebhelper-shim.sh --install ~/WinePrefixes/SteamStaging
```

Details in `DESIGN.md` §11.

## Layout

```
Sources/GameXCore/            shared core (logic)
Sources/GameXCore/Resources/  C shim (bundled resource)
Sources/gx/                   CLI frontend
Sources/gx-selftest/          standalone test harness
Sources/GameX/                SwiftUI frontend (macOS app)
Resources/                    sample config
scripts/                      build shim, build-app, install
```

## License

Project code: **MIT** (see [`LICENSE`](LICENSE)). Third-party components
(Wine, GPTK/D3DMetal, Steam, winetricks) belong to their respective owners.

In particular: **Apple D3DMetal/GPTK and Valve binaries are not redistributed**.
The downloadable `wine-cx` base is **Wine** (LGPL-2.1-or-later) and includes the
license texts (`LICENSE`, `COPYING.LIB`) and a `NOTICE` file listing the components.
D3DMetal is obtained by the user from their own Apple GPTK copy and `gx runtime build-gptk`
injects it locally.

## Wine + D3DMetal runtime (`wine-gptk`)

Besides **Wine+DXMT**, Game-X supports a **Wine + D3DMetal** runtime:

```bash
gx runtime list                      # shows the "GPTK: wine-11.0-…" runtime if installed
gx box create Mine --runtime gptk    # a box with D3DMetal
gx box exec  Mine --runtime gptk -- C:\d3dvis.exe
```

**Why a CodeWeavers Wine is needed (and not upstream Wine).** Apple's D3DMetal
glue (`libd3dshared` = `d3d11.so`/`dxgi.so`) calls Mach-O functions
**directly from PE code** (fast path `gGFXTDispatch+0x150` in
`dxgi.dll!Thunk_Thread`, `gGFXTDispatch+N` in every entry point). That code uses
libc → `%gs` must be the **macOS TSD**. Upstream Wine puts the **Windows TEB
in `%gs`**: `%gs:0 == 0` and the first libc call
(`pthread_setname_np("D3DMetalWineThread")`) page-faults on `0x0`
(`_pthread_setname_np+51`, `xor (%rbx),%rax`). CodeWeavers Wine, instead, does not
touch `%gs` (`get_current_teb() = rsp & ~signal_stack_mask`, TEB fields written
inside the TSD page) → D3DMetal works.

Runtime layout (self-contained, `~/Library/Application Support/game-x/runtimes/wine-gptk`):

    bin/wine                                   (build from CodeWeavers public sources)
    lib/wine/x86_64-{unix,windows}/…           (D3DMetal dll: d3d11, dxgi, d3d12, …)
    lib/external/{D3DMetal.framework, libd3dshared.dylib}
    x64deps/*.dylib                            (MoltenVK, freetype…)
    manifest.json

Details and measurements: `~/Workspace/d3dmetal-wine/PLAN.md` §14-15.

### Self-contained runtimes (no external dependency)

Game-X does not require GPTK, Wine Staging, Homebrew or `~/x64deps`: each runtime
contains Wine + renderer + dependencies + wine-mono.

| Runtime | What it contains | When to use it |
|---|---|---|
| `wine-gptk` | Wine from **CodeWeavers sources** + **D3DMetal** (Apple Game Porting Toolkit) | **default**: Apple's shader path; the only supported box |
| `wine-dxmt` | Wine 11.10 + **DXMT** (D3D11→Metal, open source) | open-source fallback |
| GPTK / Wine Staging / Homebrew | system runtimes, **optional** | fallback |

Rebuild the D3DMetal runtime (reproducible, no third-party app — only Apple's
**Game Porting Toolkit 4 DMG** is needed as the source of the D3DMetal files):

```bash
gx runtime build-gptk                              # inside the tool (auto Wine base + DMG in ~/Downloads)
gx runtime build-gptk --gptk-dmg ~/Downloads/Evaluation_environment_for_Windows_games_*.dmg --dry-run
scripts/build-runtime-gptk.sh --gptk-dmg /path/to/Evaluation_environment_for_Windows_games_4.0_beta_1.dmg
```

The runtime is chosen **per box** (dropdown next to "New box name", or
`gx box create NAME --runtime wine-gptk`; **default = wine-gptk**). The line under each
box name shows the effective runtime, e.g.
`Game-X Wine+D3DMetal — wine-11.0 / D3DMetal 4.0b2 [wine-gptk]`.

## Keyboard and controller in-game (macOS, Wine)

Typical symptom: **the mouse works, keyboard and gamepad do not**. On macOS game input
goes through *global* capture (`CGEventTap` / `IOHIDManager`), which requires TCC
permissions **tied to the binary's path** — so a new runtime (`wine-gptk`) does not
inherit the permissions granted to `wine-dxmt`.

Checklist:

1. **System Settings → Privacy & Security**
   - **Accessibility**: add the binary of the runtime in use, e.g.
     `~/Library/Application Support/game-x/runtimes/wine-gptk/bin/wine`
     (and, if present, `wine64-preloader`). Also add the app that launches games
     (GameX.app, Terminal.app or the IDE) because the spawn permission belongs to the ancestor.
   - **Input Monitoring**: same thing (needed by `winebus`/IOKit for keyboard and gamepad).
2. **Launch the game from the GUI or from Steam**, not from a headless shell: the window must
   become the *key window*/active app, otherwise AppKit delivers keys to another app.
3. **Controller**: the default is the **physical pad** via XInput (Steam Input disabled
   for games). With SDL2 in the runtime, Wine sees the pad — verified with
   `gxpadlive.exe` (buttons, sticks and triggers that change).
   ```bash
   gx steam input <box> --check  # status per game
   gx steam input <box>          # disable Steam Input (physical pad, default)
   gx steam input <box> --on     # Steam virtual pad (requires Steam to detect the pad)
   ```
   ⚠️ On macOS with a **Bluetooth LE** pad (Xbox PID `0x0B13`) Steam tends to **not
   detect it**: with Steam Input ON the overlay grabs XInput and *hides* the physical
   pad without creating a virtual one → the game sees no controller.
   In that case use the default (physical pad) or connect the pad via USB.
4. The runtime includes **SDL2** in `x64deps/` (Wine loads it via `dlopen`): verify with
   `strings <runtime>/lib/wine/x86_64-unix/winebus.so | grep -i libSDL2`.
5. If the keyboard works but the pad does not, check that the pad is visible to macOS
   (Bluetooth/USB) and retry with `gx box exec <box> -- C:\gxpad.exe` (Game-X pad test).
