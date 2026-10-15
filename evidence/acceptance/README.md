# Evidenza di accettazione — `gx-dxmf`, metà **«i moduli caricati sono i nostri»**

Prodotta e raccolta da `evidence/acceptance/collect.sh` (rieseguibile). Tutto il materiale
grezzo sta in **`raw/`**: ogni affermazione qui sotto cita il file che la sostiene.
I rilievi del VALIDATOR adversariale (v2 §7) sono chiusi in fondo, uno per uno.

## Provenienza (rilevante per i vincoli di sicurezza)

| cosa | valore |
| --- | --- |
| box usato | **`gxdxmf-acc`**, creato dal CLI dentro una **tmpdir** (`$TMPDIR/gxdxmf-acc-*`), prefisso riservato `gxdxmf-` |
| carico | `dxmf_demo.exe` — **demo sintetico**, non un gioco, nessun download |
| host Wine | `~/wine-d3dmetal/bin/wine` (`wine-11.10`), **sola lettura** |
| stage moduli | `~/Workspace/dxmf/build/game-stage/wine`, **sola lettura** |
| dylib di supporto | `~/x64deps`, **sola lettura** |
| box di altri | **mai toccate** (nessun `create/remove/purge`, nessun `steam`/`deps`) |

Comandi esatti: `raw/00-commands.txt`.

## 1. Il contratto d'ambiente e chi lo riceve

`raw/10-status.txt` (host patchato), `raw/11-status-staging.txt` (host senza patch, `exit=3`),
`raw/20-run-positive.txt` (la run), `raw/13-box-create.txt` (la box).

## 2. I moduli mappati sono i NOSTRI — per path **e per contenuto**

`raw/22-lsof-stage.txt` (8 righe `lsof`, dai PID in `raw/21-process.txt`), confrontate con
`raw/12-modules.txt` (`gx dxmf modules`):

```
$ python3  # confronto hash
dichiarati: 4   mappati: 4
MATCH  d3d11.so 136b2ff01788ab94
MATCH  dxgi.so  ae66a2715c6bd1aa
MATCH  d3d11.dll 9967979c03a96735
MATCH  dxgi.dll  4e4336f81e354c44
```
(il confronto completo è in `raw/26-hashes-mapped.txt`). Il PID è legato al comando in
`raw/21-process.txt` (`.../dxmf_demo.exe`).

## 3. I moduli *eseguono*, non solo si aprono

`raw/24-load-markers.txt`:
```
[unix:d3d11] image=.../game-stage/wine/x86_64-unix/d3d11.so
[unix:dxgi]  image=.../game-stage/wine/x86_64-unix/dxgi.so
```
**Precondizione, dichiarata**: questi marker sono la **auto-diagnosi dei nostri moduli** (non
output del loader di Wine) e vengono emessi **solo senza `DXMF_DIAG_QUIET`**, cioè con
`--verbose`. Di default la diagnosi è **spenta** (`DXMF_DIAG_QUIET=1`) perché accesa costa
frame: senza `--verbose` il log non li contiene, e la prova resta comunque `lsof` + hash.
`--winedebug +d3d11,+dxgi` **non** produce output di Wine: `d3d11`/`dxgi` sono i nostri moduli e
non usano i canali `WINEDEBUG` (misurato: 0 righe `trace:d3d11|dxgi` nel log di 411 KB).

## 4. Il carico è andato a buon fine

`raw/25-demo-verdict.txt`: `presented=24 … verdict=PASS failures=0`.

## 5. Controllo negativo (la parte che rende significativa la prova positiva)

`raw/30-negative-control.txt` — stesso demo, stesso box, **senza** il contratto:
```
exit=3
--- righe dello stage mappate (atteso 0): 0
fixme:winediag:wined3d_select_feature_level None of the requested D3D feature levels is supported
[demo] D3D11CreateDevice -> 0x80004005 level=0x0000
--- dll native mappate:
   ~/wine-d3dmetal/lib/wine/x86_64-windows/dxgi.dll
   ~/wine-d3dmetal/lib/wine/x86_64-windows/d3d11.dll
```
Senza il contratto Wine carica i **suoi** dll (`wined3d`) e il demo **fallisce**: la prova
positiva non è un falso positivo.

## 6. Il CLI ha orchestrato lock, orfani, tetto e misura

`raw/20-run-positive.txt`: `winedbg orphans: …`, `stage:`, `modules:`, `deps:`, `exit:`,
`log:`, `written:`, `du:`, `truncated:`. Il **troncamento** del tetto è provato dal test
ermetico del progetto (`swift run gx-selftest`, sezione *Launch log cap*): 6 MB scritti con cap
1 MB → `truncated=true`, `du <= 3 MB`, marcatore nel file. Nell'evidenza la demo scrive 411 KB,
sotto il tetto: per questo `truncated: no`.

## 7. Cosa NON è provato qui

- **Steam vivo e visibile sullo stesso host dxmf**, e un **gioco reale**: serve una box con
  Steam e una decisione del CEO (vincolo di sicurezza: le box non mie non si mutano).
  Vedi `ESCALATION AL CEO` nel report dell'orchestrator.

## Rilievi chiusi (VALIDATOR v2 §7)

| # | Rilievo | Chiusura |
| --- | --- | --- |
| 1 | «nessun log committato» | `raw/23-log-positive.log` (411 KB) e `raw/34-negative-log.txt` sono **nel repo** (`git add -f`: `*.log` è in `.gitignore`) |
| 2 | «nessun hash: il contenuto non è provato» | `raw/12-modules.txt` (dichiarati) + `raw/26-hashes-mapped.txt` (mappati): **4/4 MATCH** |
| 3 | «nessun controllo negativo» | `raw/30-negative-control.txt` + `raw/32-negative-lsof-stage.txt` (0 righe) |
| 4 | «PID non correlato al comando» | `raw/21-process.txt`: pid + command line completa del demo campionata durante la stessa run |
| 5 | «escalation citata ma assente» | sezione `ESCALATION AL CEO` nel report dell'orchestrator, riportata anche in `docs/STREAM-gx-dxmf.md` |
| 6 | «provenienza non deducibile» | tabella *Provenienza* sopra + `raw/00-commands.txt` con la tmpdir esatta |
| 7 | «path relativo dello script» | `evidence/acceptance/collect.sh` e `../module-load-proof.sh` |

## Difetto trovato dal VALIDATOR e **corretto** (D1)

`gx game launch` su un box dxmf non applicava il contratto (`GameLauncher` → `Prefix.exec` →
`baseEnvironment`): un gioco registrato e avviato così girava senza dxmf e, con gli override
native di dxvk, sarebbe morto a `0xC0000135` prima di qualunque nostro codice.
Corretto in `Sources/GameXCore/GameLauncher.swift` (ramo dxmf → `Prefix.dxmfLaunchEnvironment`),
con test in `Sources/gx-selftest/PrefixChecks.swift` («D1: a dxmf game launch carries
WINEDLLPATH_PREPEND» / «forces the dxmf builtin modules» / «a non-dxmf runtime takes the
unchanged path»). Il fix ha portato anche alla centralizzazione della diagnostica in
`DXMF.Diagnostics.defaults(config:…)`, così **tutti** i percorsi di lancio portano la stessa
cartella deps (`DYLD_LIBRARY_PATH`) — prima `steam launch --runtime dxmf` non la metteva.
