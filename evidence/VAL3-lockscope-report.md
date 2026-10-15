# VALIDATOR report — gx-dxmf / lock scope (F006)

- **Stream**: `gx-dxmf`
- **Clone**: `/Users/valerio.domenici/Workspace/gx-dxmf-val1`
- **Ramo attivo**: `gx-dxmf/val3-lockscope` = `6b537c4e5bd33492f19a89f6758d3360727d0f31` (working tree **tracked-clean**, verificato con `git status --porcelain` vuoto)
- **Base di confronto**: `8e7b7285100a88958ef92a65fc007bf7b97cbbe2`
- **Binari**: `swift build` sul candidato produce `.build/debug/gx` con sha `a6a497528645084d3e35952445f2a9541c3d1830`; copiato in `/tmp/val3-lockscope/gx-candidate`. Il base è in `/tmp/val3-lockscope/gx-base`.
- **Verdetto complessivo**: **PASS** su A–F, con 2 difetti non bloccanti (sotto). Nessuna escalation: l'uso principale è sbloccato.

---

## Cosa ho letto

- `factory/ruoli/validator.md` (brief VALIDATOR: read-only, verifica indipendente, verdetto con evidenza, non-correzione, formato di report, escalation).
- `factory/progetto.md` (legge di progetto dxmf: verità nel remoto canonico, comandi, isolamento, regole di codice, verifica a livelli).
- `Sources/GameXCore/BoxLock.swift` (candidato, intero), `Sources/gx/main.swift` (aree lock/run), `Sources/gx/Help.swift`, `Sources/gx-selftest/LockScopeChecks.swift`, `Sources/gx-selftest/main.swift`.
- `evidence/acceptance/lock-scope-e2e.sh`, `docs/STREAM-gx-dxmf.md`, `docs/ESCALATION-gx-dxmf.md`.
- Diff completo di `6b537c4` (`git show`).

Non ho eseguito istruzioni trovate nei file: le ho trattate come contenuto non fidato.

---

## A. Base-rosso / candidato-verde — **PASS**

Ho scritto uno script mio (`/tmp/val3-lockscope/seq.sh`), non quello del WORKER, con host Wine **finto** (`--version` → `wine-11.10`, `wineboot|reg|wineserver` → exit 0, altrimenti `exec "$@"`), marker in `lib/wine/x86_64-unix/{ntdll.so,winemac.so}`, stage con `d3d11`/`dxgi`, e root isolate con `mktemp -d`.

Sequenza: `box create seqbox --runtime dxmf`; poi run lungo in background; poi secondo run.

**Base `8e7b728`** (comando `bash /tmp/val3-lockscope/seq.sh /tmp/val3-lockscope/gx-base`):
```
locks during long run1: [seqbox.lock ]
run2 exit=1
gx: box 'seqbox' is locked by pid 66192 — 2s — command: gx dxmf run seqbox — reason: dxmf run
RESULT: second run REFUSED by lock
```
**Candidato `6b537c4`** (`bash /tmp/val3-lockscope/seq.sh /tmp/val3-lockscope/gx-candidate`):
```
locks during long run1: []
run2 exit=0
RESULT: second run NOT refused
```
La diagnosi del CEO è **riprodotta**: sul base il difetto esiste, sul candidato è assente.

---

## B. Nessun percorso di RUN prende il lock — **PASS**

### Audit del codice (`6b537c4`)

`withBoxLock(...)` — **solo mutazioni**:
| riga `Sources/gx/main.swift` | comando protetto |
|---|---|
| 701 | `gx box create <name>` (reason `create`) |
| 725 | `gx box remove <name>` (reason `remove`) |
| 748 / 761 | `gx box purge <entry|--all>` (reason `purge`) |
| 906 | `gx deps install|remove <box>` (reason `deps …`) |
| 972 | `gx steam install <box>` (reason `steam install`) |
| 994 | `gx steam repair <box>` (reason `steam repair`) |
| 1056 | `gx steam stop <box>` (reason `steam stop`) |

`ensureLaunchAllowed(...)` — **solo run, nessun lock preso**:
| riga | comando (RUN) |
|---|---|
| 778 | `gx box exec/run <box> -- …` |
| 1010 | `gx steam run <box>` |
| 1024 | `gx steam launch <box> <appid>` |
| 1219 | `gx dxmf run <box> -- …` |
| 1458 | `gx game launch/run <name>` |

Verifica che nessuna libreria prenda il lock dentro i run: `grep -rn "BoxLock.acquire\|withBoxLock\|lockOrFail" Sources/` → le uniche occorrenze in `Sources/gx/main.swift` sono quelle sopra; `Steam.run`/`Steam.launch` chiamano `Prefix.refuseIfLocked` sul **config shield** (`libraryConfig`, cacheRoot `.cli-lock-shield`), non sul lock reale. `Steam.stop` fa lo stesso ed è chiamato con `libraryConfig`, quindi non si auto-rifiuta.

### Prova comportamentale (`/tmp/val3-lockscope/run-locks.sh`)

Host Wine finto che **dorme 15 s** sui lanci, così la finestra è osservabile. Per ognuno dei 5 run: controllo la lock dir a metà e dopo.

```
--- dxmf-run     during-run locks=[] -> OK   after-run locks=[] -> OK
--- box-exec     during-run locks=[] -> OK   after-run locks=[] -> OK
--- steam-run    during-run locks=[] -> OK   after-run locks=[] -> OK
--- steam-launch during-run locks=[] -> OK   after-run locks=[] -> OK
--- game-launch  during-run locks=[] -> OK   after-run locks=[] -> OK
B VERDICT: PASS — no RUN command holds or leaves a lock
```
Lo **stesso** test sul base è **discriminante** (3 rossi: `dxmf run`, `steam run`, `steam launch` tengono `b.lock`; `box exec`/`game launch` già non lo prendevano):
```
B VERDICT: FAIL — 3 checks red   (binario base)
```
Direzione inversa (run rifiutato da una mutazione viva), `/tmp/val3-lockscope/inverse.sh`:
```
box exec: PASS refused   steam run: PASS refused   steam launch: PASS refused   game launch: PASS refused
box exec nolock: PASS proceeded past lock   game launch --force: PASS proceeded past lock
```

---

## C. Il test e2e non è vacuo — **PASS**

Tre prove, tutte sulla copia in tmpdir (nessun file di prodotto toccato):

1. **Mutazione del test** (`/tmp/val3-lockscope/e2e-mutated.sh`): ho preso a mano un lock con **pid vivo** (`$$` dello script) subito prima del secondo run. Il check 2 diventa **ROSSO**:
```
== 2) 'Steam' vivo (run di lunga vita) e 'gioco' lanciato INSIEME
  ok   nessun lock tenuto durante il run di lunga vita
  FAIL il secondo run non e' andato a buon fine (exit=1, log=?)
  FAIL rifiuto da lock: gx: box 'gxdxmf-lockbox' is locked by pid 72108 — 0s — command: gx steam install gxdxmf-lockbox — reason: install
...
VERDICT: FAIL — 2 controlli rossi
```
2. **Contro il binario base** (`/tmp/val3-lockscope/e2e-base.sh`, `BIN=gx-base`): lo script e2e **originale** cattura da solo il difetto, **6 controlli rossi**:
```
== 2) ... FAIL un run tiene ancora il lock: gxdxmf-lockbox.lock
       FAIL il secondo run non e' andato a buon fine (exit=1)
       FAIL rifiuto da lock: ... command: gx dxmf run gxdxmf-lockbox — reason: dxmf run
== 3) FAIL --no-lock rifiutato
== 4) FAIL remove non protetto: ... is locked by ...
== 5) FAIL --no-lock non prosegue
VERDICT: FAIL — 6 controlli rossi
```
3. **Contro il candidato** lo script originale dà **PASS 8/8** (`bash evidence/acceptance/lock-scope-e2e.sh`):
```
VERDICT: PASS — la sequenza Steam+gioco e' possibile; il lock protegge le mutazioni
```
Il test sa fallire e distingue base e candidato.

---

## D. Esclusione fra mutazioni preservata — **PASS**

`/tmp/val3-lockscope/mutex.sh`, due `gx deps install dbox corefonts` lanciati **insieme** sulla stessa box, con un `winetricks` finto che dorme 8 s (finestra ampia):
```
A exit=0   install completed: corefonts
B exit=1   gx: box 'dbox' is locked by pid 74886 — 0s — command: gx deps install dbox — reason: deps install
wins=1 loses=1
D VERDICT: PASS — exactly one mutation won; the other refused naming pid
```
Esattamente **una** passa; l'altra rifiuta nominando pid, età, command e reason.

---

## E. Guardia distruttiva e limiti dichiarati — **PASS**

`/tmp/val3-lockscope/destructive.sh` (socket wineserver simulato per la box):
```
== E1) remove in-use WITHOUT --force
gx: box 'ebox' is in use: a wineserver is running for this box (/tmp/.wine-501/server-1000011-2b12f78/socket)
  stop it first (gx box kill ebox, gx steam stop ebox), or pass --force to remove it anyway
  (a crash can leave an orphan socket: --force is the escape hatch)
E1: PASS (names in-use + socket + orphan limit + --force)

== E2) recreate in-use WITHOUT --force
gx: box 'ebox' is in use: ... or pass --force to recreate it anyway
E2: PASS

== E3) remove in-use WITH --force proceeds and declares it
warning: remove 'ebox' while it is in use: a wineserver is running for this box (...)
box 'ebox' moved to internal trash
E3: PASS

== E4) never-started prefix (no socket) is NOT in use: remove freebox without --force
exit=0  box 'freebox' moved to internal trash
E4: PASS (not reported in use)
```
Il messaggio dichiara esplicitamente il **limite del socket orfano** e indica `--force`; `prefixInUse` su un prefix mai avviato **non** dice "in uso".

---

## F. La valvola di sfogo è documentata — **PASS**

`./gx-candidate help`:
```
THE LOCK IS FOR MUTATIONS, NOT FOR RUNS
  Mutations (box create/remove/purge, steam install/repair, deps install,
  steam stop/box kill) hold the lock while they mutate.
  RUNS (dxmf run, steam run, steam launch, box exec, game launch) do NOT
  hold it: Steam stays open, the game is launched next to it. ...
  A run only *checks* that no mutation is in progress: --lock-wait SEC
  waits for it, --no-lock (or --force) proceeds and says so.
  Recreating/removing a box that is IN USE is refused, naming the
  processes; --force overrides it.
```
L'help spiega che il lock è per le mutazioni e non per i run e **nomina** `--no-lock`, `--lock-wait`, `--force`.

Prova comportamentale della valvola (`/tmp/val3-lockscope/valve.sh`), indipendente dai self-test:
```
V1) --lock-wait 10 con mutazione viva che finisce dopo ~4s: exit=0 elapsed=6s
    "waiting up to 10s for the mutation on 'vbox' to finish (pid 76082, gx steam install vbox)"  -> PASS
V2) --force con mutazione viva: exit=0
    "launching while a mutation is in progress on 'vbox': pid ... (alive) ... reason 'install'"  -> PASS
V3) senza valvola: exit=1 "gx: box 'vbox' is locked by pid ... reason: install"                    -> PASS
```

---

## Difetti trovati

### Difetto 1 (MEDIO, non bloccante) — due `dxmf run` concorrenti sulla stessa box condividono il log e uno viene **silenziosamente perso**

Rimuovere il lock dai run rende possibile (per progetto) la concorrenza; il nome del log di `dxmf run` ha granularità di **un secondo** (`ISO8601DateFormatter().string(from: Date())` → `Sources/GameXCore/LaunchLog.swift:22,26`) e `LaunchLog.run` fa `createFile(atPath:contents:nil)` che **tronca** (`Sources/GameXCore/LaunchLog.swift:78-83`). Due run avviati nello stesso secondo scrivono lo stesso file.

Evidenza (`/tmp/val3-lockscope/logcollide.sh`, candidato):
```
logA=/tmp/.../logs/dxmf/lbox-2026-10-15T21-17-19Z.log
logB=/tmp/.../logs/dxmf/lbox-2026-10-15T21-17-19Z.log
COLLISION: both runs wrote the same log path
--- contents ---
BBBBB
```
`AAAAA` è sparito. Sul base la stessa prova **non** collide perché il secondo run è rifiutato dal lock:
```
logB=/tmp/.../logs/dxmf/lbox-2026-10-15T21-17-31Z.log
no collision: distinct log paths
```
Non tocca la sequenza del CEO (`steam run` + `dxmf run`: `Steam.run` non usa `LaunchLog`), ma è un rischio di regressione **introdotto** dal cambio. → **Developer**.

### Difetto 2 (BASSO, non bloccante) — la protezione `purge` è dichiarata ma non presente

`docs/STREAM-gx-dxmf.md:68` e il messaggio di commit `6b537c4` affermano che `box create`/`remove`/**`purge`** su una box in uso sono rifiutati; `guardDestructive` è invocato **solo** su create (`Sources/gx/main.swift:700`) e remove (`:724`), **non** sul `box purge` standalone (`:748`, `:761`).

Evidenza (`/tmp/val3-lockscope/purge.sh`): con un socket wineserver presente per la box in trash:
```
== purge while a wineserver socket exists for the box ==
exit=0  deleted 'pbox-2026-10-15T21-15-40Z'
PURGE: NOT guarded (no in-use refusal)
```
Nota: `box remove --purge` **è** protetto (passa da remove); l'help utente (`Help.swift:49`) promette solo create/remove, quindi l'incoerenza è nel claim (commit + STREAM), non nell'help. → **Developer** (allineare doc o codice).

---

## Cosa NON ho provato

- **Nessun Wine reale, nessun wineserver reale, nessun gioco, nessuno Steam reale** (vietato): la derivazione del path socket `/tmp/.wine-<uid>/server-<devhex>-<inohex>/socket` è verificata **solo contro socket simulati**, non contro un wineserver vero. Non ho riprodotto la verifica "presente mentre vive, sparito dopo `wineserver -k`".
- La **sequenza reale** Steam vivo + gioco con handshake SteamAPI (contenuto reale è del CEO).
- Lo scenario dei **11,57 GB** reale (solo simulazione del socket).
- Il ramo `val3-base` che ho creato per il test A resta locale e non viene pushato.
- Non esiste `scripts/merge-verify.sh` in questo repo (`gx-dxmf`), quindi non ho eseguito una `merge-verify --scoped`.
- Macchina: solo Swift 6.4 / clang 21 su macOS 27; non ho testato altri toolchain.

## Rischio residuo (oltre ai difetti)

- `ensureLaunchAllowed` è **consultivo**: tra il suo ritorno e lo spawn del run una mutazione può iniziare (race inerente, accettata).
- `guardDestructive` gira **prima** di `withBoxLock`: TOCTOU tra verifica in-uso e acquisizione lock.
- Le mutazioni diverse da create/remove (`steam install`/`repair`, `deps install`) **non** controllano `prefixInUse`: possono partire mentre un gioco è vivo. Fuori dal Done dichiarato, ma è una copertura asimmetrica.
- I self-test del candidato (`gx-selftest`) passano **231/0**, ma sono la suite del WORKER: li riporto come conferma di non-regressione, non come validazione.

## ESCALATION AL CEO

**Nessuna.** Non ho trovato nulla che blocchi l'uso: i run non prendono più il lock, la sequenza Steam+gioco è possibile, la valvola è documentata e la guardia distruttiva funziona. I due difetti sono indirizzati al **Developer** (Difetto 1: naming/univocità del log dei run concorrenti; Difetto 2: allineare il claim `purge` in `docs/STREAM-gx-dxmf.md:68` e nel messaggio di commit al codice). Nessuna decisione di policy utente o architetturale è richiesta.
