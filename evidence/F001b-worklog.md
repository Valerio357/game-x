# F001b — worklog (W1b)

Ramo: `gx-dxmf/f001b-host` · clone: `/Users/valerio.domenici/Workspace/gx-dxmf-w1`

## Letto
- `factory/ruoli/worker.md`, `factory/progetto.md` (sola lettura, in `/Users/valerio.domenici/Workspace/dxmf`).
- `docs/GX-DXMF.md` §1-bis e §2 (contratto congelato), `docs/STREAM-gx-dxmf.md`.
- `Sources/GameXCore/DXMF.swift`, `Runtime.swift`, `Config.swift`, `ProcessRunner.swift`,
  `Sources/gx-selftest/main.swift` (blocco DXMF).

## Piano (write-ahead, prima di modificare)
1. `DXMF.HostCapabilities` + `DXMF.hostCapabilities(forBinary:)`: probe read-only con
   `strings` (ntdll: `WINEDLLPATH_PREPEND`), `nm -gU` + fallback `strings` (winemac:
   `macdrv_functions`), walk bounded (maxdepth 4) + esplicito `lib/external/*` per
   `libfreetype*`, `libMoltenVK*`, `libgnutls*`. Nessuna esecuzione di Wine.
2. `DXMF.Info.hostCapabilities` (stored), calcolata in `discover`; `unusableReason`
   compone in ordine: eseguibile/moduli → `versionMismatch` → `hostCapabilities.refusal`.
   `isUsable` = versione ok **e** le due patch (le librerie NON contano).
   `canHostSteam` resta un fatto separato; `refusal` nomina la patch mancante e il rimedio
   `gx runtime install --from-source`.
3. Test ermetici in `Sources/gx-selftest/main.swift`: 4 host finti (a/b/c/d) + host reali
   `~/wine-d3dmetal` e `Wine Staging.app` solo se esistono (read-only).

## Vincoli
- Nessun comando che muta box/prefix; nessuna scrittura in `~/WinePrefixes`,
  `~/wine-d3dmetal`, cache game-x. Solo file del clone.
- Perimetro: `Sources/GameXCore/DXMF.swift`, `Sources/gx-selftest/main.swift` (+ questo worklog).

## Esito (2026-10-15 ~22:14)

- `swift build`: **Build complete**, 8 warning **preesistenti** (`Sources/GameX/AppModel.swift`,
  `Sources/GameXCore/Steam.swift`), **0 nuovi**. Verificato con `git stash push` sulle mie modifiche:
  base = 8 warning, stessi file; con le modifiche = 8, stessi file. Zero errori.
- `swift run gx-selftest`: **179 passed, 0 failed**.
- Implementato: `DXMF.HostCapabilities` + `DXMF.hostCapabilities(forBinary:)` (read-only,
  `nm`/`strings`/walk), `Info.hostCapabilities` calcolata in `discover`, `unusableReason`
  nell'ordine eseguibile/moduli → `versionMismatch` → `hostCapabilities.refusal`.
  `isUsable` = versione ok && le due patch; `canHostSteam` separato, informativo.
- Test: 4 host finti (a patch+libs, b patch no libs, c libs no patch, d nessuno) + 2 host
  reali read-only (`~/wine-d3dmetal`, `Wine Staging.app`) solo se esistono.

### Scoperta (importante, fuori dal mio perimetro)
Durante il lavoro, **un'altra lane** (processi `dxmf-playfix-val4`, `gx steam run dxmf-3d`,
`wine-d3d12-verify.sh` — osservati con `ps`) ha scritto in `~/wine-d3dmetal/lib/`:
- 22:11: `libfreetype.dylib`, `libMoltenVK.dylib`;
- 22:12:41-43: set completo `libfreetype.6.dylib`, `libMoltenVK.dylib`, `libgnutls.30.dylib` + deps.

Io **non** ho scritto là: solo letture (`ls`/`find`/`stat`/`nm`/`strings`), nessun comando di
mutazione, nessun `gx`. Di conseguenza la tabella §1-bis ("wine-d3dmetal: 0 librerie") **non è più
vera** su questa macchina: quell'host ha ora le due patch **e** le 3 librerie → `canHostSteam == true`.
Non ho modificato i documenti (`docs/GX-DXMF.md` è del CEO/ORCH). Il test reale misura lo stato e
verifica la coerenza di `canHostSteam` con le librerie misurate, non un valore congelato.

### Cosa NON ho provato
- Nessuna esecuzione di Wine, nessun `gx`; nessuna scrittura in box/prefix, `~/WinePrefixes`,
  `~/wine-d3dmetal`, `~/Library/*`, cache game-x.
- Nessuna suite completa (`ctest`, `merge-verify`): sono del VALIDATOR.
- Non ho indagato *cosa* scriva l'altra lane in `~/wine-d3dmetal` (fuori dal mio scope/isolamento).
