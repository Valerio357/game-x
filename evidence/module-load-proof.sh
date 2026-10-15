#!/usr/bin/env bash
# gx-dxmf — prova NON giocata che i moduli CARICATI sono i nostri (module-loading half).
#
# Usa un box DI MIA PROPRIETA' in una tmpdir (prefisso riservato gxdxmf-*), il carico
# SINTETICO `dxmf_demo.exe` (non un gioco, nessun download) e l'host patchato
# `~/wine-d3dmetal` + le dylib di supporto `~/x64deps`.
# Non tocca nessuna box esistente: non `box create/remove`, non Steam, non deps.
set -uo pipefail

WINE="${WINE:-$HOME/wine-d3dmetal/bin/wine}"
STAGE="${GX_DXMF_STAGE:-$HOME/Workspace/dxmf/build/game-stage/wine}"
DEPS="${GX_DXMF_DEPS:-$HOME/x64deps}"
DEMO="${DEMO:-$HOME/Workspace/dxmf/build/pe/bin/dxmf_demo.exe}"
OUT="${1:-$(cd "$(dirname "$0")" && pwd)/module-load-proof}"
SECS="${2:-30}"

mkdir -p "$OUT"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/gxdxmf-probe-XXXXXX")"
PREFIX="$WORK/boxes/gxdxmf-probe"
mkdir -p "$PREFIX"

echo "== host  : $WINE -> $("$WINE" --version 2>&1)"
echo "== stage : $STAGE"
echo "== deps  : $DEPS"
echo "== demo  : $DEMO"
echo "== box   : $PREFIX   (tmpdir mia, prefisso riservato gxdxmf-)"

echo "== wineboot -u (solo il MIO box temporaneo)"
WINEPREFIX="$PREFIX" WINEARCH=win64 WINEDEBUG=-all \
  "$WINE" wineboot -u >"$OUT/wineboot.log" 2>&1
echo "   exit=$?"

echo "== lancio il demo con il contratto d'ambiente dxmf"
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" \
  WINEPREFIX="$PREFIX" \
  WINEDLLPATH_PREPEND="$STAGE" \
  WINEDLLOVERRIDES="d3d9,d3d11,dxgi=b" \
  DYLD_LIBRARY_PATH="$DEPS" \
  WINEDEBUG=-all \
  "$WINE" "$DEMO" >"$OUT/demo.log" 2>&1 &
DEMO_JOB=$!

: >"$OUT/lsof-stage.txt"; : >"$OUT/modules.txt"; : >"$OUT/processes.txt"
end=$(( $(date +%s) + SECS ))
seen=""
while [ "$(date +%s)" -lt "$end" ]; do
  for pid in $(pgrep -f 'dxmf_demo' 2>/dev/null); do
    case " $seen " in *" $pid "*) ;; *) seen="$seen $pid"
      { echo "=== pid $pid   $(date -u +%Y-%m-%dT%H:%M:%SZ)"; ps -p "$pid" -o pid,ppid,command=; } >>"$OUT/processes.txt"
      ;;
    esac
    # OGNI secondo, non una volta sola: il modulo compare solo dopo il load.
    lsof -p "$pid" 2>/dev/null | grep -F "$STAGE" >>"$OUT/lsof-stage.txt"
    lsof -p "$pid" 2>/dev/null | grep -Ei 'd3d11|dxgi' >>"$OUT/modules.txt"
  done
  sleep 1
done

echo "== fermo SOLO i processi di questo box temporaneo"
pkill -f "$(basename "$DEMO")" 2>/dev/null
WINEPREFIX="$PREFIX" "$(dirname "$WINE")/wineserver" -k 2>/dev/null
sleep 1

echo
echo "############ ESITO"
echo "-- pid visti:"; cat "$OUT/processes.txt"
echo "-- moduli dal NOSTRO stage (lsof, path):"; sort -u "$OUT/lsof-stage.txt" | sed 's/^/   /'
echo "-- tutti i d3d11/dxgi mappati:"; sort -u "$OUT/modules.txt" | sed 's/^/   /'
n=$(sort -u "$OUT/lsof-stage.txt" | wc -l | tr -d ' ')
if [ "$n" -ge 2 ]; then echo "VERDICT: PASS — $n moduli (PE+unix) dal nostro stage sono mappati nel processo"; else echo "VERDICT: FAIL/indeterminato — $n righe"; fi
echo "-- log del demo (ultime righe):"; tail -15 "$OUT/demo.log"
echo "-- work dir lasciata per ispezione: $WORK"
