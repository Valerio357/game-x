# UX — primo avvio (utente che scarica Game-X)

> Obiettivo: **un utente che scarica l'app per la prima volta deve arrivare a giocare
> da solo**, senza conoscere Wine, D3DMetal, CodeWeavers, TCC o il terminale.
> Il **box default e unico supportato è `wine-gptk`** (Wine dai sorgenti CodeWeavers +
> **D3DMetal** di Apple). Tutto il resto è opzionale/ripiego.

Questo documento è la **specifica della Dashboard**: elenca *tutto* ciò che serve,
e per ogni voce dice se la Dashboard lo riporta **tutto / di meno / di più**.
Le correzioni di codice corrispondono ai marcatori `→ FIX-*`.

---

## 1. Anatomia del prodotto

| Pezzo | Cosa è | Chi lo fornisce |
|---|---|---|
| **GameX.app** | La GUI (Dashboard/Boxes/Logs) + il core `GameXCore` | noi (build locale / release) |
| **Runtime `wine-gptk`** | Wine costruito dai sorgenti pubblici CodeWeavers + redist **D3DMetal** di Apple, tutto dentro una cartella auto-consistente | Wine = LGPL (ricostruibile); **D3DMetal = Apple** (non ridistribuibile: va preso dall'utente) |
| **Box** | Un prefix Wine (`~/WinePrefixes/<nome>`) creato sul runtime `wine-gptk` | il tool |
| **Steam** | Il client Windows installato nella box | il tool scarica `SteamSetup.exe` da Valve |
| **Giochi** | Le librerie dell'utente | l'utente, via Steam |

---

## 2. Tutto quello che serve (lista completa)

Legenda **Tipo**: 🖥️ sistema · 🧰 tool da terminale · 🧩 runtime · 🔐 permessi · 🎮 gioco.
**Auto?**: ✅ il tool lo fa · ⚠️ il tool guida / lo fa in parte · ❌ manuale.

| # | Prerequisito | Perché | Come | Tipo | Auto? |
|---|---|---|---|---|---|
| 1 | Mac **Apple Silicon** (M1+) | Wine x86_64 gira via Rosetta; D3DMetal richiede Metal | hardware | 🖥️ | ❌ |
| 2 | macOS recente (13+) | Metal 3/4, feature IOHID | aggiornamento di sistema | 🖥️ | ❌ |
| 3 | **Rosetta 2** | esegue il codice x86_64 del gioco/Wine | `softwareupdate --install-rosetta --agree-to-license` | 🖥️ | ✅ |
| 4 | **Xcode Command Line Tools** | serve `clang`/`make` per buildare Wine (`wine-cx`) e lo shim | `xcode-select --install` | 🧰 | ✅ (avvia l'installer) |
| 5 | **Homebrew** | fonte di `winetricks`, `mingw-w64`, `cabextract` | https://brew.sh | 🧰 | ⚠️ (link + comando) |
| 6 | **winetricks** | installa dipendenze Windows (VC++, font, .NET) | `brew install winetricks` | 🧰 | ✅ |
| 7 | **cabextract** | richiesto da winetricks | `brew install cabextract` | 🧰 | ✅ |
| 8 | **mingw-w64** | ricompila lo shim `steamwebhelper` (fix CEF nero) | `brew install mingw-w64` | 🧰 | ✅ |
| 9 | **Runtime `wine-gptk`** | il motore: Wine + d3d11/dxgi D3DMetal + MoltenVK/SDL2 + wine-mono | `gx runtime build-gptk` (o tarball prebuilt + redist D3DMetal) | 🧩 | ⚠️ |
| 9a | ↳ **Wine da sorgenti CodeWeavers** (`~/wine-cx`) | D3DMetal richiede lo schema TEB-in-TSD (CodeWeavers), non Wine upstream | **scaricata in automatico** dal release (`wine-cx-macos-x86_64.tar.xz`, ~137 MB) da `gx runtime build-gptk` | 🧩 | ✅ |
| 9b | ↳ **redist D3DMetal** | il renderer Apple | estratta dal **DMG Game Porting Toolkit 4** di Apple (gratuito, developer.apple.com) | 🧩 | ⚠️ (serve il DMG) |
| 9c | ↳ **`x64deps/`** | MoltenVK, freetype, **SDL2** (controller!) | inclusa nel runtime / da Wine Staging.app | 🧩 | ✅ |
| 9d | ↳ **wine-mono** | fa nascere il browser CEF di Steam | `.msi` nel runtime / scaricato da Wine | 🧩 | ✅ |
| 10 | **Permessi TCC: Accessibilità** | eventi tastiera/mouse al gioco | Impostazioni → Privacy → Accessibilità (binario `wine` + app che lancia) | 🔐 | ⚠️ |
| 11 | **Permessi TCC: Monitoraggio input** | `winebus`/IOKit per tastiera e **controller** | Impostazioni → Privacy → Monitoraggio input | 🔐 | ⚠️ |
| 12 | **Controller** | pad fisico via XInput (Steam Input **OFF**, default) | accendere il pad; se Bluetooth LE non va, usare USB | 🎮 | ✅ |
| 13 | **Steam** | store/launcher | `gx steam install <box>` (scarica da Valve) | 🧩 | ✅ |
| 14 | **Spazio disco** | runtime (~2 GB) + box (~20-25 GB con un gioco) | liberare spazio | 🖥️ | ✅ (check) |
| 15 | **Gioco** | il titolo | acquistato su Steam | 🎮 | ❌ |

> **Licenza**: il runtime NON ridistribuisce D3DMetal. L'utente lo prende dalla sua copia
> di terze parti; il tool lo estrae dal DMG di Apple e lo innesta nel runtime.

---

## 3. Happy flow (cosa vede e fa l'utente)

1. Scarica `GameX.app` → primo avvio: tasto destro → **Apri** (non notarizzata).
   L'app include già il **CLI `gx`** in `Contents/MacOS/gx`: non va installato a parte.
2. **Dashboard** si apre già popolata. In alto un riquadro **“Per iniziare”** con un unico
   pulsante **Installa tutto ciò che manca** (→ FIX-DASH-1). Dietro le quinte:
   Rosetta, Xcode CLT, Homebrew (se assente: link), winetricks, cabextract, mingw-w64.
   Ogni riga di **Diagnostics** ha il suo pulsante **Install** (o il link) quando manca
   qualcosa (→ FIX-DASH-8): non serve più copiare comandi a mano.
3. Il tool chiede **una cosa sola che non può fare da sé**: **la redist D3DMetal**.
   Due scelte esplicite (→ FIX-DASH-2):
   - **Uso il DMG di Apple (Game Porting Toolkit 4)** → il tool lo monta ed estrae D3DMetal
     (se il DMG è in `~/Downloads` lo trova da solo).
   (Serve anche una **Wine CodeWeavers** (`~/wine-cx`): se manca, la Dashboard lo dice
   nel check del runtime indicando esattamente cosa è assente.)
4. Il pulsante **Build runtime** (nella riga di Diagnostics “Runtime wine-gptk not
   installed”) costruisce `wine-gptk` eseguendo il **`gx` incluso nell'app**:
   niente terminale, niente `gx` da installare (→ FIX-DASH-9). Se `~/wine-cx` manca,
   il tool **scarica da solo** la base Wine dal release (→ FIX-DASH-10) e innesta la
   redist D3DMetal.
5. Il runtime appare come *runtime attivo* (`Game-X Wine+D3DMetal — wine-11.x / D3DMetal 4.0b2 [wine-gptk]`).
5. **Permessi**: compare una sezione **Permessi macOS** con due pulsanti
   (**Apri Accessibilità**, **Apri Monitoraggio input**) e l'elenco dei binari da aggiungere
   (`…/runtimes/wine-gptk/bin/wine`). Il tool rileva quando sono concessi (→ FIX-DASH-3).
6. **Boxes** → **Crea box** (`wine-gptk` preselezionato, unico default) → **Installa Steam**
   (download automatico) → **Run**.
7. In Steam: login, installa il gioco, **Play**. Steam Input è già **OFF** (pad fisico) per
   tutti i giochi (→ il tool lo scrive da solo).
8. Se tastiera/pad non rispondono, la Dashboard lo dice già al punto 5; il gioco va avviato
   dalla GUI/Steam (finestra attiva).

Risultato: **un percorso lineare da “app scaricata” a “sto giocando”**, con un solo punto
di decisione (sorgente D3DMetal) e un solo obbligo manuale (i permessi TCC).

---

## 4. Cosa riporta la Dashboard oggi

`DashboardView` mostra: *System* (macOS/arch/chip/GPU/Metal/runtime/D3DMetal/Steam-ready),
*Diagnostics* (i check di `Doctor.run`), *Components* (i componenti di `Setup.status`).

| Voce della lista §2 | Dashboard oggi | Verdetto |
|---|---|---|
| 1 Apple Silicon | check “macOS … (arch)” con “not Apple Silicon” | ✅ **tutto** |
| 2 macOS/Metal | “Metal …” + verdetto Metal 4 | ✅ **tutto** |
| 3 Rosetta 2 | check dedicato + componente | ✅ **tutto** |
| 4 Xcode CLT | **assente** | ❌ **di meno** |
| 5 Homebrew | **assente** (solo implicito in winetricks) | ❌ **di meno** |
| 6 winetricks | check + componente | ✅ **tutto** |
| 7 cabextract | check + componente | ✅ **tutto** |
| 8 mingw-w64 | check + componente | ✅ **tutto** |
| 9 Runtime `wine-gptk` | check “Runtime: …” ma **default = DXMT**; il componente `runtime` è `.manual` con URL vago (`scripts/…`) | ⚠️ **di meno** + **sbagliato** |
| 9a Wine `~/wine-cx` | **assente** | ❌ **di meno** |
| 9b D3DMetal redist (Apple GPTK) | solo “D3DMetal present/no” sul runtime scelto | ❌ **di meno** |
| 9c `x64deps` (SDL2!) | **assente** | ❌ **di meno** (rischio “controller non va”) |
| 9d wine-mono | **assente** | ❌ **di meno** |
| 10/11 Permessi TCC | **assenti** | ❌ **di meno** (causa misurata: tastiera/pad) |
| 12 Controller/Steam Input | **assente** | ❌ **di meno** |
| 13 Steam | badge per-box in *Boxes* | ✅ (fuori Dashboard, ok) |
| 14 Spazio disco | check, ma soglia **10 GB** | ⚠️ soglia troppo bassa |
| 15 Gioco | — | n/a |
| — Wine Staging (cask) | componente **mostrato come mancante** | ➕ **di più** (non serve) |
| — GPTK di sistema (cask) | componente **mostrato come mancante** | ➕ **di più** (non serve) |
| — “Runtime Wine+DXMT” | primo in `Runtime.choices`/`resolve` | ➕ **di più** (non è il default) |

---

## 5. Correzioni

- **FIX-DASH-1** — `Setup`: aggiungere i componenti mancanti e rendere “installa tutto” un
  percorso unico (Rosetta, Xcode CLT, Homebrew, winetricks, cabextract, mingw).
- **FIX-DASH-2** — `Setup`/Dashboard: componente **runtime `wine-gptk`** realmente azionabile:
  rileva 9a/9b/9c e spiega l'estrazione di D3DMetal dal DMG Apple.
- **FIX-DASH-3** — `Permissions`: check **Accessibilità** + **Monitoraggio input** con
  pulsanti che aprono i pannelli Privacy; riga dedicata in Dashboard.
- **FIX-DASH-4** — `Doctor`: check per **Xcode CLT**, **Homebrew** e **feature del runtime**
  (`sdl2`, `vulkan`, `mono` dal `manifest.json`) → avviso “controller/gamepad non
  funzioneranno” se manca SDL2.
- **FIX-DASH-5** — soglia **spazio disco ≥ 30 GB** (runtime + box).
- **FIX-DASH-6** — `Runtime`: **default = `wine-gptk`** (D3DMetal) prima di DXMT; `choices`,
  `resolve`, `resolveForSteam` e la copy della UI.
- **FIX-DASH-7** — Dashboard: **filtrare i componenti opzionali** (Wine Staging, GPTK di
  sistema) fuori dalla lista “manca”; mostrarli come “opzionali”.
- **FIX-DASH-8** — Dashboard/Diagnostics: ogni check con un componente installabile mostra
  il pulsante **Install** (o il link per Homebrew); i permessi mostrano **Open Settings**.
- **FIX-DASH-9** — Il **CLI `gx` è incluso nel bundle** dell'app (`Contents/MacOS/gx`, con lo
  script `build-runtime-gptk.sh` in `Contents/Resources/…`): la Dashboard può eseguire
  **Build runtime** senza che l'utente installi nulla. `gx` risolve le risorse con
  `BundledResources` (ricerca esplicita, **non** `Bundle.module`).
- **FIX-DASH-10** — La base **Wine CodeWeavers** non va più procurata a mano: se `~/wine-cx`
  manca, `gx runtime build-gptk` la scarica dal release (`wine-cx-macos-x86_64.tar.xz`,
  rilocabile, con `x64deps` incluso) e la estrae. Resta manuale solo **D3DMetal** (licenza).

## 6. Operazioni “offline” da portare nel tool

Queste le abbiamo fatte a mano durante lo sviluppo e **devono entrare nel prodotto**:

| Operazione fatta a mano | Diventa nel tool |
|---|---|
| Build di Wine dai sorgenti CodeWeavers (`~/wine-cx`) | `gx runtime build-gptk` (+ prerequisiti verificati da `doctor`) |
| Rinnesto della redist D3DMetal dal DMG Apple | stessa pipeline: `--gptk-dmg <DMG>` |
| Copia di `~/x64deps` (MoltenVK, SDL2…) nel runtime | incluso in `build-gptk`; feature registrata nel `manifest.json` |
| Copia di `wine-mono-*.msi` | inclusa in `build-gptk` (o download al primo bisogno) |
| `xattr -dr com.apple.quarantine` | incluso in `build-gptk` |
| Scrittura `UseSteamControllerConfig=0` | già automatica in `Steam.run` (pad fisico) |
| Permessi TCC | rilevati + pulsanti Privacy in Dashboard |

---

## 7. Definition of done (happy flow verificabile)

1. `gx doctor` su macchina pulita elenca **esattamente** le voci §2 (né più né meno) e
   `gx setup` ne installa tutte quelle automatiche.
2. `gx runtime build-gptk` porta a un runtime `wine-gptk` usabile partendo da:
   Xcode CLT + il **DMG Game Porting Toolkit 4** di Apple — senza altri passi a mano.
3. Dashboard: dopo il setup tutti i check sono **OK**, compresi i due permessi TCC.
4. `gx box create Gioco` → runtime **wine-gptk**; `gx steam install Gioco`; `gx steam run Gioco`;
   Play da Steam → gioco a schermo, **tastiera e pad** funzionanti.
