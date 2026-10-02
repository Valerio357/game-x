# Game-X Wine + DXMT runtime

> DirectX 10/11 → Metal su Apple Silicon, con **Steam moderno funzionante**.
> Stato: **verificato end-to-end** (Steam UI completa + login + giochi D3D11) il 2026-10-01 su M4 / macOS 26.6.

## Perché serve

Su Apple Silicon esistono due strade per DirectX:

| Soluzione | Stato | Perché non basta |
|---|---|---|
| **GPTK / D3DMetal** (Apple) | ottimo, ma **Wine 7.7** | Steam 2026 (CEF) non gira su Wine 7.7 → niente DRM Steam → niente giochi |
| **DXMT** (open source) | ottimo su Wine ≥ 8 | richiede un Wine **patchato e compilato**: upstream non espone i simboli che DXMT usa |
| Wine Staging (Gcenx) | Steam OK | non può ospitare DXMT (manca `winemetal` nel loader di ntdll) |

La soluzione è un **Wine nostro**, moderno (11.10) e con le patch che DXMT richiede:
così **Steam** (che richiede Wine ≥ 8) e i **giochi D3D11 → Metal** convivono nello stesso
`wineserver` — indispensabile perché il DRM SteamStub verifica il processo Steam.

## Cosa contiene il runtime

```
<runtime>/wine/                          Wine 11.10 x86_64 (con patch CW HACK 22435 + winemetal)
  bin/wine  bin/wineserver
  lib/wine/{x86_64-windows,x86_64-unix,i386-windows}
  share/wine/{fonts,mono/wine-mono-11.1.0-x86.msi}
<runtime>/renderers/dxmt/wine/           DXMT 0.80
  x86_64-windows/{d3d11,d3d10core,dxgi,winemetal}.dll
  x86_64-unix/{winemetal.so,ntdll.so→,winemac.so→}
<runtime>/x64deps/*.dylib                freetype, gnutls, MoltenVK (x86_64)
<runtime>/manifest.json                  versioni + provenienza
```

Tutto è **dentro** la cartella: si copia su un'altra macchina e funziona
(le dylib sono riscritte con `@loader_path`, quindi il runtime è **rilocabile**).

## Le 3 patch indispensabili (in `Patches/`)

| Patch | Cosa fa | Perché serve |
|---|---|---|
| `0013-ntdll-CW-HACK-22435` | `WINEDLLPATH_PREPEND` nel loader | permette a DXMT di essere servito come *builtin* senza toccare l'installazione di Wine |
| `0014-winemac.drv-CW-HACK-22435` | esporta `macdrv_functions` (24 entry) da `winemac.drv` | è l'API che DXMT usa per creare la NSView/Metal layer |
| `0015-winemetal-new-stub` | registra il modulo `winemetal` in ntdll | senza, Wine risponde `c0000135` (modulo non trovato) |

Sono le patch pubbliche di CodeWeavers (CW HACK 22435), riprese da MacPorts.

## Ambiente di lancio (lo imposta `gx`, mai l'utente)

```
WINEDLLPATH_PREPEND=<runtime>/renderers/dxmt/wine
WINEDLLOVERRIDES=d3d11,d3d10core,dxgi,winemetal=b   (+ mshtml= / mscoree,mshtml=)
DYLD_LIBRARY_PATH=<runtime>/x64deps                 (Wine fa dlopen con SONAME **nudo**)
DXMT_LOG_LEVEL=warn
```

Inoltre `gx` crea i symlink `ntdll.so`/`winemac.so` accanto a `winemetal.so`
(`winemetal.so` ha `LC_RPATH=@loader_path/`).

## wine-mono: non è un dettaglio

Senza **wine-mono** il browser CEF di Steam (`steamwebhelper`) **non viene creato**
(nei log si ferma a `CreateBrowser`… `WasHidden` con finestra 0×0). Con mono 11.1.0
installato il browser nasce e la UI si disegna. `gx` lo installa automaticamente
(`gx runtime mono`, oppure al primo `gx steam run`).

## I flag CEF dello shim (misurati, non ipotizzati)

Lo shim `steamwebhelper.exe` (in `Sources/GameXCore/Resources/`) inietta
`--no-sandbox --disable-gpu --single-process`. Misure sul nostro Wine:

| Flag | Esito |
|---|---|
| `--disable-gpu --single-process` | ✅ **UI completa** — 0 errori GPU, finestra disegnata |
| `--disable-gpu` (senza `--single-process`) | UI viva (JS/login) ma **finestra nera**: il present cross-process dei frame non arriva alla NSWindow |
| `+ --in-process-gpu` | ❌ ANGLE chiede Vulkan ≥ 1.1 e fallisce in loop (`gl_factory_win.cc NOTREACHED`) |
| `+ --in-process-gpu --use-angle=vulkan` | ❌ blocco all'avvio (winevulkan su thread non-main) |

Nota: serve **Vulkan/MoltenVK** nel build (ANGLE lo usa), e DXMT **presenta davvero**
(verificato con `harness/d3dvis.c`: clear R/G/B/bianco catturato a schermo).

## Cache shader, warm-up e controller (misurato il 2026-10-01)

**Cache shader.** DXMT compila le pipeline con un **LLVM incorporato** in `winemetal.so` (30 MB) →
la prima volta che una scena appare costa **decine/centinaia di ms per shader** (stallo di 1-3 minuti,
300% di CPU: *non* è un blocco). La cache è attivata da `gx`:

```
DXMT_SHADER_CACHE=1
export DXMT_SHADER_CACHE_PATH=<runtime>/cache/dxmt     # SQLite shaders_<ver>.db (+ wal)
```

Su Linux/Proton la stessa cosa è quasi invisibile perché (a) DXVK compila con un compilatore
scritto a mano (ms), (b) il driver NVIDIA tiene una pipeline-cache su disco e (c) **Valve
precompila e scarica** gli shader. Per Metal non esiste un pre-caching di Valve e DXMT non ha
un'opzione di compilazione anticipata → l'unica mitigazione è il **warm-up**.

**Warm-up** (`gx steam warmup <box> <appid>` / automatico in `gx steam launch`): avvia il gioco,
monitora la cache ogni 5 s e chiude quando è stabile da 30 s. Il gioco viene segnato come
“riscaldato” (`.warmed-<appid>`): le volte successive parte subito.

**Controller.** Su macOS Wine vede i gamepad **solo con SDL2 compilato dentro `winebus`**
(senza: 0 dispositivi HID ✗). Verificato: senza SDL2 → 0 pad; con SDL2 → `pad 0/1 CONNESSO` +
2 HID (045e:0b12 / 045e:0b13). Inoltre:

- **Steam Input deve restare ABILITATO**: è l'unica configurazione in cui il pad arriva al gioco.
  `gx steam input <box>` forza `UseSteamControllerConfig "2"` in
  `userdata/<id>/config/localconfig.vdf` (con backup `.gamex-bak`, validazione delle graffe e
  rifiuto se Steam è in esecuzione).
- ⚠️ `winebus.so` fa `dlopen("libSDL2.dylib")` con **SONAME nudo** → serve
  `DYLD_LIBRARY_PATH=<runtime>/x64deps` (altrimenti sembra “0 controller” anche col build SDL2).
- ⚠️ I symlink `ntdll.so`/`winemac.so` accanto a `winemetal.so` devono risolvere **allo stesso
  file** che Wine carica da `lib/wine/x86_64-unix/` — se differiscono, dyld carica due
  `winemac.so` → `objc: Class WineApplication is implemented in both …` → crash del gioco.

## GPTK 4 / D3DMetal (2026-10-01)

Il DMG `Evaluation_environment_for_Windows_games_4.0_beta_1.dmg` contiene **solo**
`redist/lib/external/{D3DMetal.framework, libd3dshared.dylib}` +
`redist/lib/wine/{x86_64-windows,x86_64-unix}/{d3d10,d3d11,d3d12,dxgi,…}`: **nessun Wine**, va
copiato in un contenitore Wine esistente (Wine 11 CodeWeavers). Richiede **macOS 27** (dichiarato da Apple).
In GPTK 4 `D3DMetal` compila gli shader in **due fasi** (transpiler veloce + ottimizzatore in
background) → è il fix degli stalli che paghiamo con DXMT.

Prova diretta (macOS 27.0.1): i thunk 4.0 caricati nel **nostro** Wine 11.10 falliscono la init
(`d3d11.dll … c0000142`) perché D3DMetal 4.0 richiede l'API *client surface* nuova di Wine 11
(CodeWeavers) (`macdrv_set_view_d3dmetal_client_surface`, `macdrv_client_surface_release`), assente nel
nostro albero (stessa famiglia dello *shm surface*, CX HACK 23950). → Per usarlo servono le **sorgenti
pubbliche CodeWeavers** (Wine 11.0 + gli hack CW), non un porting a mano: build in `~/wine-cx`.

## Installazione

```bash
# 1. pacchetto già pronto (consigliato: nessuna compilazione)
gx runtime install --tar game-x-wine-dxmt-11.10-macos-x86_64.tar.xz --sha256 <hash>

# 2. oppure compilazione locale (~40-60 min)
gx runtime install --from-source

# 3. verifica
gx runtime status

# 4. box pronta per Steam + giochi D3D11
gx box create Steam --runtime dxmt
gx steam install Steam
gx steam run Steam
```

Per creare il pacchetto da una build già fatta:

```bash
./scripts/package-runtime.sh          # → dist/game-x-wine-dxmt-<ver>-macos-x86_64.tar.xz + sha256
```

## Limiti noti

- Richiede **Rosetta 2** (Wine è x86_64: su Apple Silicon gira tradotto).
- Il build è x86_64 + i386 (WoW64 nuovo): i giochi 32-bit passano dal lato 64-bit.
- DXMT copre D3D10/D3D11; **D3D12** non è supportato (nessun renderer libero su macOS).
- Kernel anti-cheat e alcuni launcher restano incompatibili (come su ogni Wine).
- Nessuna ridistribuzione di binari Valve/Apple: il runtime contiene solo Wine (LGPL,
  con le nostre patch in `Patches/`), DXMT (MIT), MoltenVK/freetype/gnutls (licenze libere)
  e wine-mono (LGPL). Steam viene scaricato dall'utente dal CDN di Valve.
