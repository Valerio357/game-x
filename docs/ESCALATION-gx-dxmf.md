# ESCALATION AL CEO — stream `gx-dxmf` (2026-10-15)

Stato: blocco 1 e 2 **implementati, verdi e validati in modo indipendente**.
Resta **una** cosa che non posso decidere ne' eseguire da solo: l'accettazione con **Steam vivo**
e il vincolo di sicurezza sulle box che non sono mie.

## Cosa e' gia' fatto (con evidenza)

| ID | Cosa | Verdetto indipendente |
| --- | --- | --- |
| F001 | runtime `dxmf` di prima classe: host + stage + pin di versione `11.10` + contratto d'ambiente | in `be92ee1` |
| F001b | **probe delle capacita' dell'host**: le 2 patch CodeWeavers + freetype/MoltenVK/gnutls | in `c7a6993` |
| F002 | **un lock per box** + igiene orfani `winedbg` | in `a2250f8` |
| F003 | `gx dxmf status|modules|run`, tetto di log misurato con `du`, lock su ogni mutazione | **VAL1 6/6 PASS** (`b7c214f`) |
| F004 | prefix lock-aware, `find` per enumerazione, Steam su dxvk + gioco su dxmf, `doctor` | **VAL1 6/6 PASS** (`77542a3`) |
| F005 | accettazione «i moduli caricati sono i nostri» + correzione D1 | **VAL2 5/5 PASS** (`d5950d7`) |

`219/219` self-test verdi. D1 (`gx game launch` che non applicava il contratto) **corretto e testato**;
la stessa porta (`gx box exec`) corretta ora e verificata con `lsof`.

## ESC-1 — rendere completo il NOSTRO host (criterio di verifica del CEO)

**Fatto misurato.** `~/wine-d3dmetal` ha le **due patch** (`WINEDLLPATH_PREPEND` in `ntdll.so`,
`macdrv_functions` in `winemac.so`) ma **zero** `libfreetype` / `libMoltenVK` / `libgnutls`.
`~/x64deps` **contiene tutte e tre**, in **x86_64**. `gx` ora le espone da solo: risolve la
cartella deps (`GX_DXMF_DEPS` → `<runtime>/x64deps` → `~/x64deps`) e mette
`DYLD_LIBRARY_PATH` in **ogni** percorso di lancio (`gx dxmf run`, `gx box exec`,
`gx steam launch --runtime dxmf`, `gx game launch`), **senza scrivere nel runtime**.

| opzione | costo | rischio |
| --- | --- | --- |
| **A.** usare la cartella deps (implementato) | 0 | `DYLD_*` non e' letto da eventuali binari protetti da SIP; Wine non lo e' |
| **B.** installare le dylib **dentro** `~/wine-d3dmetal` | ~1 min + 250 MB | e' una **scrittura nel runtime**: serve la tua autorizzazione |
| **C.** ricostruire il runtime completo (`gx runtime install --from-source`) | 40–60 min | nessuno, ma non e' piu' necessario: B e' stata fatta |

**AGGIORNAMENTO (2026-10-15, tardi) — ESC-1 e' GIA' RISOLTA dal CEO.**
Alle **22:12** e **22:38** le tre librerie (e i loro dipendenti) sono state **installate
dentro `~/wine-d3dmetal`** (`lib/` e `lib/wine/x86_64-unix/`): misurato con
`stat`/`find` adesso, non ereditato dal documento. L'host e' quindi **completo E patchato**,
cioe' esattamente il caso che il CEO ha descritto: **un solo wineserver per Steam e gioco**.
La mia misura precedente (0/0/0) era di **22:0x** ed e' **stantia**: corretta in
`docs/GX-DXMF.md` §1-bis con entrambe le misure e le date.
La cartella deps resta come **rete di sicurezza** (per un host che non le avesse), non come
rimedio necessario. **Nessuna decisione residua su ESC-1.**

## F006 — difetto trovato dal CEO usando `gx`: RISOLTO e provato

Il lock copriva la **vita di un'applicazione** invece di una **mutazione**: `gx steam
run` / `gx dxmf run` (Steam) restavano lockati, quindi la sequenza reale — Steam vivo + il
gioco nella stessa box — era impossibile. Corretto: i run non prendono il lock (solo una
verifica «nessuna mutazione in corso»), `--no-lock`/`--force` sono la valvola documentata,
e una box **in uso** non si ricrea/rimuove senza `--force` (protezione dell'incidente da
11,57 GB). Prova end-to-end con il CLI vero: `evidence/acceptance/lock-scope-e2e.sh`,
**8/8 PASS**.

Resta la sola cosa che è tua: **la run vera su una box con Steam e un gioco** (la tua
`dxmf-run`), perché il box non è mio. Meccanismo provato; contenuto reale tuo.

## ESC-2 — l'accettazione «Steam parte e si vede» (decisione, non capacita')

> Resa **piu' facile** dall'aggiornamento di ESC-1: l'host e' ora completo, quindi Steam e il
> gioco possono girare **sullo stesso wineserver**, come hai chiesto.

Vincolo in vigore: **non muto box che non siano mie** e **se serve una box con Steam chiedo**.
Il criterio che hai dato e': *i moduli si caricano (sonda PASS) **E** Steam parte e si vede*.

- La **prima meta'** e' chiusa e riprodotta da un VALIDATOR indipendente:
  `lsof` + hash (4/4) sul processo del carico, con **controllo negativo** (senza contratto Wine
  carica i suoi `wined3d` e il demo fallisce `0x80004005`) — `evidence/acceptance/`.
- La **seconda meta'** richiede una box con Steam sull'host dxmf. Opzioni:

| opzione | costo | rischio |
| --- | --- | --- |
| **A.** mi autorizzi a creare `gxdxmf-acc-steam` (box mia, tmpdir) e a `gx steam install` li' (scarica il **client** Steam, nessun gioco) | ~10–20 min, ~250 MB | nessuno sulle tue box |
| **B.** mi autorizzi a lanciare il gioco in una **tua** box (`dxmf-3d`, Steam + Thymesia gia' installati) con `gx dxmf run` e sola lettura del resto | ~5 min | la box riceve scritture di Steam/log; **solo su tua autorizzazione esplicita** |
| **C.** fai tu l'accettazione giocata (e' tua per mandato) con i comandi qui sotto | 5 min + la partita | nessuno |

**Raccomandazione: A** per la visibilita' di Steam, poi **C** per la partita giocata.
Se preferisci il percorso piu' corto: **B** con autorizzazione esplicita.

## I comandi esatti (cosa deve digitare un umano, da ora in poi)

```sh
# 1) un runtime dxmf di prima classe, in una box tua
gx box create gxdxmf-acc --runtime dxmf          # rifiuta l'host incompatibile, prima di toccare il disco
gx dxmf status gxdxmf-acc                        # host, stage, pin, capacita', deps, tetto di log, orfani, lock
gx dxmf modules                                  # le coppie PE/unix + sha256 (la prova per CONTENUTO)

# 2) Steam resta su dxvk (la sua UI compone in D3D11: con i nostri moduli e' NERA)
gx steam install gxdxmf-acc
gx steam run     gxdxmf-acc                      # UI visibile

# 3) il gioco va su dxmf, con Steam gia' avviato
gx dxmf run      gxdxmf-acc -- <exe del gioco>   # contratto dxmf + lock + tetto di log misurato
gx steam launch  gxdxmf-acc <appid> --runtime dxmf
gx box exec      gxdxmf-acc -- '<exe del gioco>' # gioco diretto, senza Steam

# 4) la prova che i moduli caricati sono i NOSTRI (path, non nome)
gx dxmf run gxdxmf-acc --verbose -- <exe> &      # --verbose accende la diagnostica (default: spenta)
lsof -p $(pgrep -f '<nome exe>') | grep "$(gx dxmf modules | sed -n 's/.*unix *: //p' | head -1 | sed 's|/[^/]*$||')"

# 5) diagnostica dxmf (una chiusura pesante alla volta)
gx dxmf run gxdxmf-acc --frame-log /tmp/frame.log -- <exe>   # -> DXMF_FRAME_TIME
gx dxmf run gxdxmf-acc --winedebug +d3d11,+dxgi --max-log-mb 512 -- <exe>  # tetto + misura `du`
```

## Cosa serve da te, in una riga ciascuno

1. **Autorizzazione** per ESC-2 (A, B o C) se vuoi che chiuda io l'accettazione con Steam.
2. **Decisione su ESC-1** (raccomandazione: A, nessuna scrittura nel runtime).
3. **Merge su `main`** e **sostituzione del symlink** `/opt/homebrew/bin/gx`: sono tuoi, non miei.
