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
| F001 | Runtime `dxmf` di prima classe (host+stage, pin di versione, contratto d'ambiente) | `Sources/GameXCore/DXMF.swift` (nuovo), `Runtime.swift`, `Config.swift` | W1 | in progress | — |
| F002 | Igiene: lock per box + orfani `winedbg` | `Sources/GameXCore/BoxLock.swift`, `Sources/GameXCore/Orphans.swift` (nuovi) | W2 | in progress | — |
| F003 | CLI: `gx dxmf run/status/modules`, flag diagnostica e tetto di log | `Sources/gx/main.swift`, `Sources/gx/Help.swift` | W3 | pending (dipende da F001) | — |
| F004 | Innesti: prefix lock-aware, Steam su dxvk + gioco su dxmf, doctor | `Sources/GameXCore/Prefix.swift`, `Steam.swift`, `Doctor.swift` | W4 | pending (dipende da F001) | — |
| F005 | Validazione indipendente + accettazione reale (lsof) | `evidence/` | ORCH + VAL1/VAL2 | pending | — |

## Verifica (criterio di riuscita)

Non "compila": `gx dxmf run` fa partire un gioco vero sotto dxmf, con `lsof` sul processo
del gioco che mostra `<stage>/x86_64-unix/d3d11.so` **e** `dxgi.so`, e Steam vivo con UI
visibile nello stesso prefix. Box d'accettazione: `~/WinePrefixes/dxfm-3d`
(Wine Staging 11.10 + Steam + Thymesia appid 1343240).

## Evidenza raccolta (ORCH, read-only)

- **Riproduzione della lettura ambigua (requisito 2)**, 2026-10-15 21:5x, su
  `~/WinePrefixes/dxfm-3d`: `stat`/`ls` sul percorso **assoluto** → `ENOENT`, mentre
  `os.listdir` dello stesso padre **elenca il nome con byte identici** (`b'dxfm-3d'`),
  e la lettura **relativa** (`cd WinePrefixes && ls dxmf-3d`) riesce. Cioè: `box list`
  mostra un box che `box info` dichiara inesistente. Causa: cache di nome del kernel
  mentre il prefix viene ricreato (la stessa classe di `Prefix.find` vs `Prefix.list`).
  Evidenza raw: `evidence/ambiguous-read-20261015.txt`.
- **Coppia incompatibile**: `SekiroDXMF/.gx.meta.json` = `GPTK wine-7.7`; i moduli sono
  pin `11.10` (`dxmf/src/thunk/bridge/dxmf_wine_runtime.h:25`).
- **Il contratto d'ambiente provato**: `dxmf/CRITICAL.md:1400` (`DEC-137`).
- **Il pattern di lancio provato**: `dxmf/scripts/app-probe.sh` +
  `dxmf/build/app-probe/*/verdict.txt` (`measured=dxmf`, lsof content-matched).
