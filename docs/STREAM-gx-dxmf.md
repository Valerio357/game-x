# Stream `gx-dxmf` — stato su disco

Owner: ORCHESTRATOR `gx-dxmf`. Ramo di stream: `gx-dxmf/core` (base `ee1f267`).
Clone di integrazione: `/Users/valerio.domenici/Workspace/gx-dxmf`.
Clone dei figli: `~/Workspace/gx-dxmf-{w1,w2,w3,w4,val1,val2}` (uno per ruolo).
Regola `BLK-012`: il repo condiviso `~/Workspace/game-x` **non si tocca**. Nessun figlio pusha.

## Contratto

Obiettivo: far girare un gioco **sotto dxmf** con **un comando**, e impedire gli errori
già commessi tre volte (lock, letture ambigue, log senza tetto, orfani, diagnostica).
Design e API congelate: `docs/GX-DXMF.md`.

## Feature

| ID | Titolo | File | Owner | Stato | Commit |
| --- | --- | --- | --- | --- | --- |
| F001 | Runtime `dxmf` di prima classe (host+stage, pin di versione, contratto d'ambiente) | `Sources/GameXCore/DXMF.swift` (nuovo), `Runtime.swift`, `Config.swift` | W1 | **validato internamente** (build ok, 143/143 selftest) | `be92ee1` |
| F002 | Igiene: lock per box + orfani `winedbg` | `Sources/GameXCore/BoxLock.swift`, `Sources/GameXCore/Orphans.swift` (nuovi) | W2 | **validato internamente** (build ok, 143/143 selftest) | `a2250f8` |
| F001b | Probe delle capacità dell'host (le 2 patch + le librerie di sistema) | `Sources/GameXCore/DXMF.swift`, selftest | W1b | pending | — |
| F003 | CLI: `gx dxmf run/status/modules`, flag diagnostica, tetto di log, lock su ogni mutazione | `Sources/gx/main.swift`, `Sources/gx/Help.swift`, `Sources/GameXCore/LaunchLog.swift` (nuovo) | W3 | **validato** (VAL1 6/6 PASS) | `b7c214f` |
| F004 | Innesti: prefix lock-aware, find per enumerazione, Steam su dxvk + gioco su dxmf, doctor | `Sources/GameXCore/Prefix.swift`, `Steam.swift`, `Doctor.swift` | W4 | **validato** (VAL1 6/6 PASS) | `77542a3` |
| F005 | Validazione indipendente + accettazione (lsof) + correzione D1 | `evidence/`, `GameLauncher.swift` | ORCH + VAL1/VAL2 | **VALID1 6/6 PASS · VAL2 5/5 PASS**; D1 corretto e testato; accettazione giocata = CEO | — |

## Verifica (criterio di riuscita)

Non "compila": `gx dxmf run` fa partire un gioco vero sotto dxmf, con `lsof` sul processo
del gioco che mostra `<stage>/x86_64-unix/d3d11.so` **e** `dxgi.so`, e Steam vivo con UI
visibile nello stesso prefix. Box d'accettazione: `~/WinePrefixes/dxfm-3d`
(Wine Staging 11.10 + Steam + Thymesia appid 1343240).

## VINCOLO DI SICUREZZA (ordine del CEO, 2026-10-15 22:0x)

1. **Nessun comando che muta una box non mia.** Vietato `box create/remove/purge`,
   `steam install/repair/stop`, `deps install` su `dxmf-3d`, `SekiroDXMF`, `DXMF-renderer`
   o qualunque box che non sia mia. Vale anche per i test automatici.
2. **Le box di prova sono solo mie**, con prefisso riservato `gxdxmf-<qualcosa>`.
3. **Nessun download di giochi nuovi** e nessuna scrittura fuori dal mio clone del repo `gx`.
4. Se serve una box **con Steam**, lo chiedo prima al CEO.
5. Non lancio il gioco per giocarci: l'accettazione giocata è del CEO.

Nota di verità: un allarme del CEO su una presunta distruzione di `dxmf-3d` è stato
**ritirato** (era un suo refuso `dxfm-3d`↔`dxmf-3d`). La ricognizione di questo stream è
stata **read-only**: nessun comando `gx`, nessuna scrittura in `~/WinePrefixes` (un solo
`mkdir ~/WinePrefixes/.probe-abs` di misura, subito rimosso) e nessuna scrittura in
`~/wine-d3dmetal` o nel repo dxmf. I due WORKER del blocco 1 non hanno toccato nessun
prefix (verificato: zero occorrenze di `gx box|steam|deps`, `wineboot`, `WinePrefixes/*`
nei loro log).

## Evidenza raccolta (ORCH, read-only)

- **Capacità degli host (F001b) — misurato**: `~/wine-d3dmetal` ha `macdrv_functions`
  in `winemac.so` e `WINEDLLPATH_PREPEND` in `ntdll.so`, ma **zero** `libfreetype`,
  `libMoltenVK`, `libgnutls`; `Wine Staging.app` è `wine-11.10 (Staging)` con le librerie
  ma **senza** entrambe le patch. Dettagli e tabella in `docs/GX-DXMF.md` §1-bis.
- **Lettura ambigua (requisito 2) — osservazione poi NON riprodotta** (onestà di misura):
  2026-10-15 21:5x, su
  `~/WinePrefixes/dxfm-3d`: `stat`/`ls` sul percorso **assoluto** → `ENOENT`, mentre
  `os.listdir` dello stesso padre **elenca il nome con byte identici** (`b'dxfm-3d'`),
  e la lettura **relativa** (`cd WinePrefixes && ls dxmf-3d`) riesce. Cioè: `box list`
  mostra un box che `box info` dichiara inesistente. Causa: cache di nome del kernel
  mentre il prefix viene ricreato (la stessa classe di `Prefix.find` vs `Prefix.list`).
  Evidenza raw: `evidence/ambiguous-read-20261015.txt`.
  **Ri-misura alle 22:1x: non riproduce** (`0/200` fallimenti su entrambi i nomi, in
  entrambi i modi). Resta quindi una **regola di prodotto** (risolvere i box per
  enumerazione, mai rispondere «not found» per un nome che il listino mostra) e non un
  difetto accertato con causa nota: il file di evidenza porta entrambe le misure.
- **Coppia incompatibile**: `SekiroDXMF/.gx.meta.json` = `GPTK wine-7.7`; i moduli sono
  pin `11.10` (`dxmf/src/thunk/bridge/dxmf_wine_runtime.h:25`).
- **Il contratto d'ambiente provato**: `dxmf/CRITICAL.md:1400` (`DEC-137`).
- **Il pattern di lancio provato**: `dxmf/scripts/app-probe.sh` +
  `dxmf/build/app-probe/*/verdict.txt` (`measured=dxmf`, lsof content-matched).
