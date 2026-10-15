# Evidenza di accettazione (ORCHESTRATOR, `gx-dxmf`)

Tutto prodotto **senza toccare box di altri**: le box usate sono di mia proprieta',
create in una tmpdir con prefisso riservato `gxdxmf-*`; carico **sintetico**
(`dxmf_demo.exe`), nessun gioco, nessun download; sola lettura su `~/wine-d3dmetal`,
`~/x64deps`, `~/Workspace/dxmf/build/game-stage`.

## 1. I moduli CARICATI sono i nostri (`lsof`, per path)

```
$ lsof -p <pid del processo del gioco>
dxmf_demo <pid> ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/d3d11.so
dxmf_demo <pid> ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/dxgi.so
dxmf_demo <pid> ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-windows/d3d11.dll
dxmf_demo <pid> ... /Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-windows/dxgi.dll
```
Vedi `lsof-stage.txt` / `modules.txt` (raw) e `evidence/module-load-proof.sh`.

## 2. Marker di CARICAMENTO dei nostri moduli nel log della run (`gx dxmf run`)

```
[unix:dxgi]  image=/Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/dxgi.so
[unix:d3d11] image=/Users/valerio.domenici/Workspace/dxmf/build/game-stage/wine/x86_64-unix/d3d11.so
```

## 3. Il carico sintetico e' andato a buon fine

```
[demo] present frame=0 hr=0x00000000 draws=6 commands=6   (x24)
[demo] verdict=PASS failures=0
```

## 4. Il CLI ha orchestrato tutto: lock, orfani, contratto, tetto, `du`

```
$ gx dxmf run gxdxmf-e2e --verbose --winedebug +d3d11,+dxgi --max-log-mb 1 -- <demo>
winedbg orphans: 0 (processes 761 of 2666)
stage: <stage>
modules: d3d11,dxgi
deps: /Users/valerio.domenici/x64deps (freetype, MoltenVK, gnutls)
exit: 0
log: <logs>/dxmf/gxdxmf-e2e-...Z.log
written: 411032 bytes
du: 462848 bytes
truncated: no
```
Il **tetto** e' esercitato dal test ermetico (`gx-selftest`): un processo che scrive
6 MB con cap 1 MB → `truncated=true`, `du <= 3 MB`, marcatore presente nel file.

## 5. Un host senza le due patch e' RIFIUTATO per nome (non "provato e fallito")

```
$ GX_DXMF_WINE_ROOT=/Applications/Wine Staging.app/Contents/Resources/wine gx dxmf status
capabilities : dxmf modules: not loadable (ntdll.so lacks WINEDLLPATH_PREPEND;
               winemac.so lacks macdrv_functions)
unusable     : ... do not load at all (ERROR_MOD_NOT_FOUND, 126)
$ echo $?    -> 3
```
Coincide con la misura indipendente del CEO (`dxgi=126 d3d11=126` con Staging).

## 6. Cosa NON e' provato qui (e va al CEO)

- Steam **vivo e visibile sullo stesso host dxmf** (un solo wineserver): serve una box
  con Steam e una decisione del CEO (vedi `ESCALATION AL CEO` nel report).
- L'accettazione **giocata** su un gioco vero: e' del CEO per mandato.
