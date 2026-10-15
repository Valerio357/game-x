# VALIDATOR (gx-dxmf, val2-adversarial) — report

Clone: `/Users/valerio.domenici/Workspace/gx-dxmf-val2` @ **f59b10e** (`git status` pulito, `.build` assente).
Bersaglio: *«i moduli dxmf che il processo del gioco carica sono i NOSTRI»*, limitata all'evidenza di accettazione
"module-loading half" aggiunta dal commit f59b10e.

## 0. Cosa ho letto
- `factory/ruoli/validator.md` (in `/Users/valerio.domenici/Workspace/dxmf`, sola lettura): VALIDATOR read-only sul
  codice, reproduce il criterio con metodo diverso dal WORKER, esito `PASS`/`FAIL` con evidenza comando+output,
  `UNPROVEN` ammesso, niente patch/allargamento del Done, escalation al CEO con opzioni, report su disco.
- `evidence/F001b-worklog.md`, `evidence/F003-worklog.md`, `evidence/ambiguous-read-20261015.txt`,
  `evidence/sample-modules.sh`, `evidence/module-load-proof.sh`.
- `evidence/acceptance/README.md`, `evidence/acceptance/lsof-stage.txt`, `evidence/acceptance/modules.txt`.
- `Sources/gx/main.swift` (comandi `dxmf status|modules|run`), `Sources/GameXCore/DXMF.swift`,
  `Sources/GameXCore/Config.swift`, `git show f59b10e`.

Restrizioni rispettate: non ho usato `evidence/module-load-proof.sh` né altri script dell'orchestrator; ho riscritto
la prova a mano. Nessun `gx box create/remove/purge` su box esistenti; box solo dentro la mia tmpdir
`/tmp/gxdxmf-val2.73jWmc` (`GX_PREFIX_ROOT=$VTMP/boxes`), nessuna scrittura in `~/WinePrefixes`, `~/wine-d3dmetal`,
`~/Library/*`. `gx` ricostruito da zero con `swift build --scratch-path $VTMP/scratch` (clone non toccato).
Nessun `git push/checkout/merge`.

> **Nota sul path del target.** Il brief cita `.../build/pe/bin/dxfm_demo.exe`: quel file **non esiste**. Il file reale
> è `.../build/pe/bin/dxfm_demo.exe` (typo `dxfm`↔`dxmf`). Ho usato quello, verificato con `file`.
> ```
> $ ls -la /Users/valerio.domenici/Workspace/dxmf/build/pe/bin/dxfm_demo.exe
> ls: ... No such file or directory
> $ ls -la /Users/valerio.domenici/Workspace/dxmf/build/pe/bin/dxfm_demo.exe
> -rwxr-xr-x@ 1 valerio.domenici  staff  745537 Oct 14 23:32 .../dxmf_demo.exe
> ```

`gx dxmf modules` (dichiarazione di prodotto, dalla mia build):
```
$ $VTMP/scratch/release/gx dxmf modules
dxmf modules (/Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine)
d3d11  pe   : .../x86_64-windows/d3d11.dll  sha256 9967979c03a9673543a50adf0022f857561911158b499b005547a0cfcb4179fc
d3d11  unix : .../x86_64-unix/d3d11.so     sha256 136b2ff01788ab947a7fdc3734aebc222778923a16b96bcc1bfc29f5be8939c8
dxgi   pe   : .../x86_64-windows/dxgi.dll   sha256 4e4336f81e354c44a79566df2a51a80d6cb8082e6957b1d19a7851d66c945d35
dxgi   unix : .../x86_64-unix/dxgi.so      sha256 ae66a2715c6bd1aa2a243d548cf799de7c58ba0283255817890a56eca0392bbf
EXIT=0
```

---

## 1. Prova positiva, riprodotta da zero — PASS (per il carico sintetico)
Prefix mio in tmpdir (`/tmp/gxdxmf-val2.73jWmc/boxes/gxdxmf-val2-pos`, creato da Wine), demo con
`WINEDLLPATH_PREPEND=<stage>`, `WINEDLLOVERRIDES=d3d9,d3d11,dxgi=b`, `DYLD_LIBRARY_PATH=$HOME/x64deps`,
campionamento `lsof` ogni 0.3s. Script mio: `$VTMP/scripts/pos.sh`.

```
-- pids visti -- 27058
-- stage matches (path) [righe distinte] --
dxmf_demo 27058 ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/d3d11.so
dxmf_demo 27058 ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/dxgi.so
dxmf_demo 27058 ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-windows/dxgi.dll
dxmf_demo 27058 ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-windows/d3d11.dll
```
Tutti e quattro i file dello stage (PE+unix, d3d11+dxgi) sono mappati nel processo `dxmf_demo`.
Log del processo (`$VTMP/pos/demo.log`): `[demo] verdict=PASS failures=0`.
Le righe `[d3d11] ...` / `[unix:dxgi] ...` (centinaia) mostrano che i moduli **eseguono**, non solo si aprono.

## 2. Controllo negativo — PASS (nessun falso positivo)
Stesso demo, **senza** `WINEDLLPATH_PREPEND` e **senza** override, prefix fresco
(`boxes/gxdxmf-val2-neg`, creato senza prepend). Script mio: `$VTMP/scripts/neg.sh`.

```
$ grep -F "$STAGE" <lsof campionato>            -> VUOTO (0 righe; lo stage NON compare mai)
demo exit=3
-- tutti i d3d11/dxgi mappati --
dxmf_demo 36225 ... /Users/valerio.domenici/wine-d3dmetal/lib/wine/x86_64-windows/dxgi.dll
dxmf_demo 36225 ... /Users/valerio.domenici/wine-d3dmetal/lib/wine/x86_64-windows/d3d11.dll
[demo] D3D11CreateDevice -> 0x80004005 level=0x0000
$ grep -c "$STAGE" demo.log   -> 0
```
Senza il contratto dxmf il processo carica i dll **nativi** di `~/wine-d3dmetal/lib/wine` (hash diversi, vedi §3) e
il demo **fallisce**. Il controllo negativo non fallisce: la prova positiva è quindi significativa.

## 3. Per CONTENUTO, non per nome — PASS
`lsof` per il positivo mostra i path reali dello stage; `shasum -a 256` di quei path vs `gx dxmf modules`:
```
9967979c03a9673543a50adf0022f857561911158b499b005547a0cfcb4179fc  .../x86_64-windows/d3d11.dll   (= dichiarato)
136b2ff01788ab947a7fdc3734aebc222778923a16b96bcc1bfc29f5be8939c8  .../x86_64-unix/d3d11.so       (= dichiarato)
4e4336f81e354c44a79566df2a51a80d6cb8082e6957b1d19a7851d66c945d35  .../x86_64-windows/dxgi.dll    (= dichiarato)
ae66a2715c6bd1aa2a243d548cf799de7c58ba0283255817890a56eca0392bbf  .../x86_64-unix/dxgi.so        (= dichiarato)
```
Corroborazione indipendente del **contenuto** dei .so: i nomi delle cache AOT generati da dyld nel mio run coincidono
**carattere per carattere** con quelli dell'evidenza dell'orchestrator (`3841c0cb…d3d11.so.aot`, `1102a987…dxgi.so.aot`),
quindi i .so caricati erano lo stesso contenuto:
```
acceptance/modules.txt : .../oah/.../3841c0cb.../d3d11.so.aot ; .../1102a987.../dxgi.so.aot
mio run (all-d3d11-dxgi) : idem
```
Copie fuori dallo stage: **nessuna copia dei moduli è mappata** dal processo positivo (né `drive_c/.../system32`, né
`drive_c/.../syswow64`). Per dovere d'indagine ho cercato copie nel box: nel prefix creato "a primo avvio con il
prepend" (`gxdxmf-val2-pos`) Wine ha materializzato in `drive_c/windows/system32/{d3d11,dxgi}.dll` copie
**byte-identiche** ai nostri PE (sha256 `9967979c…`/`4e4336f8…`). Tuttavia **non vengono caricate**: togliendo il
prepend lo stesso box continua a mappare i dll nativi di `~/wine-d3dmetal` e il demo fallisce (§2/trap sotto). Nel
box creato dal CLI (`gx box create --runtime dxmf`) le `system32` restano i dll nativi di Wine
(`a78104fb…`/`2d695478…`), quindi `gx box create` **non** copia i nostri moduli. I dll nativi di Wine hanno hash/size
diversi (d3d11 4.540.570 byte vs 959.278; dxgi 1.822.876 vs 813.749).
Trap verificato: eseguendo il demo sul prefix "pos" (che contiene le copie nostre in system32) **senza** prepend e
**senza** override, lsof mappa ancora `~/wine-d3dmetal/.../d3d11.dll` e il demo fallisce (`D3D11CreateDevice 0x80004005`):
la copia in `system32` è una fake-DLL, non la sorgente del builtin.

## 4. Marker di caricamento nel log — PASS (ma solo con `--verbose`)
Run `gx dxmf run` (mia build) sul box `gxdxmf-e2e`, `--verbose --winedebug +d3d11,+dxgi --max-log-mb 1`:
```
$ $VTMP/scratch/release/gx dxmf run gxdxmf-e2e --verbose --winedebug +d3d11,+dxgi --max-log-mb 1 -- "$DEMO"
winedbg orphans: 0 (processes 687 of 2666)
stage: /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine
modules: d3d11,dxgi
deps: /Users/valerio.domenici/x64deps (freetype, MoltenVK, gnutls)
exit: 0
log: /tmp/gxdxmf-val2.73jWmc/logs/dxmf/gxdxmf-e2e-2026-10-15T20-39-58Z.log
written: 411032 bytes
du: 462848 bytes
truncated: no
```
Nel log (`...39-58Z.log`, 411.032 byte):
```
7:[unix:dxgi]  image=/Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/dxgi.so
12:[unix:d3d11] image=/Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/d3d11.so
5029:[demo] verdict=PASS failures=0
```
**Caveat emerso (falsificazione parziale della lettura "marker di CARICAMENTO"):** senza `--verbose` gli stessi marker
**spariscono**. `globalDebugRequested()` → `quiet=false` solo con `--verbose/-v/--debug`; con quiet il processo riceve
`DXMF_DIAG_QUIET=1` e i marker `[unix:*] image=` non vengono emessi:
```
$ gx dxmf run gxdxmf-e2e --max-log-mb 1 -- "$DEMO"       # senza --verbose
written: 14445 bytes
$ grep -E 'image=' <log>   -> (NESSUNO)      ; $ grep -c '\[unix:' <log> -> 0
```
Quindi i marker sono una **auto-diagnosi del nostro modulo**, non output del loader di Wine, e compaiono solo in run
verbosa. La prova indipendente resta `lsof`.

## 5. Audit dell'evidenza dell'orchestrator (`evidence/acceptance/`)
File realmente presenti: `README.md`, `lsof-stage.txt`, `modules.txt`. **Non esiste alcun `*.log`** in
`evidence/acceptance/` (verificato con `find evidence -type f`). `modules.txt` è una lista `lsof` di d3d11/dxgi
(include anche le `.so.aot` di `/private/var/db/oah`), **non** l'output di `gx dxmf modules` e **senza hash**.

| # | Affermazione del README | Verdetto sull'evidenza raw |
|---|---|---|
| 1 | "I moduli CARICATI sono i nostri (`lsof`, per path)" | **Supportata solo per path** da `lsof-stage.txt`/`modules.txt`. **Nessun hash** nei raw: il contenuto non è provato dall'evidenza. |
| 2 | "Marker di CARICAMENTO … nel log della run" | **NON supportata**: il log non è committato. Riprodotta da me (§4), ma dipendente da `--verbose` (non dichiarato). |
| 3 | "Il carico sintetico è andato a buon fine: verdict=PASS" | **NON supportata**: nessun log del demo nei raw. Riprodotta da me (§1). |
| 4 | Blocco `gx dxmf run … --verbose --winedebug +d3d11,+dxgi` | **NON supportata**: nessun file di output CLI. Riprodotta quasi identica (`written 411032`, `du 462848`, `truncated no`). |
| 4b | "Il tetto è esercitato dal test ermetico (`gx-selftest`): 6 MB, cap 1 MB → truncated=true, du<=3 MB" | **Supportata in via indiretta**: `gx-selftest` mia build = `216 passed, 0 failed`, blocco `Launch log cap (F003)` con `6 MB … truncated`, `du 1003520`, marker presente. |
| 5 | Host senza le due patch RIFIUTATO per nome, `$? -> 3` | **NON supportata** da raw (nessun file status). **Riprodotta identica** (sotto). |
| 6 | "Cosa NON è provato qui" | Onesta e coerente (Steam vivo, gioco reale). |

Domande specifiche della consegna:
- **Il log `--verbose` contiene marker di caricamento o solo di risposta?** Contiene entrambi: i marker `[unix:d3d11] image=<stage>/…` e `[unix:dxgi] image=<stage>/…` (auto-diagnosi del modulo, in testa al log) e i marker di *risposta* / stato (`[d3d11] …`, `FRAME_*`, `[demo] …`). Non sono output del loader: sono gated da `--verbose`.
- **`--winedebug +d3d11,+dxgi` ha prodotto output di Wine?** **No.** Nel log verboso: 0 righe `trace:d3d11`/`trace:dxgi` (0 anche `warn:`/`err:` di quei canali); l'unica riga Wine è `00a4:err:ntoskrnl:ZwLoadDriver … winebth`. Il dry-run conferma che `WINEDEBUG=+d3d11,+dxgi` è stato davvero passato. Motivo: `d3d11`/`dxgi` sono i **nostri** moduli e non usano i canali `WINEDEBUG`; le righe `[d3d11]`/`[unix:d3d11]` sono diagnostica custom, non controllata da `WINEDEBUG`. Il flag, per questi moduli, è inerte (serve solo a imporre un cap finito).

Claim 5 riprodotta:
```
$ GX_DXMF_WINE_ROOT="/Applications/Wine Staging.app/Contents/Resources/wine" gx dxmf status
capabilities : dxmf modules: not loadable (ntdll.so lacks WINEDLLPATH_PREPEND; winemac.so lacks macdrv_functions) — patch the host first
unusable     : host Wine cannot load dxmf modules: …
EXIT=3
```

## 6. Verdetto complessivo su «i moduli caricati sono i nostri»
**PASS — limitatamente al carico sintetico (`dxmf_demo.exe`) e al percorso `lsof`/contenuto.** Con il contratto
d'ambiente dxmf il processo del demo mappa tutti e quattro i file dello **stage** nostro; nessun file dello stage è
mappato senza il contratto; gli hash dei file mappati coincidono con quelli dichiarati da `gx dxmf modules`; i .so
eseguono la nostra diagnostica; le copie eventuali in `system32` non sono la sorgente del builtin.
**UNPROVEN per «il processo del gioco»**: il target è un demo sintetico. Un gioco reale non è stato caricato (né qui né
nell'evidenza dell'orchestrator). Per chiudere quella metà serve lanciare un gioco/Steam reale con lo stesso contratto e
ripetere `lsof` + hash.

## 7. Punti in cui l'evidenza dell'orchestrator NON regge
1. **Nessun log committato** nonostante il README (claim 2-3) e il commit message parlino di marker e `verdict=PASS`: quei claim non sono verificabili dai file raw. Idem per l'output CLI (claim 4) e per `dxmf status` (claim 5).
2. **Nessun hash nell'evidenza**: il claim "i moduli caricati sono i nostri" è provato **solo per path**; il contenuto non è mai confrontato nell'evidenza con `gx dxmf modules`.
3. **Nessun controllo negativo committato**: l'evidenza non mostra cosa succede *senza* prepend; è la parte che rende significativa la prova positiva e manca del tutto.
4. **PID non correlato**: `acceptance/{lsof-stage,modules}.txt` sono del PID 10626, ma in `acceptance/` non c'è alcun `processes`/command line per quel PID (il `processes.txt` del PID 83336 sta in `evidence/module-load-proof/`). Non si può legare dai raw quel `lsof` al comando demo.
5. **`ESCALATION AL CEO` citata ma assente**: il README rimanda a "`ESCALATION AL CEO` nel report", ma nel repo non esiste alcun file di report/escalation (`find`).
6. **Claim di sicurezza non verificabile**: "box di mia proprietà in tmpdir con prefisso `gxdxmf-*`" non è deducibile dai raw (nessun path di prefix nei file).
7. Piccola imprecisione di path: il README cita `evidence/module-load-proof.sh` (esiste) ma dalla cartella `acceptance/` il riferimento corretto sarebbe `../module-load-proof.sh`; non bloccante.

Nessuno di questi è un difetto del *prodotto*: sono lacune dell'*evidenza*. Le fix vanno al WORKER/ORCHESTRATOR
(committare log e hash, aggiungere il controllo negativo con il comando), non a me.

## 8. Cosa NON ho provato
- Un **gioco reale** (né Steam): il claim resta `UNPROVEN` per il processo di gioco.
- Il comportamento con `--winedebug` **senza** `--verbose` e viceversa in tutte le combinazioni (ho provato: `--verbose`+winedebug → marker sì, Wine no; senza `--verbose` → marker no).
- Il **troncamento reale** di `gx dxmf run` con un processo Windows: ho visto solo il cap nel selftest ermetico (processo POSIX) e il caso non-troncato del demo (411 KB < 1 MB).
- `gx box remove/purge`, `steam/deps`, e qualunque scrittura fuori dalla mia tmpdir.
- L'hash del **contenuto** dei file *al momento* della run dell'orchestrator: ho confrontato gli hash correnti e i nomi AOT, non i byte di allora.
- Il comando `gx box create` con altre runtime e la creazione di box con prepend attivo (il caso del prefix "pos" l'ho ottenuto con `wineboot` implicito al primo `wine`, non via CLI).

## ESCALATION AL CEO
- **Blocco**: non c'è blocco tecnico. La metà "module loading" del claim è riproducibile e passa sul carico sintetico. Restano due decisioni.
- **Opzione A — accettare la metà sintetica come chiusura parziale**: costo ~0, rischio basso; lascia `UNPROVEN` il gioco reale. Raccomandata se il mandato è "moduli caricati = nostri" a livello di runtime.
- **Opzione B — pretendere il gioco reale prima della chiusura**: costo = box con Steam + download + gioco (richiede la tua decisione e viola il vincolo "nessun download" di questa validazione), rischio = dipendenza da contenuti/Steam, tempo. Da fare solo se il Done include esplicitamente il processo di gioco.
- **Opzione C — far committare all'ORCHESTRATOR l'evidenza mancante** (log `--verbose` con i marker, output `gx dxmf modules` con gli hash, output `gx dxmf status`, e un controllo negativo con il comando) così che i claim 2-5 del README siano verificabili dai raw: costo basso, rischio nullo, chiude i rilievi §7 senza toccare il prodotto.
- **Raccomandazione**: **A + C**. Accettare la metà sintetica come PASS (già riprodotta), e allocare all'ORCHESTRATOR il committimento dei raw mancanti per rendere l'evidenza auto-verificabile. La scelta di inseguire il gioco reale (B) è tua: supera il perimetro di questa validazione.

---
Metodo: tutti i comandi e gli output sono nel corpo del report; artefatti grezzi della mia riproduzione in
`/tmp/gxdxmf-val2.73jWmc/{pos,neg,e2e,pos-neg-trap}` (tmpdir mia, non committata). Non ho ucciso wineserver per non
toccare eventuali host di altri; nessun processo `dxmf_demo` è rimasto attivo (`pgrep` vuoto).
