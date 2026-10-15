# F003 worklog — CLI dxmf (W3, ramo `gx-dxmf/f003-cli`)

## Letto (SOLA LETTURA)
- `dxmf/factory/ruoli/worker.md`
- `dxmf/factory/progetto.md`
- `gx-dxmf-w3/docs/GX-DXMF.md` (contratto, per intero)
- `gx-dxmf-w3/docs/STREAM-gx-dxmf.md` (vincolo sicurezza + stato)
- Sorgenti esistenti: `DXMF.swift`, `BoxLock.swift`, `Orphans.swift`, `Prefix.swift`,
  `Steam.swift`, `Config.swift`, `Runtime.swift`, `DXMT.swift`, `Logs.swift`,
  `ProcessRunner.swift`, `Shim.swift`, `Deps.swift`, `Sources/gx/main.swift`,
  `Sources/gx/Help.swift`, `Sources/gx-selftest/*`.

## Write-ahead
Sto per creare:
1. `Sources/GameXCore/LaunchLog.swift` (nuovo): `LogCap` + `LaunchLog.run`/`du`.
2. `Sources/gx/main.swift`: comando `dxmf status|modules|run`, helper `withBoxLock`,
   `libraryConfig`, lock su mutazioni, `box info`/`box list` lock-aware,
   `steam launch --exe`, rifiuto coppia incompatibile in `box create`.
3. `Sources/gx/Help.swift`: documentazione.
4. `Sources/gx-selftest/LogChecks.swift` (nuovo) + una riga in `main.swift`.

Baseline misurata PRIMA delle modifiche: `swift build` ok (solo warning pre-esistenti
in `AppModel.swift`), `swift run gx-selftest` = **205 passed, 0 failed**.

## Decisione non ovvia (da segnalare)
- **Self-conflict lock CLI↔libreria.** `Prefix.create/remove/purge` e
  `Steam.install/repair/run/launch` chiamano `Prefix.refuseIfLocked`, che rifiuta
  qualunque lock `.held`, **anche quello del processo corrente**. Se il CLI prende il
  lock canonico e poi chiama la libreria, la mutazione si auto-rifiuta. Per non
  toccare file di F002/F004 ho introdotto `libraryConfig(_:)`: il CLI prende il lock
  canonico (visibile a `box info`/`box list`/GUI) e passa alla libreria una copia della
  `Config` con `cacheRoot` su `.cli-lock-shield` (controllo di libreria passa); la cache
  shim è condivisa con un symlink per non ricompilare. È un workaround d'integrazione,
  non una scelta di prodotto: va rivisto dall'Architect (il controllo di libreria
  dovrebbe essere owner-aware).
- **Troncamento log**: si conserva la testa fino al cap, si appende UNA riga marker e
  poi si scarta l'output successivo (il processo NON viene ucciso). `written` conta tutti
  i byte letti; `du` misura il file reale.

## Esito

### Build
`swift build 2>&1 | tail -25` → `Build complete!` zero errori. Unico warning presente:
quello **pre-esistente** di `Sources/GameX/AppModel.swift:223-231` (SendableClosureCaptures),
non introdotto da F003.

### Selftest
`swift run gx-selftest 2>&1 | tail -40` → **216 passed, 0 failed** (baseline 205).
I +11 nuovi sono in `Launch log cap (F003)`: capped (truncated/written/bounded/marker),
uncapped (~6 MB), cap 0.

### Esercizi CLI (tmpdir, mai box vere)
`export GX_PREFIX_ROOT=$(mktemp -d)/boxes GX_CACHE_ROOT=$(mktemp -d)/cache GX_LOGS_ROOT=$(mktemp -d)/logs`
1. `swift run gx dxmf status` → host wine-11.10, stage d3d11/dxgi, pin 11.10 (default),
   capabilities hostable, deps `~/x64deps (freetype, MoltenVK, gnutls)`, log cap 512 MB,
   orfani 0. **EXIT=0**.
2. `swift run gx dxmf modules` → d3d11/dxgi PE+unix path + sha256. **EXIT=0**.
3. `swift run gx box create gxdxmf-test --runtime dxmf` → box ready (wineboot nella tmpdir),
   runtime Game-X Wine+DXMF wine-11.10. **EXIT=0**. (lock rilasciato: `cache/locks` vuota)
4. `swift run gx dxmf run gxdxmf-test --dry-run -- /bin/echo ciao` → piano + env con i valori
   (`WINEDLLPATH_PREPEND`, `WINEDLLOVERRIDES=d3d9,d3d11,dxgi=b`, `DXMF_DIAG_QUIET=1`,
   `DYLD_LIBRARY_PATH`), nessun lancio. **EXIT=0**.

### Lock (in tmpdir, read-only)
- Lock vivo scritto a mano: `box list` → `(locked)`; `box info` → «being rebuilt: lock held by
  pid N (command; reason) for Ns»; `dxmf run --dry-run` → rifiuto
  `box '...' is locked by pid N — Ns — command: ... — reason: ...`.
- `--force` su lock vivo → stampa chi ha rotto (pid/age/command/reason) e prosegue; poi rilascia.
- Due `box create` in parallelo sulla stessa tmp box: A ok, B rifiutato dal lock con pid/età/command/reason.
- Coppia incompatibile: host finto wine-7.7 + pin 11.10 → `dxmf status` exit 3 con mismatch nominato;
  `box create --runtime dxmf` rifiutato con lo stesso messaggio, nessuna box creata.

### Commit
sha: (vedi `git log` sul ramo `gx-dxmf/f003-cli`)

## Cosa NON ho provato
- Nessun lancio di gioco né di Wine su una box vera; nessuna scrittura in `~/WinePrefixes`,
  `~/wine-d3dmetal`, `~/Library/Caches/game-x`, `~/Library/Logs/game-x/dxmf`.
- `dxmf run` reale (non dry-run) con LaunchLog su un processo Windows: il tetto è provato in
  selftest con un processo POSIX che scrive 6 MB.
- `steam install/repair/run/launch/stop` reali (richiedono una box con Steam: non autorizzato).
  La sola cosa verificata è che compilano e che passano dal `withBoxLock` + `libraryConfig`.
- `deps install/remove` reali (winetricks).

## Scelte non ovvie (una riga ciascuna)
- Troncamento: conservo la testa fino al cap, appendo il marker e poi scarto (il processo continua).
- `libraryConfig` sposta solo `cacheRoot` su `.cli-lock-shield` (lock di libreria) e condivide
  `shims` con un symlink; il lock canonico resta quello del CLI.
- `--dry-run` stampa l'intero ambiente del processo (valori reali), non solo le variabili dxmf.
- `dxmf status` legge `config.dxmfWineRoot` ma il messaggio «not found» non è un exit 0.
- `--max-log-mb` non numerico è un errore di usage, non un fallback silenzioso al default.
