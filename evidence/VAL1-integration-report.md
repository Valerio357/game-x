# Report VALIDATOR — stream `gx-dxmf`, clone `gx-dxmf-val1`

- Clone: `/Users/valerio.domenici/Workspace/gx-dxmf-val1`
- Commit: `f59b10e0f3120cac644e072148a55e3c930ed97d` (ramo `gx-dxmf/val1-integration`)
- `git status --short` = vuoto (nessuna modifica di prodotto; scritto solo questo report, fuori dal clone)
- Tutte le prove su tmpdir `/tmp/gxval1`; nessun `box create/remove/purge`/`steam install/repair` su box reali; nessuna scrittura in `~/WinePrefixes`, `~/wine-d3dmetal`, `~/Library/*`.

## Cosa ho letto (SOLA LETTURA)

- `/Users/valerio.domenici/Workspace/dxmf/factory/ruoli/validator.md` (per intero)
- `/Users/valerio.domenici/Workspace/dxmf/factory/progetto.md` (per intero)
- Nel clone: `Package.swift`, `docs/GX-DXMF.md`, `docs/STREAM-gx-dxmf.md`,
  `Sources/GameXCore/{DXMF,BoxLock,Prefix,Steam,LaunchLog,Runtime,GameLauncher,Config,Paths}.swift`,
  `Sources/gx/main.swift`, `Sources/gx-selftest/LogChecks.swift`, `evidence/ambiguous-read-20261015.txt`.

## Preambolo: build + selftest

```
$ swift build
Build complete! (8,88 s)   EXIT=0     # warning preesistenti in Sources/GameX/AppModel.swift (Sendable), non bloccanti

$ swift run gx-selftest
216 passed, 0 failed        EXIT=0
```

---

## 1. Contratto d'ambiente — **PASS**

Comando (devo con deps presente, lock dir/wait esposti, frame-log):

```
$ GX_PREFIX_ROOT=/tmp/gxval1/b GX_CACHE_ROOT=/tmp/gxval1/c GX_LOGS_ROOT=/tmp/gxval1/l \
  GX_DXMF_WINE_ROOT=/tmp/gxval1/hostA GX_DXMF_STAGE=/tmp/gxval1/stage \
  GX_DXMF_LOCK_DIR=/tmp/gxval1/dlocks GX_DXMF_GATE_LOCK_WAIT=42 GX_DXMF_DEPS=/tmp/gxval1/deps \
  ./.build/debug/gx dxmf run mybox --runtime dxmf --frame-log /tmp/gxval1/frame.log --dry-run -- /bin/true arg1
```
Estratto dell'output:
```
  DXMF_DIAG_QUIET=1
  DXMF_FRAME_TIME=/tmp/gxval1/frame.log
  DXMF_GATE_LOCK_WAIT=42
  DXMF_LOCK_DIR=/tmp/gxval1/dlocks
  DYLD_LIBRARY_PATH=/tmp/gxval1/deps
  WINEDLLOVERRIDES=d3d9,d3d11,dxgi=b
  WINEDLLPATH_PREPEND=/tmp/gxval1/stage
EXIT=0
```
Con deps **inesistente** (`GX_DXMF_DEPS=/tmp/gxval1/nonexistent-deps`) e `--verbose`:
```
$ ... ./.build/debug/gx --verbose dxmf run mybox --runtime dxmf --dry-run -- /bin/true
  WINEDLLOVERRIDES=d3d9,d3d11,dxgi=b
  WINEDLLPATH_PREPEND=/tmp/gxval1/stage          # niente DYLD_LIBRARY_PATH, niente DXMF_DIAG_QUIET
```
Con deps assente e senza `--verbose`: `DXMF_DIAG_QUIET=1` (diagnostica spenta di default).
Conclusione: tutti i nomi/valori dichiarati presenti; `DYLD_LIBRARY_PATH` compare **solo** se la cartella esiste; la diagnostica non resta accesa senza richiesta (`quiet` è funzione di `--verbose/-v/--debug`).

## 2. Coppia incompatibile rifiutata — **PASS**

Host finto `wine-7.7` + stage d3d11/dxgi; host finto `wine-11.10` con `.so` **senza** i marker.

```
$ GX_DXMF_WINE_ROOT=/tmp/gxval1/hostB ./.build/debug/gx dxmf status mybox
  wine version    : wine-7.7
  version mismatch: host Wine wine-7.7 (major.minor 7.7) does not match pinned 11.10 ... the PE↔unix ABI (WINE_UNIX_CALL) is version-locked, so these modules do not load on this host
  unusable        : <stesso messaggio>
STATUS_EXIT=3

$ GX_DXMF_WINE_ROOT=/tmp/gxval1/hostB ./.build/debug/gx dxmf run mybox --runtime dxmf --dry-run -- /bin/true
gx: host Wine wine-7.7 ... does not load on this host
RUN_EXIT=1

$ GX_DXMF_WINE_ROOT=/tmp/gxval1/hostC ./.build/debug/gx dxmf status mybox
  wine version    : wine-11.10
  capabilities    : dxmf modules: not loadable (ntdll.so lacks WINEDLLPATH_PREPEND; winemac.so lacks macdrv_functions) — patch the host first
  unusable        : host Wine cannot load dxmf modules: ntdll.so lacks WINEDLLPATH_PREPEND; winemac.so lacks macdrv_functions. ...
STATUS_EXIT=3

$ GX_DXMF_WINE_ROOT=/tmp/gxval1/hostC ./.build/debug/gx box create newboxC --runtime dxmf
gx: host Wine cannot load dxmf modules: ... ERROR_MOD_NOT_FOUND, 126
EXIT=1     # e `ls` conferma che nessun box è stato creato
```
Il mismatch è **nominato**, l'exit è non-zero, e anche con versione combaciante ma senza le due patch il lancio/creazione è rifiutato. Nessun percorso in cui `gx` prova lo stesso a lanciare.

## 3. Lock esclusivo — **PASS**

Holder reale (fake `wine` che dorme) e secondo mutatore:
```
$ cat /tmp/gxval1/c/locks/mybox.lock
{"startedAt":"...","box":"mybox","pid":35967,"reason":"dxmf run","command":"gx dxmf run mybox"}

$ ./.build/debug/gx dxmf run mybox --runtime dxmf --dry-run -- /game.exe
gx: box 'mybox' is locked by pid 35967 — 2s — command: gx dxmf run mybox — reason: dxmf run
SECOND_EXIT=1

$ ./.build/debug/gx dxmf run mybox --runtime dxmf --force --dry-run -- /game.exe
WARN : BoxLock: FORCE breaking live lock on box 'mybox': pid 35967 (alive), age 2s, box 'mybox', command 'gx dxmf run mybox', reason 'dxmf run'
breaking live lock on 'mybox': pid 35967 (alive), age 2s, ...
FORCE_EXIT=0
```
Il rifiuto porta **pid, età, command e reason** (non «busy»); `--force` rompe un lock **vivo** e dice chi ha rotto.
Falsificazione (6 coppie di mutazioni concorrenti sulla stessa box):
```
trial 1: A_EXIT=1 B_EXIT=0     trial 4: A_EXIT=0 B_EXIT=1
trial 2: A_EXIT=1 B_EXIT=0     trial 5: A_EXIT=0 B_EXIT=1
trial 3: A_EXIT=1 B_EXIT=0     trial 6: A_EXIT=0 B_EXIT=1
both_passed=0
```
Nessuna sequenza in cui due mutazioni passano entrambe.

## 4. Steam non prende mai il contratto dxmf — **PASS**

Metodo indipendente: il fake `wine` scarica `env` su file, poi catturo l'ambiente **reale** passato al processo.

```
$ ./.build/debug/gx steam run steambox --runtime dxmf        # UI Steam
WINEDLLOVERRIDES=mscoree,mshtml=
WINEPREFIX=/tmp/gxval1/b/steambox
# nessuna riga WINEDLLPATH_PREPEND, nessun DXMF_*

$ ./.build/debug/gx steam launch steambox 12345 --exe .../Game.exe --runtime dxmf
DXMF_DIAG_QUIET=1
WINEDLLOVERRIDES=d3d9,d3d11,dxgi=b
WINEDLLPATH_PREPEND=/tmp/gxval1/stage
SteamAppId=12345
```
Codice: `Steam.steamEnvironment` (`Sources/GameXCore/Steam.swift:57,68-83`) rimuove il contratto; `Steam.launch` sul runtime dxmf usa `Prefix.dxmfLaunchEnvironment` (`Steam.swift:355-369`). Nessun percorso Steam prende i nostri moduli.

## 5. Nessun «not found» ambiguo — **PASS (con limite dichiarato)**

```
$ ./.build/debug/gx box list
  mybox   0 B
  steambox ... [+Steam]
$ ./.build/debug/gx box info mybox
Box 'mybox' ... initialized: yes   INFO_EXIT=0
```
Fallback per enumerazione esercitato (cartella presente, `drive_c` assente):
```
$ mkdir -p /tmp/gxval1/b/ghostbox
$ ./.build/debug/gx box info ghostbox
Box 'ghostbox' ... initialized: no   GHOST_EXIT=0
$ ls /tmp/gxval1/b/ghostbox/drive_c   -> No such file or directory
```
`Prefix.find` (`Sources/GameXCore/Prefix.swift:120-136`) fa fast-path su `drive_c`, poi **enumerazione** `contentsOfDirectory(prefixRoot)` + `names.contains(name)` e ritorna il record. Quindi `box info` non risponde «not found» per un nome presente nel listino.
**Limite (onestà):** la finestra transitoria del kernel descritta in `evidence/ambiguous-read-20261015.txt` **non è riproducibile** (0/200 fallimenti nella stessa evidenza); non ho potuto assistere end-to-end al caso «`list` mostra / `info` dice not found». Il verdetto PASS è sulla proprietà del codice + sul fallback esercitato, non sull'osservazione del transiente.

## 6. Tetto di log — **PASS (test non vacuo)**

Lettura del test (`Sources/gx-selftest/LogChecks.swift:8-56`): produce 6.000.000 byte su stderr, cap 1 MB, e verifica `truncated`, `written>=6M`, `duBytes<=3M`, marker, `du()` reale, più i casi 50 MB (intero) e cap 0 (illimitato). Non è vacuo: il file è misurato con `du` reale e il marker è letto dal file.
Riproduzione indipendente end-to-end via CLI (fake `wine` che scrive 6 MB):
```
$ ./.build/debug/gx dxmf run mybox --runtime dxmf --max-log-mb 1 -- /x
log cap reached after 1064960 bytes; truncating .../mybox-....log
exit: 0
written: 6000000 bytes
du: 1052672 bytes
truncated: yes
$ du -sk <log>   -> 1028
$ wc -c <log>    -> 1048610
$ grep -a -o '=== gx: log truncated at [0-9]* MB ===' <log>
=== gx: log truncated at 1 MB ===
```
File limitato **e** marcatore **e** `du` reale: PASS.

---

## Difetti trovati

**D1 (non bloccante, fuori dalle 6 asserzioni) — il gioco lanciato da `gx game launch` su runtime dxmf non riceve il contratto dxmf.**
- `Sources/gx/main.swift:1387-1406` (`game launch`) → `Sources/GameXCore/GameLauncher.swift:65` `Prefix.exec` → `Sources/GameXCore/Prefix.swift:223` `baseEnvironment` (`:322`), che non imposta `WINEDLLPATH_PREPEND` né forza `d3d9,d3d11,dxgi=b`.
- Evidenza (env realmente passato a wine):
```
$ ./.build/debug/gx game launch g1 --runtime dxmf
launching 'g1'…
--- captured env ---
WINEDLLOVERRIDES=mscoree,mshtml=        # niente WINEDLLPATH_PREPEND, niente dxmf
```
- Impatto: un gioco registrato come `exe` e avviato con `gx game launch` gira **senza** dxmf (con gli override native dxvk può morire a `0xC0000135`). Non è il difetto di A4 (non rende nera la UI di Steam) e non è nella superficie dichiarata (`gx dxmf run`, `gx steam launch`), quindi **non blocca**; da instradare al **Developer** se si vuole che `gx game launch` onori il runtime del box.

## Cosa NON ho provato

- Wine reale / box reali: tutte le prove usano host e stage finti. Non ho eseguito `gx dxmf run` su `~/wine-d3dmetal` né l'accettazione con Thymesia/`lsof` (non riproducibile in questo clone e vietata dai vincoli).
- GUI (`GameX.app`) e i suoi percorsi di mutazione/lock.
- `gx steam install/repair`, `box remove/purge`: vietati su box non miei; non esercitati.
- Il transiente di lettura ambigua (A5): non riprodotto.
- La cooptazione di host reali `Wine Staging.app` / `~/wine-d3dmetal` (probe `nm`/`strings`): non eseguita.

## Raccomandazione

Le 6 asserzioni passano con evidenza. Accettare il blocco; segnalare D1 al Developer come backlog (o fix mirato) senza bloccare lo stream. Nessun difetto che impedisca l'uso del comando dichiarato (`gx dxmf run` / `gx steam launch --runtime dxmf`).

## ESCALATION AL CEO

Nessun difetto **bloccante** trovato: non c'è blocco all'uso. Unica decisione di prodotto/backlog:

- **Cosa:** `gx game launch <name> --runtime dxmf` non applica il contratto dxmf (D1). **Perché:** percorso di lancio preesistente che chiama `Prefix.exec`/`baseEnvironment`.
- **Opzioni:**
  1. **Non fare nulla** (D1 fuori dalla superficie dichiarata): costo 0, rischio che un utente usi `gx game launch` su box dxmf e il gioco non parta con dxmf.
  2. **Fix mirato al Developer:** in `GameLauncher.launch`/`gx game launch`, se `runtime.dxmf != nil`, usare `Prefix.dxmfLaunchEnvironment` (come fa `Steam.launch`). Costo basso, rischio di toccare un percorso generico già in uso da runtime non-dxmf; richiede un test.
- **Raccomandazione:** opzione 2 come backlog non bloccante, con test dedicato; nel frattempo documentare che l'unico percorso supportato per dxmf è `gx dxmf run` / `gx steam launch --runtime dxmf`.
