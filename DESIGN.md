# Game-X — Design Document

> CLI per eseguire **Steam** e giochi Windows su macOS tramite **Apple Game Porting Toolkit (GPTK)** + **Wine** + **winetricks**, con percorso di rendering DirectX → **D3DMetal** → Metal (incluso, dove disponibile, **Metal 4**).

Stato: **bozza di progettazione (pre-implementazione)**
Data: 2026-10-01
Autore: Valerio Domenici

---

## 1. Obiettivo

Fornire un singolo strumento a riga di comando (`gx`) che automatizzi il ciclo di vita di un ambiente di gioco Windows su macOS:

- Creazione e gestione dei **Wine prefix**.
- Installazione e lancio di **Steam** (con le workaround necessarie).
- Installazione delle **dipendenze Windows** via `winetricks` (VC++ runtime, .NET, dll override).
- Lancio di **giochi** sia tramite Steam (`applaunch`) sia diretti (`exe`).
- Diagnostica chiara di cosa funziona e cosa no (**`gx doctor`**).

### 1.1 Non-obiettivi

- **Non** è un game store né un client di download.
- **Non** aggira DRM, anti-cheat o verifiche di proprietà.
- **Non** ridistribuisce GPTK, D3DMetal, Steam, giochi o runtime di terze parti.
- **Non** fornisce una GUI (target primario = CLI; eventuale GUI è fuori scope).
- **Non** promette compatibilità universale: è un toolkit, non un launcher consumer.

---

## 2. Contesto tecnico e vincoli

### 2.1 Catena di rendering

```
Gioco DirectX 9/10/11  →  D3DMetal  →  Metal 3
Gioco DirectX 12       →  D3DMetal  →  Metal 3  (GPTK 3)
                                    →  Metal 4  (GPTK 4, solo Apple Silicon)
```

La scelta della versione Metal **non è pilotabile dall'utente**: la decide il D3DMetal incluso in GPTK. La CLI non deve esporre flag tipo `--metal4`, perché sarebbero fuorvianti.

### 2.2 Matrice dei requisiti per Metal 4

| Requisito | Obbligatorio per Metal 4 |
|---|---|
| GPU | Apple Silicon (niente Intel) |
| macOS | **27** |
| Xcode | 27 (per `gpucapture` / `gpudebug`) |
| GPTK | **4** (evaluation environment 4.x) |
| API del gioco | DirectX 12 |

> Nota: i giochi DirectX 11 ricadono su Metal 3 anche con GPTK 4.

### 2.3 Stato attuale dell'ambiente di sviluppo

| Componente | Valore rilevato |
|---|---|
| macOS | 26.6.2 (build 25G83), arm64 |
| GPTK installato | `/Applications/Game Porting Toolkit.app` → **GPTK 1.1, Wine 7.7** |
| Wine Homebrew | `/opt/homebrew/bin/wine64` → Wine 7.7 (GPTK 1.1) |
| winetricks | `20260125` |
| Altro | `Steam.app`, `Wine Staging.app`, `WineSpaces.app` |

**Conseguenza:** allo stato attuale **Metal 4 non è raggiungibile** (manca macOS 27 + GPTK 4). La CLI deve funzionare anche in questo scenario degradato e **riportarlo chiaramente** in `gx doctor`.

> **Nota:** l'update a **macOS 27.0.1** risulta disponibile su questa macchina → abiliterebbe GPTK 4 + Metal 4 (Apple Silicon).

> **PoC Steam (2026-10-01):** la UI di Steam funziona già ora con **Wine Staging 11.10** + shim `steamwebhelper` (vedi §11), **in modo indipendente** da GPTK/Metal. Il percorso Metal 3/4 riguarda il rendering dei *giochi*, non la UI del client.

### 2.4 Vincoli di piattaforma

- Serve **Rosetta 2** per Wine x86_64 su Apple Silicon.
- Anti-cheat kernel-level (EAC, BattlEye, Vanguard) **non** funzionano → multiplayer competitivo escluso.
- Gli **installer** Windows sono meno affidabili di una cartella di gioco già installata.
- `steamwebhelper` (CEF) va wrappato o la UI Steam risulta **nera**.

---

## 3. Principi di design

1. **Runtime discovery, non hardcoding.** Ogni percorso (wine, GPTK, prefix root) è risolto a runtime e sovrascrivibile via config/env.
2. **Prefix come unità di isolamento.** Ogni gioco/app vive in un prefix dedicato; niente stato globale condiviso.
3. **Idempotenza.** Ogni comando deve poter essere rieseguito senza rompere ciò che esiste.
4. **Trasparenza.** Ogni invocazione a wine/winetricks viene loggata; `gx` non nasconde i comandi.
5. **Fail loudly, fail diagnostics.** Errori con causa + suggerimento; `doctor` come prima linea.
6. **Zero redistribuzione di binari proprietari.** GPTK/D3DMetal scaricati dall'utente.
7. **Metal-agnostico.** La CLI descrive la capacità (`gx gpu info`), non forza la versione Metal.

---

## 4. Architettura

**Decisione (2026-10-01): core condiviso + doppio frontend.** La logica vive in una libreria Swift (`GameXCore`) riusata da due frontend: la CLI `gx` (automazione, debug, headless) e l'app SwiftUI `GameX` (uso quotidiano). Non si sceglie tra CLI e GUI: condividono il core.

```
┌──────────────────────┐        ┌──────────────────────┐
│      gx (CLI)        │        │    GameX.app (GUI)   │
│ parser · output ·    │        │ SwiftUI · dashboard  │
│ exit codes · script  │        │ · log live · libreria│
└──────────┬───────────┘        └──────────┬───────────┘
           │                               │
           └───────────────┬───────────────┘
                           ▼
                ┌─────────────────────┐
                │     GameXCore       │
                │  Runtime · Prefix   │
                │  Deps · Steam ·     │
                │  Shim · GameReg ·   │
                │  Doctor             │
                └──────────┬──────────┘
                           │
      ┌────────────────────┼─────────────────────┐
      ▼                    ▼                     ▼
  Wine/GPTK            WINEPREFIX           shim steamwebhelper
  D3DMetal             (per gioco)          + winetricks
  Rosetta 2
```

> Nota: né la CLI né la GUI renderizzano i giochi. I giochi girano nelle finestre di Wine. Entrambi i frontend sono **orchestratori**, non runtime.

### 4.1 Livelli

| Livello | Responsabilità | Dipende da |
|---|---|---|
| **Frontend CLI (`gx`)** | Parsing, dispatch, output, exit code | GameXCore |
| **Frontend GUI (`GameX`)** | SwiftUI: dashboard, libreria, log, azioni | GameXCore |
| **GameXCore** | Runtime, prefix, deps, steam, shim, registry, doctor | OS + Wine |
| **Adapter OS** | Invocazione processi, filesystem, log | macOS |
| **Dati** | Config, registry giochi, cache | filesystem |

### 4.2 Scelta del linguaggio

**Decisione: Swift** (Swift 6.x) per tutto il core e i frontend. Motivi: tipizzazione, testabilità, `Process`/`FileManager` nativi, e — decisivo — la GUI SwiftUI può condividere lo stesso core senza riscritture.

Restrizioni pratiche:
- **App Sandbox disattivata**: Wine deve avviare eseguibili arbitrari fuori sandbox → **niente Mac App Store**.
- Distribuzione: **Developer ID + notarization**, oppure avvio manuale via "Open Anyway".
- GPTK/D3DMetal e binari Valve **non** bundlabili; lo shim (MIT) sì.
- Firmare l'app con hardened runtime ma **senza library validation** (Wine carica librerie non firmate).

### 4.3 App SwiftUI `GameX` (M6, verificata 2026-10-01)

La GUI è un **secondo frontend sullo stesso `GameXCore`**: nessuna logica duplicata, nessuna chiamata alla CLI. Ogni schermata legge/azione del core:

| Sezione | Funzioni |
|---|---|
| **Dashboard** | system (chip, GPU cores, Metal), resolved runtime, `Doctor` report per check, missing components with a **per-component Install** button |
| **Boxes** | one row per box (Wine container): runtime, size, Steam status; create box, install Steam (online), repair shim, run, stop, **Run program…**, open in Finder, remove (trash), empty trash |
| **Logs** | log file list + selectable tail |

Boxes are always created with **Wine Staging** (the modern runtime; GPTK/Homebrew proved redundant on this setup — see §19.4). Homebrew Wine is the same Wine as GPTK here.

The UI is **in English**. There is no separate "Games" section: games are installed and launched from Steam itself; the `gx game` CLI commands remain for power users.

Azioni bloccanti (wineboot, build shim, winetricks) girano in `Task.detached` con stato `busy`; l'UI resta reattiva.

> **Invariante critico:** le **view non devono eseguire processi**. Lanciare un processo (`wine --version`) o leggere il filesystem in modo pesante dentro il `body` causa re-entrancy nel runloop e crash (`AG::Graph::value_set ... abort`). Tutto ciò che lancia processi (label runtime, dimensione box, stato shim) è **precalcolato in `refresh()`** e pubblicato come dati (`runtimeLabels`, `prefixSizes`, `steamBadges`); le view leggono solo dizionari.

**Build** (SwiftPM non produce bundle `.app`):

```sh
scripts/build-app.sh release   # → dist/GameX.app
open dist/GameX.app            # al primo avvio: tasto destro → Apri (non firmata)
```

Lo script impacchetta l'eseguibile, genera `Info.plist` e copia il resource bundle di `GameXCore` (necessario perché `Bundle.module` trovi lo shim dentro l'app). Firma ad-hoc best effort. Il codice dell'app è compilabile anche con i soli Command Line Tools (niente Xcode license), perché usa SDK/SwiftUI di sistema.

---

## 5. Struttura del repository

```
game-x/
├── DESIGN.md
├── README.md
├── Package.swift                 # SwiftPM: GameXCore + gx + gx-selftest
├── Sources/
│   ├── GameXCore/                # ← tutta la logica condivisa
│   │   ├── Resources/
│   │   │   └── steamwebhelper_shim.c   # shim C (risorsa bundled)
│   │   ├── Paths.swift           # risoluzione percorsi (config/env/default)
│   │   ├── Config.swift          # config.toml / env GX_*
│   │   ├── Log.swift             # logging strutturato + file
│   │   ├── ProcessRunner.swift   # spawn processo, cattura/streaming
│   │   ├── Runtime.swift         # discovery wine/GPTK/D3DMetal/Rosetta
│   │   ├── Prefix.swift          # create/list/remove/exec + metadati
│   │   ├── Deps.swift            # winetricks wrapper
│   │   ├── Steam.swift           # install(online)/repair/run/stop
│   │   ├── Shim.swift            # build/installa shim + chflags
│   │   ├── GameRegistry.swift    # registry.json
│   │   ├── GPUInfo.swift         # capacità Metal
│   │   └── Doctor.swift          # diagnostica
│   ├── gx/                       # ← frontend CLI
│   │   ├── main.swift            # dispatch
│   │   ├── Parser.swift
│   │   ├── Help.swift
│   │   └── Output.swift          # colori/exit code
│   ├── gx-selftest/              # ← test harness autonomo (no XCTest)
│   │   └── main.swift
│   └── GameX/                    # ← frontend SwiftUI (Xcode target)
│       ├── GameXApp.swift
│       ├── AppModel.swift
│       └── Views.swift           # Dashboard · Boxes · Logs (UI in inglese)
├── Tests/                        # riservato a XCTest/Swift Testing (quando Xcode è disponibile)
│   └── (vedi nota sotto)
├── Resources/                    # config di esempio / doc (lo shim è nel target)
│   └── default-config.toml
└── scripts/
    ├── build-steamwebhelper-shim.sh
    └── install.sh
```

> **Self-test senza Xcode.** Su questa macchina `xcode-select` punta al CommandLineTools, che non espone i moduli `XCTest`/`Testing`, e la licenza Xcode non è accettata → `swift test` non funziona. I test di M0 vivono quindi in `Sources/gx-selftest/main.swift` (harness autonomo, `swift run gx-selftest`). Quando l'ambiente Xcode sarà disponibile, i casi si portano 1:1 in `Tests/GameXCoreTests`.

> Il target `GameX` (GUI) non è compilabile con SwiftPM puro perché richiede bundle `.app`, `Info.plist` ed entitlements: richiede un progetto Xcode che **dipende dal package SwiftPM** `GameXCore`. Il package resta la fonte di verità.

Struttura storica di riferimento (pre-decisione core/frontend): i moduli `Runtime`, `Prefix`, `Deps`, `Steam`, `Shim`, `GameRegistry`, `Doctor` e gli adapter `ProcessRunner`/`Paths` restano invariati, solo ricollocati in `Sources/GameXCore/`.

---

## 6. Modello di configurazione

File: `~/.config/game-x/config.toml`

```toml
[runtime]
gptk_app    = "/Applications/Game Porting Toolkit.app"
wine_binary = ""              # vuoto = auto-discovery
winetricks  = "/opt/homebrew/bin/winetricks"
arch        = "win64"

[paths]
prefix_root = "~/Library/Application Support/game-x/prefixes"
games_root  = "~/Library/Application Support/game-x/games"
logs_root   = "~/Library/Logs/game-x"
cache_root  = "~/Library/Caches/game-x"

[steam]
default_prefix = "Steam"
webhelper_wrapper = "auto"    # auto | on | off

[launch]
esync = true
msync = false
```

Precedenza (dalla più alta): **flag CLI → variabili `GX_*` → config.toml → default**.

Variabili ambiente supportate: `GX_PREFIX_ROOT`, `GX_GPTK_APP`, `GX_WINE`, `GX_LOG_LEVEL`.

---

## 7. Superficie dei comandi

```
gx <command> [subcommand] [options]

AMBIENTE
  gx doctor                    Diagnostica completa dell'ambiente
  gx info                      Riepilogo config + runtime risolti
  gx gpu info                  Capacità GPU/Metal e verdetto Metal 4
  gx runtime list              Wine/GPTK disponibili
  gx runtime use <path>        Seleziona un runtime

PREFIX
  gx prefix create <name>      Crea un prefix Wine
  gx prefix list               Elenca i prefix
  gx prefix remove <name>      Rimuove un prefix (con conferma)
  gx prefix exec <name> -- <cmd>
  gx prefix open <name>        Apre la C: in Finder

DIPENDENZE
  gx deps list                 Verb winetricks noti/consigliati
  gx deps install <name> <verb...>
  gx deps remove  <name> <verb...>

STEAM
  gx steam install [--prefix Steam]
  gx steam repair  [--prefix Steam]   # reinstalla wrapper webhelper
  gx steam run     [--prefix Steam]
  gx steam stop    [--prefix Steam]

GIOCHI
  gx game add <name> --prefix <p> --exe <path>
  gx game list
  gx game launch <name>
  gx game launch --prefix <p> --appid <id>   # via Steam

LOG
  gx log tail <name|--last>
  gx log path [name]
```

### 7.1 Exit code

| Code | Significato |
|---|---|
| 0 | successo |
| 1 | errore generico |
| 2 | uso errato / argomenti invalidi |
| 3 | runtime non trovato |
| 4 | prefix inesistente |
| 5 | dipendenza/steam non installata |
| 6 | comando Wine fallito (propaga il code) |

---

## 8. Runtime resolution

Algoritmo di `Runtime.resolve()`:

1. Se `--runtime` o `GX_WINE` presenti → usali, verifica esistenza.
2. Cerca wine dentro `gptk_app` → `Contents/Resources/wine/bin/wine64`.
3. Fallback a `wine64` nel `PATH`.
4. Fallback a un runtime Wine di sistema (se presente) → `Contents/Resources/wine/bin/wine64`.
5. Determina la versione (`wine --version`) e prova a mappare GPTK↔Wine.
6. Determina presenza **D3DMetal** cercando le librerie Metal lato host / `d3d12.dll` nel runtime.
7. Verifica **Rosetta 2** (`/usr/libexec/rosetta/oahd` o `arch -x86_64 true`).
8. Ritorna un oggetto `ResolvedRuntime { winePath, version, gptkVersion, hasD3DMetal, rosettaOK }`.

Tutto ciò alimenta anche `gx doctor` e `gx gpu info`.

---

## 9. Gestione prefix

> Stato: **implementato e verificato (M1, 2026-10-01)**.

Un prefix è: directory + file di metadati. Il prefix **ricorda il proprio runtime** in modo che `exec` usi sempre il Wine con cui è stato creato, indipendentemente da quale sia il default globale.

```
<prefix_root>/<name>/
├── .gx.meta.json         # nome, kind, runtime usato (kind+versione+binario), date
├── drive_c/
├── dosdevices/
└── ...
```

`.gx.meta.json`:

```json
{
  "name": "SteamStaging",
  "kind": "prefix",
  "runtimeKind": "Wine Staging",
  "runtimeVersion": "wine-11.10 (Staging)",
  "wineBinary": "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine",
  "createdAt": "2026-10-01T08:42:14Z"
}
```

Operazioni (CLI M1):

| Comando | Comportamento |
|---|---|
| `gx prefix list [--trash]` | nome, runtime, dimensione, `+Steam`; opz. cestino interno |
| `gx prefix create <name> [--runtime ...] [--force]` | valida nome, crea, `wineboot -u`, scrive meta |
| `gx prefix info <name>` | percorso, runtime, dimensione, stato Steam/shim |
| `gx prefix exec <name> [--runtime ...] -- <cmd...>` | usa il runtime del prefix; propaga exit code e output |
| `gx prefix kill <name>` | `wineserver -k` |
| `gx prefix remove <name> --yes [--purge]` | **recuperabile**: sposta in `<prefix_root>/.trash/`; `--purge` elimina subito |
| `gx prefix purge <entry> \| --all` | svuota il cestino interno |
| `gx prefix open <name>` | apre `drive_c` nel Finder |

Regole:

- **Nome validato** (`[A-Za-z0-9._-]+`, niente slash/`..`).
- **Mai rimozione silenziosa di save**: la cancellazione richiede `--yes` e di default è reversibile (cestino interno).
- **Runtime per-prefix**: `Runtime.forPrefix()` legge i metadati; override con `--runtime`.
- **Selezione runtime**: `--runtime gptk|staging|homebrew|<path-esplicito>`.

Override standard applicati al lancio (dipende dal runtime):

```
WINEDLLOVERRIDES="d3d12,d3d11,dxgi=n,b"   # quando il runtime fornisce D3DMetal
WINEESYNC / WINEMSYNC                      # da config
```

> I valori esatti vanno validati per versione GPTK in una matrice di test (§14).

---

## 10. Dipendenze (winetricks)

> Stato: **implementato e verificato (M2, 2026-10-01)**.

`gx deps` invoca winetricks **contro il Wine del prefix** (dai metadati), non contro quello di default:

```sh
WINEPREFIX=<prefix> WINE=<prefix-runtime> winetricks -q <verb...>
```

Comandi:

| Comando | Comportamento |
|---|---|
| `gx deps list` | verb noti con nota di rischio |
| `gx deps status <prefix>` | verb effettivamente installati |
| `gx deps install <prefix> <verb...> [--dry-run]` | installa, saltando quelli già presenti |
| `gx deps remove <prefix> <verb...> [--dry-run]` | `winetricks --uninstall` |

Dettagli implementativi:

- **Rilevamento installati**: `winetricks list-installed`, non i file sentinella. Wine fornisce molti DLL builtin (es. `msvcp140.dll`) che darebbero **falsi positivi**; la query a winetricks è affidabile.
- **Idempotenza**: `install` filtra i verb già installati e segnala `già installati: ...` → `nulla da fare`.
- **Validazione**: verb sconosciuti rifiutati; rischio `unsupported` bloccato.
- **Streaming**: l'output di winetricks è mostrato in tempo reale (stdout+stderr uniti) e telegrafato su `logs_root/deps/<prefix>-<timestamp>.log`.
- **`--dry-run`**: stampa WINE/WINEPREFIX/comando senza eseguire.
- Verb noti: `corefonts`, `vcrun2022`, `vcrun2019`, `d3dcompiler_47`, `gdiplus` (safe); `dotnet6`, `dotnet48` (delicate).

---

## 11. Integrazione Steam

> Stato: **verificato end-to-end il 2026-10-01** (vedi §11.5). Questa sezione è normativa.

### 11.1 Problema (root cause)

La UI di Steam è **CEF** (`steamwebhelper.exe`), **non** `steam.exe`. Su macOS/Wine la finestra di Steam si presenta **completamente nera** anche se il processo è vivo e la finestra ha il titolo corretto.

Causa: **Wine bug #60263** — `winemac.drv` non implementa le *cross-process child window Metal swapchain*. Il GPU process di CEF chiede una Metal view per una **child window il cui root vive nel browser process**; `get_win_data()` ritorna `NULL` per costruzione → il GPU process muore → nero. È **indipendente dal backend grafico** (anche forzando SwiftShader resta nera).

Sintomi caratteristici nei log CEF (`Steam/logs/cef_log.txt`, `webhelper_gpu.txt`):

```
ERROR angle_platform_impl.cc Renderer11.cpp ... Error querying driver version from DXGI Adapter
ERROR gl_display.cc EGL Driver message (Error) eglCreateContext: Requested GLES
      version (3.0) is greater than max supported (2, 0)
```

Corollario importante: **il flag va iniettato in `steamwebhelper.exe`, non in `steam.exe`.**

### 11.2 Fix (obbligatoria)

Shim di `steamwebhelper.exe` che fonde renderer/GPU/utility nel browser process, evitando la swapchain cross-process:

```
--no-sandbox --disable-gpu --single-process
```

- **`--single-process` è la chiave.** `--in-process-gpu` da solo **non** basta: lascia renderer/utility come processi separati, e il problema cross-process resta.
- Serve anche `--disable-gpu` (il percorso GPU di CEF non è comunque componibile sotto Wine).
- Sorgente: `Resources/steamwebhelper_shim.c`, compilato con `mingw-w64` (64-bit per `cef.win64`/`cef.win7x64`, 32-bit per `cef.win7`).
- **Niente blocco `uchg`**: applicare `chflags uchg` allo shim impedisce a Steam di aggiornarsi (`BCommitUpdatedFiles: failed to rename ... error 5` → update fallisce, revert, poi `Fatal Error: Could not load module 'bin\FileSystem_stdio.dll'`). Lo shim non viene bloccato: viene **riconosciuto tramite un marker** nel binario e **reinstallato automaticamente** quando Steam lo sovrascrive.
- **Auto-riparazione al lancio**: `Steam.run` monitora i primi ~3 minuti; se il webhelper torna "reale" (update applicato), ferma Steam, reinstalla lo shim e rilancia una volta → la UI non resta nera dopo un aggiornamento.

Sequenza di install:

```sh
per ogni dir bin/cef/<arch>:
  se steamwebhelper.exe è il webhelper reale: salvalo come steamwebhelper_real.exe
  copia lo shim (x64 / x86) come steamwebhelper.exe
```

`gx steam install` / `gx steam repair` eseguono questa sequenza e registrano nei metadati l'hash dello shim installato, per accorgersi di un overwrite.

### 11.3 Flag di avvio Steam

```
Steam.exe -no-cef-sandbox -forcedesktopscaling 1 -noverifyfiles
```

- `-noverifyfiles` impedisce al bootstrapper di ripristinare `steamwebhelper.exe`.
- `-no-cef-sandbox` e `-forcedesktopscaling 1` completano la compatibilità UI.
- Gioco: `wine steam.exe -applaunch <appid>` con Steam già avviato.

### 11.4 Requisito di runtime

La fix funziona **solo con un Wine moderno**. Verificato:

| Runtime | Versione | Esito |
|---|---|---|
| GPTK 1.1 | Wine 7.7 | ❌ UI nera (runtime troppo vecchio per Steam 2026) |
| Wine Staging (Gcenx) | Wine 11.10 | ✅ UI renderizzata con lo shim |

Implicazioni per `Runtime.resolve()` (§8):
- Se il runtime risolto è **Wine < 8**, `gx steam` deve fallire con errore esplicito (exit 3) e suggerire un runtime moderno.
- `gx doctor` verifica `wine --version` e avverte se il runtime è troppo vecchio per Steam.
- Il runtime **raccomandato per la UI Steam** è Wine Staging recente, **indipendentemente** da GPTK/D3DMetal usato per i giochi (i due aspetti sono separabili).

Nota operativa: il percorso di installazione è **online** e non richiede altri prefix (vedi §11.6). Rimossa la vecchia strategia di copia da un prefix esistente, basata su un presunto crash del bootstrapper che la verifica ha smentito.

### 11.5 Esito PoC (2026-10-01)

Verificato su macOS 26.6.2 / Apple Silicon con Wine Staging 11.10:

- Senza fix: finestra **nera** (byte-identica a nero anche via ScreenCaptureKit, quindi non artefatto di cattura).
- Con lo shim `--no-sandbox --disable-gpu --single-process`: la schermata di login renderizza correttamente (campi account/password, pulsante Sign in, QR code).

Artefatti verificati:
- `Resources/steamwebhelper_shim.c` (sorgente shim).
- Diagnostica finestre/screenshot: `CGWindowList` + ScreenCaptureKit (la cattura di finestre occluse GPU-composited con `screencapture -l` può dare falsi negativi neri).

Riferimenti: WineHQ bug 60263; progetti `notpop/steam-on-m1-wine` e `wisnuub/Steam-Win-Silicon` (fonte della combinazione `--disable-gpu --single-process`).

### 11.6 Implementazione CLI (M3, verificata 2026-10-01)

Comandi:

| Comando | Comportamento |
|---|---|
| `gx steam status [prefix]` | stato Steam + shim installato/protetto |
| `gx steam install [prefix] [--setup <path>] [--runtime ...] [--force] [--no-update]` | installa Steam **online** e applica lo shim |
| `gx steam repair [prefix] [--runtime ...]` | ricompila/reinstalla lo shim dopo un auto-update |
| `gx steam run [prefix]` | avvia il client con i flag corretti |
| `gx steam launch <prefix> <appid>` | `-applaunch` |
| `gx steam stop [prefix]` | `wineserver -k` |

Dettagli:

- **Shim come risorsa bundled**: `Sources/GameXCore/Resources/steamwebhelper_shim.c` è incluso nel target SwiftPM; `Shim.build()` lo compila con **mingw-w64** su `cacheRoot/shims/` (cache su mtime). `brew install mingw-w64` è l'unico requisito a runtime per `repair`.
- **Shim come risorsa bundled**: `Sources/GameXCore/Resources/steamwebhelper_shim.c` è incluso nel target SwiftPM; `Shim.build()` lo compila con **mingw-w64** su `cacheRoot/shims/` (cache su mtime). `brew install mingw-w64` è l'unico requisito a runtime per `repair`.
- **Marker di riconoscimento**: il binario contiene la stringa `game-x-steamwebhelper-shim-v2`; `Shim.isInstalled` la cerca per distinguere il nostro shim dal webhelper reale. Niente `uchg`; un eventuale lock lasciato dalle versioni vecchie viene rimosso (`Shim.clearLocks`).
- **Installazione Steam (online, verificata)**:
  1. scarica (o usa) `SteamSetup.exe` da `cdn.fastly.steamstatic.com` ed esegue `/S` → bootstrapper;
  2. avvia Steam per il **primo download del client** (~1.5 GB) e attende che `bin/cef/cef.win64/steamwebhelper.exe` esista e sia stabile (niente euristica sul testo del log: l'installer scrive già "Update complete");
  3. **ferma** Steam e applica lo shim (l'update lo sovrascriverebbe se applicato prima).
  Tempo misurato: ~2m30s. **Non serve nessun altro prefix.**
  - Nota storica errata: si credeva che `SteamSetup.exe`/l'update crashasse su Wine 11 (page fault). Verificato: **zero page fault** con Wine Staging 11.10; il percorso online è affidabile. Gli errori `virtual:try_map_free_area mmap()` sono rumore non fatale.
- **Requisito runtime**: `install`/`run` richiedono Wine ≥ 8; `runtimeForSteam` preferisce il runtime registrato nel prefix se moderno, altrimenti `resolveForSteam`.
- **Idempotenza**: se Steam è già presente e `--force` non è dato, `install` si limita a verificare/ripristinare lo shim; `repair` è sempre idempotente.
- Aggiorna `.gx.meta.json` con `kind = steam`.

---

## 12. Registro giochi

> Stato: **implementato e verificato (M4, 2026-10-01)**.

File: `games_root/registry.json`

```json
{
  "version": 1,
  "games": [
    {
      "name": "elden-ring",
      "prefix": "Steam",
      "appid": 1245620,
      "exe": null,
      "args": [],
      "env": {},
      "notes": "usa applaunch; ESYNC off per stabilità"
    }
  ]
}
```

- Un gioco è identificato da **prefix + (exe | appid)**.
- Supporto a override `env` per workaround game-specific (vincono sull'ambiente di base).

Comandi:

| Comando | Comportamento |
|---|---|
| `gx game list` | elenca i giochi registrati |
| `gx game add <name> --prefix <p> [--appid <id> \| --exe <path>] [--arg <a>]* [--env K=V]* [--notes <t>]` | registra/aggiorna un gioco |
| `gx game show <name>` | dettagli + **piano di lancio** calcolato |
| `gx game remove <name>` | rimuove dal registro |
| `gx game launch <name> [--runtime ...] [--dry-run]` | lancia |

Dettagli implementativi:

- **Percorso appid**: `Steam.exe -applaunch <id>` nel prefix (richiede Steam installato).
- **Percorso exe**: `wine <exe> <args>` con `env` per-gioco.
- **`GameLauncher.plan()`**: calcola il comando senza eseguirlo (usato da `show`/`--dry-run`).
- **Runtime del prefix**: come per prefix/deps/steam, si usa `Runtime.forPrefix` con override `--runtime`.
- `upsert` mantiene il registro ordinato per nome; `remove` ritorna `false` se assente.

---

## 13. Diagnostica — `gx doctor`

> Stato: **implementato e verificato (M5, 2026-10-01)**. Supporta `--json`.

Controlli (con esito OK / WARN / FAIL e rimedio):

1. macOS/architettura/chip/core GPU (arm64?).
2. Rosetta 2 presente.
3. Runtime wine trovato + versione.
4. GPTK presente + D3DMetal.
5. `winetricks`, `mingw-w64`, `cabextract` (tool esterni con versione).
6. Prefix presenti; per ogni prefix con Steam, stato shim (ok / da riparare).
7. Spazio disco libero.
8. Verdetto **Metal 4** (macOS 27 + GPTK 4 + Apple Silicon).

Esempio output:

```
gx doctor
  [ OK ] macOS 26.6.2 (arm64) — Apple M4
  [ OK ] Rosetta 2
  [ OK ] Runtime: GPTK — wine-7.7 (Game Porting Toolkit 1.1)
  [ OK ] D3DMetal presente
  [WARN] Runtime troppo vecchio per la UI Steam → usa Wine Staging
  [ OK ] winetricks / mingw-w64 / cabextract
  [ OK ] 2 prefix, 2 con Steam
  [WARN] Steam in 'Steam': shim da riparare → gx steam repair Steam
  [ OK ] Spazio libero: 197.2 GB
  [WARN] Metal 4 NON disponibile: serve macOS 27, serve GPTK 4

  10 ok, 3 warn, 0 fail
```

- Exit code: `1` se esiste almeno un `FAIL`, altrimenti `0`.
- `--json` emette `{ "checks": [ { status, title, detail?, remedy? } ] }` per automazione/GUI (M6).
- **`gx doctor --fix`**: installa automaticamente i componenti mancanti (stessa logica di `gx setup`), poi ripete la diagnostica. In GUI: bottone *Install* per singolo componente mancante + *Install missing* per tutti.
- `gx gpu info [--json]` e `gx info [--json]` completano il quadro macchina/configurazione.
- **Logging**: `Log` separa soglia file e soglia console; ogni invocazione è in `~/Library/Logs/game-x/gx.log`. `gx log path|list|tail [name] [--lines N]`. `-v/--verbose/--debug` alza il livello; `--quiet` abbassa.

---

## 14. Roadmap Metal 4

Poiché Metal 4 dipende dall'ambiente (non dalla CLI), il lavoro si divide in:

**Ora (macOS 26 / GPTK v1–3):**
- CLI completa per prefix/deps/steam/gioco su Metal 3.
- Discovery D3DMetal e rilevazione capacità.

**Quando disponibile macOS 27 + GPTK 4:**
- Validare override dll per D3D12 → Metal 4.
- Aggiungere `gx gpu info` con verdetto Metal 4 reale.
- Integrare, opzionale, `gpucapture`/`gpudebug` per il debug (solo se Xcode 27 presente).
- Matrice di test per gioco (D3D11 = Metal 3, D3D12 = Metal 4).

---

## 15. Aspetti legali / etici

> Questa sezione distingue esplicitamente due piani che spesso si confondono: **legge** (copyright, DRM) e **contratto** (Steam Subscriber Agreement / Steam Client License Agreement). Non è consulenza legale; per uso commerciale rivolgersi a un avvocato.

### 15.1 Piano legale (copyright / DRM) — nessun illecito

Lo shim `steamwebhelper_shim.c` messo in `Resources/`:

- è **codice originale** del progetto, non contiene né copia codice Valve;
- **non fa reverse engineering** né decompilazione di binari Valve (solo passaggio di flag CLI);
- **non aggira misure di protezione** (DRM, login, anti-cheat) → niente elusione ex DMCA §1201 o art. 6 dir. 2009/24/CE;
- **non ridistribuisce binari Valve** (rinomina localmente il file esistente, non ne modifica i bit).

**Conclusione:** scrivere, possedere e distribuire lo shim è lecito. Interoperabilità, nessuna violazione di copyright.

### 15.2 Piano contrattuale (SSA) — rischio di violazione

La SSA (rev. 20 apr. 2026) contiene clausole che qualificano l'operazione come possibile **violazione contrattuale** (non penale) da parte dell'utente:

| Fonte | Clausola (sintesi) | Rilevanza |
|---|---|---|
| SSA §4.B | *"you will not **tamper with the execution of Steam** [...] unless otherwise authorized by Valve"* | massima: sostituire `steamwebhelper.exe` altera l'esecuzione di Steam |
| SSA §2.G | divieto di *"modify [...] the Content and Services or any software accessed via Steam without prior consent, in writing, of Valve"* | modifica di un componente installato |
| Steam Client License Agmt | *"you may not [...] modify [...] the Program"* | modifica dell'installazione |

**Conseguenza concreta:** non multa/carcere, ma — sulla carta — Valve può **limitare o terminare l'account** (SSA §9.C), senza rimborso.

### 15.3 Fattori che riducono il rischio pratico

- Valve distribuisce **Proton** (Wine) ufficialmente per Linux → non ostile per principio all'interoperabilità.
- Lo shim **non abilita** cheating, pirateria, condivisione account o abusi del Marketplace: lo spirito della clausola anti-tampering non è toccato.
- Uso **personale e non commerciale**, che è la licenza concessa (SSA §2.A).
- Tecnica usata da anni da progetti pubblici equivalenti (Whisky, Vineport, notpop, RipperMoonKit, Xipzer): indizio di tolleranza di fatto, non difesa legale.
- L'utente è in UE/Italia: per i consumatori UE il contratto è regolato dalla legge del paese di residenza.

### 15.4 Regole per il progetto (vincolanti)

- **Non bundlare mai** binari Valve (Steam, `steamwebhelper.exe`, DLL) né **Apple D3DMetal/GPTK**. Ogni utente scarica da sé: la EULA Apple vieta la ridistribuzione di D3DMetal.
- Distribuire solo **codice proprio** (shim MIT + CLI).
- Predisporre **disclaimer** in README e al primo avvio: strumento non ufficiale, non affiliato a Valve, usato a proprio rischio contrattuale.
- Nessun bypass di DRM/anti-cheat: la CLI **rifiuta** di supportare meccanismi di elusione.
- Non istruire l'utente a violare la SSA come se fosse privo di conseguenze: documentare il rischio.

### 15.5 Marchi

Steam è trademark di Valve. GPTK, D3DMetal, Metal sono di Apple. Nessuna affiliazione o endorsement: va dichiarato esplicitamente.

---

## 16. Testing

- **Unit**: parser, runtime resolver (con filesystem mock), composition dei comandi Wine.
- **Integration (macOS)**: creazione prefix reale, `wine --version` via wrapper, install/repair webhelper (dry-run dove possibile).
- **Contract**: snapshot dei comandi generati (garantire che i flag non cambino silenziosamente tra versioni).
- **Smoke**: `gx doctor` su ambiente pulito vs configurato.

---

## 17. Milestone

| # | Milestone | Criterio di done |
|---|---|---|
| M0 | Scheletro core + CLI + config + runtime discovery | `gx info` e `gx doctor` funzionanti |
| M1 | Gestione prefix | create/list/info/exec/kill/remove/purge/open — **completato 2026-10-01** |
| M2 | Deps via winetricks | install vcrun2022 in un prefix reale — **completato 2026-10-01** |
| M3 | Steam install/repair + shim `steamwebhelper` | Steam UI visibile (non nera) — **PoC 2026-10-01; install/repair in core 2026-10-01** |
| M4 | Game registry + launch | lancio exe e `-applaunch` — **completato 2026-10-01** |
| M5 | Logging + doctor avanzato + `gpu info` | diagnostica completa — **completato 2026-10-01** |
| M6 | **App SwiftUI `GameX` sul core** | dashboard doctor, libreria giochi, log live, azioni prefix/steam — **completato 2026-10-01** |
| M7 | Metal 4 (condizionato a macOS 27 + GPTK 4) | D3D12 → Metal 4 validato |
| M6b | GPTK multi-versione + install automatico + icona | `gx setup`, mappatura macOS→GPTK, `GameX.app` con icona — **completato 2026-10-01** |

---

## 18. Questioni aperte

1. Linguaggio definitivo: Swift (raccomandato) vs Bash.
2. Set esatto di `WINEDLLOVERRIDES` per GPTK 1.1 / 3 / 4 (va testato).
3. Fonte del wrapper webhelper: mantenere il C nel repo o generarlo.
4. Supporto a runtime alternativi (Wine Staging, Homebrew) come backend selezionabili.
5. Gestione save/backup: dentro scope o modulo separato?
6. Naming definitivo della CLI (`gx` vs `game-x` vs altro).
7. Firma/notarizzazione del binario per distribuzione.

---

## 19. GPTK multi-versione e install automatico (M6b)

> Stato: **implementato e verificato (2026-10-01)**.

### 19.1 Rilevamento e mappatura delle versioni GPTK

`GPTK.discover()` cerca i bundle `*Porting Toolkit*.app` in `/Applications` e `/Users/Shared`, legge `CFBundleShortVersionString` e la versione del Wine interno (`wine --version`). Mappatura macOS → GPTK raccomandato:

| macOS | GPTK raccomandato |
|---|---|
| ≤ 12 | 1 |
| 13–14 | 2 |
| 15–26 | 3 |
| 27+ | 4 |

`GPTK.verdict()` produce una riga di doctor: se il GPTK installato è più vecchio del raccomandato → WARN con hint; altrimenti OK. Questo risponde a “compatibile anche con versioni precedenti”: il codice non assume GPTK 4, seleziona e valuta ciò che trova.

### 19.2 Install automatico — `gx setup`

Trasforma la diagnostica in azione. Componenti gestiti (`Setup.status`):

| id | tipo | come |
|---|---|---|
| `rosetta` | command | `softwareupdate --install-rosetta --agree-to-license` |
| `winetricks` | formula | `brew install winetricks` |
| `mingw` | formula | `brew install mingw-w64` |
| `cabextract` | formula | `brew install cabextract` |
| `wine-staging` | cask | `brew install --cask wine@staging` |
| `gptk` | cask/manual | `brew install --cask game-porting-toolkit` se raccomandato ≤ 3; **GPTK 4 è manuale** (Apple ID) |

```sh
gx setup --list          # stato dei componenti
gx setup --dry-run       # cosa installerebbe
gx setup                 # installa i mancanti
gx setup --only wine-staging
```

- Output in streaming + log in `logs_root/setup/<id>-<timestamp>.log`.
- In GUI: il Dashboard ha la sezione **Componenti** con il bottone **Installa mancanti** (stessa logica).
- Vincolo legale (§15): GPTK/D3DMetal non vengono ridistribuiti; `gx setup` al massimo invoca Homebrew, oppure indica il link Apple.

### 19.3 Icona applicazione

`scripts/make-icon.swift` genera (CoreGraphics) uno **squircle** con gradiente; se `Resources/Logo.png` esiste, ci centra il logo neon con dissolvenza radiale, altrimenti usa un gamepad vettoriale. Output: `Resources/AppIcon.icns` + `AppIcon-512.png`. `scripts/build-app.sh` la copia nel bundle e imposta `CFBundleIconFile`.

Pipeline per il logo dal mockup fornito:
1. `scripts/crop-image.swift <img> <x> <y> <w> <h> <out>` — ritaglia la regione del logo;
2. `scripts/key-logo.swift <in> <out> [satMin] [valMin]` — **chiave per saturazione+luminosità**: tiene le linee neon brillanti, rende trasparenti gamepad e sfondo (l'JPEG non ha alpha, quindi viene creato un bitmap RGBA);
3. il risultato va in `Resources/Logo.png` e viene rigenerata l'icona con `make-icon.swift`.

---

### 19.4 Runtime choice: solo Wine Staging

Verifica sul campo: **Homebrew Wine == GPTK** (entrambi `wine-7.7 (Game Porting Toolkit 1.1)`, stessa cask), quindi la scelta "Homebrew" era ridondante. **GPTK** (Wine 7.7 + D3DMetal) non apre la UI di Steam (serve Wine ≥ 8) e il suo D3DMetal **non** viene usato automaticamente: i giochi lanciati da Steam girano nel Wine della box di Steam (Wine Staging).

Conclusione: le box si creano **sempre con Wine Staging**; il picker è stato rimosso dalla GUI. `--runtime gptk|<path>` resta disponibile da CLI per usi avanzati/futuri (Metal 4 con GPTK 4 + macOS 27).

---

## Appendice A — Comandi Wine di riferimento

```sh
# Runtime GPTK
WINE="/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"

# Creare prefix
WINEPREFIX="$HOME/.../prefixes/Steam" "$WINE" wineboot -u

# winetricks contro il prefix
WINEPREFIX="$HOME/.../prefixes/Steam" WINE="$WINE" winetricks -q vcrun2022

# Lancio gioco via Steam
WINEPREFIX="$HOME/.../prefixes/Steam" "$WINE" \
  "drive_c/Program Files (x86)/Steam/steam.exe" -applaunch 1245620
```

## Appendice B — Glossario

| Termine | Significato |
|---|---|
| **GPTK** | Apple Game Porting Toolkit — ambiente di valutazione + tool |
| **D3DMetal** | layer DirectX → Metal incluso in GPTK |
| **Metal 4** | API Metal di nuova generazione, Apple Silicon + macOS 27 |
| **prefix** | ambiente Windows isolato di Wine (`WINEPREFIX`) |
| **verb** | unità di installazione di winetricks (es. `vcrun2022`) |
| **webhelper** | processo CEF della UI di Steam |
