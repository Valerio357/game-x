#!/usr/bin/env bash
# gx-dxmf — raccolta dell'evidenza di accettazione (metà "module loading"), riproducibile.
#
# Produci tutto in evidence/acceptance/raw/ con i comandi esatti, in modo che ogni
# affermazione del README sia verificabile dai file grezzi. Rilievi chiusi (VAL2 §7):
# log committati, hash nell'evidenza, controllo negativo, pid legato al comando,
# provenienza dei box dichiarata.
#
# Sicurezza: box SOLO dentro una tmpdir mia, prefisso riservato `gxdxmf-*`.
# Nessuna scrittura in ~/WinePrefixes, ~/wine-d3dmetal, ~/Library/*.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/evidence/acceptance/raw"
STAGE="${GX_DXMF_STAGE:-$HOME/Workspace/dxmf/build/game-stage/wine}"
DEMO="$HOME/Workspace/dxmf/build/pe/bin/dxmf_demo.exe"
T="$(mktemp -d "${TMPDIR:-/tmp}/gxdxmf-acc-XXXXXX")"
export GX_PREFIX_ROOT="$T/boxes" GX_CACHE_ROOT="$T/cache" GX_LOGS_ROOT="$T/logs"
BIN="$ROOT/.build/release/gx"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/gx"

rm -rf "$OUT"; mkdir -p "$OUT"
CMDS="$OUT/00-commands.txt"
say() { echo "$*" | tee -a "$CMDS"; }

say "# Evidenza di accettazione gx-dxmf — comandi esatti"
say "# data: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "# host: $($HOME/wine-d3dmetal/bin/wine --version 2>&1)"
say "# stage: $STAGE"
say "# deps:  $HOME/x64deps"
say "# bin:   $BIN"
say "# tmpdir: $T   (box mie, prefisso riservato gxdxmf-*)"
say ""

say "## gx dxmf status   (host patchato + deps)"
say "\$ gx dxmf status"
GX_DXMF_STAGE="$STAGE" "$BIN" dxmf status >"$OUT/10-status.txt" 2>&1
cat "$OUT/10-status.txt" >>"$CMDS"; say ""

say "## gx dxmf status   con un host SENZA le due patch (Staging)"
say "\$ GX_DXMF_WINE_ROOT=/Applications/Wine\\ Staging.app/Contents/Resources/wine gx dxmf status; echo exit=\$?"
GX_DXMF_WINE_ROOT="/Applications/Wine Staging.app/Contents/Resources/wine" "$BIN" dxmf status \
  >"$OUT/11-status-staging.txt" 2>&1
STAG_EXIT=$?
echo "exit=$STAG_EXIT" >>"$OUT/11-status-staging.txt"
cat "$OUT/11-status-staging.txt" >>"$CMDS"; say ""

say "## l'inventario dei moduli, con gli sha256 (per la prova per CONTENUTO)"
say "\$ gx dxmf modules"
GX_DXMF_STAGE="$STAGE" "$BIN" dxmf modules >"$OUT/12-modules.txt" 2>&1
cat "$OUT/12-modules.txt" >>"$CMDS"; say ""

say "## box mia (tmpdir) col runtime dxmf"
say "\$ gx box create gxdxmf-acc --runtime dxmf"
GX_DXMF_STAGE="$STAGE" "$BIN" box create gxdxmf-acc --runtime dxmf >"$OUT/13-box-create.txt" 2>&1
cat "$OUT/13-box-create.txt" >>"$CMDS"; say ""

# ---------------------------------------------------------------- positiva
say "## PROVA POSITIVA: gx dxmf run con il contratto (--verbose per i marker dei moduli)"
say "\$ gx dxmf run gxdxmf-acc --verbose --winedebug '+d3d11,+dxgi' --max-log-mb 8 -- <demo>"
: >"$OUT/22-lsof-stage.txt"
( end=$(( $(date +%s) + 40 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    for pid in $(pgrep -f 'dxmf_demo' 2>/dev/null); do
      { echo "=== pid $pid   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        ps -p "$pid" -o pid,ppid,command= ; } >>"$OUT/21-process.txt"
      lsof -p "$pid" 2>/dev/null | grep -F "$STAGE" >>"$OUT/22-lsof-stage.txt"
    done
    sleep 1
  done ) &
SAMPLER=$!
GX_DXMF_STAGE="$STAGE" "$BIN" dxmf run gxdxmf-acc --verbose --winedebug "+d3d11,+dxgi" \
  --max-log-mb 8 -- "$DEMO" >"$OUT/20-run-positive.txt" 2>&1
POS_EXIT=$?
echo "exit=$POS_EXIT" >>"$OUT/20-run-positive.txt"
wait $SAMPLER 2>/dev/null
cat "$OUT/20-run-positive.txt" >>"$CMDS"; say ""

LOGPOS="$(sed -n 's/^log: //p' "$OUT/20-run-positive.txt" | tail -1)"
[ -n "$LOGPOS" ] && [ -f "$LOGPOS" ] && cp "$LOGPOS" "$OUT/23-log-positive.log"
grep -a -E '\[unix:(d3d11|dxgi)\] image=' "$OUT/23-log-positive.log" >"$OUT/24-load-markers.txt" 2>/dev/null
grep -a '\[demo\]' "$OUT/23-log-positive.log" | tail -3 >"$OUT/25-demo-verdict.txt" 2>/dev/null
say "## controllo per CONTENUTO: gli sha256 dei file mappati vs quelli dichiarati da gx dxmf modules"
: >"$OUT/26-hashes-mapped.txt"
awk '{print $NF}' "$OUT/22-lsof-stage.txt" | sort -u | while read -r f; do
  [ -f "$f" ] || continue
  printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f" >>"$OUT/26-hashes-mapped.txt"
done
cat "$OUT/26-hashes-mapped.txt" >>"$CMDS"
say ""

# ---------------------------------------------------------------- negativa
say "## CONTROLLO NEGATIVO: lo stesso demo, SENZA il contratto dxmf"
say "\$ WINEPREFIX=<box di questa tmpdir> wine <demo>   (niente WINEDLLPATH_PREPEND, niente override)"
: >"$OUT/32-negative-lsof-stage.txt"; : >"$OUT/31-negative-process.txt"
( end=$(( $(date +%s) + 25 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    for pid in $(pgrep -f 'dxmf_demo' 2>/dev/null); do
      { echo "=== pid $pid"; ps -p "$pid" -o pid,command= ; } >>"$OUT/31-negative-process.txt"
      lsof -p "$pid" 2>/dev/null | grep -F "$STAGE" >>"$OUT/32-negative-lsof-stage.txt"
      lsof -p "$pid" 2>/dev/null | grep -Ei 'd3d11|dxgi' >>"$OUT/33-negative-all-modules.txt"
    done
    sleep 1
  done ) &
SAMPLER2=$!
env -i PATH=/usr/bin:/bin HOME="$HOME" WINEPREFIX="$T/boxes/gxdxmf-neg" WINEARCH=win64 \
  "$HOME/wine-d3dmetal/bin/wine" "$DEMO" >"$OUT/34-negative-log.txt" 2>&1
NEG_EXIT=$?
echo "exit=$NEG_EXIT" >>"$OUT/34-negative-log.txt"
wait $SAMPLER2 2>/dev/null
{ echo "exit=$NEG_EXIT"
  echo "--- righe dello stage mappate (atteso 0): $(wc -l < "$OUT/32-negative-lsof-stage.txt" | tr -d ' ')"
  echo "--- ultime righe del log:"; tail -4 "$OUT/34-negative-log.txt"
  echo "--- dll native mappate:"; sort -u "$OUT/33-negative-all-modules.txt" | awk '{print "   " $NF}' | head -4
} >"$OUT/30-negative-control.txt"
cat "$OUT/30-negative-control.txt" >>"$CMDS"
say ""

say "## riepilogo"
say "- positiva: moduli mappati dal NOSTRO stage = $(sort -u "$OUT/22-lsof-stage.txt" | wc -l | tr -d ' ') righe, exit=$POS_EXIT"
say "- negativa: righe dello stage = $(wc -l < "$OUT/32-negative-lsof-stage.txt" | tr -d ' ') (atteso 0), exit del demo=$NEG_EXIT"
say "- tetto di log: vedi 'log cap' e 'truncated' in 20-run-positive.txt; il troncamento e' provato dal selftest (6 MB, cap 1 MB)"
echo "tmpdir lasciata: $T"
