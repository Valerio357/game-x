#!/usr/bin/env bash
# gx-dxmf acceptance sampler (ORCHESTRATOR helper, not product code).
#
# Usage: evidence/sample-modules.sh <out-dir> <process-regex> <stage-prefix> [seconds]
# Polls the process tree for a match, then records, for every matching pid:
#   - the command line,
#   - the modules loaded from <stage-prefix> (lsof, path-based proof),
#   - the loaded d3d11/dxgi images (any path) so a NATIVE module is visible too.
set -uo pipefail
OUT="$1"; RE="$2"; STAGE="$3"; SECS="${4:-90}"
mkdir -p "$OUT"
PS="$OUT/processes.txt"; LF="$OUT/lsof-stage.txt"; MOD="$OUT/modules.txt"
: > "$PS"; : > "$LF"; : > "$MOD"
deadline=$(( $(date +%s) + SECS ))
seen=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  for pid in $(pgrep -f "$RE" 2>/dev/null); do
    case " $seen " in *" $pid "*) continue ;; esac
    seen="$seen $pid"
    { echo "=== pid $pid  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      ps -p "$pid" -o pid,ppid,command= 2>/dev/null; } >> "$PS"
    lsof -p "$pid" 2>/dev/null | grep -F "$STAGE" >> "$LF"
    lsof -p "$pid" 2>/dev/null | grep -Ei 'd3d11|dxgi' >> "$MOD"
  done
  sleep 2
done
echo "--- sampler done: seen pids:$seen"
echo "--- stage matches: $(wc -l < "$LF" | tr -d ' ')"
cat "$LF"
echo "--- all d3d11/dxgi images:"
cat "$MOD"
