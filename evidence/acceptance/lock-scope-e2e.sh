#!/usr/bin/env bash
# gx-dxmf — prova end-to-end della SEQUENZA REALE (difetto del 2026-10-15):
#
#     Steam VIVO  +  gioco lanciato nella STESSA box
#
# Il difetto: `gx dxmf run` teneva il lock per tutta la vita del processo, quindi il
# secondo comando era rifiutato ("box X is locked by pid ...") e la sequenza era
# impossibile. Qui si prova, con il CLI vero: (1) due run insieme passano, (2) un run
# NON lascia il lock, (3) una box IN USO non si ricrea/rimuove senza --force,
# (4) una mutazione in corso rifiuta il lancio.
#
# Tutto in una tmpdir mia, prefisso `gxdxmf-*`, con un host Wine FINTO: nessuna box di
# altri toccata, nessun gioco, nessun download, nessun Wine vero eseguito.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/.build/release/gx"; [ -x "$BIN" ] || BIN="$ROOT/.build/debug/gx"
T="$(mktemp -d "${TMPDIR:-/tmp}/gxdxmf-locke2e-XXXXXX")"
export GX_PREFIX_ROOT="$T/boxes" GX_CACHE_ROOT="$T/cache" GX_LOGS_ROOT="$T/logs"
FAIL=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# ---- host Wine finto: risponde a --version, ignora wineboot/reg, esegue il resto
HOST="$T/host"; mkdir -p "$HOST/bin" "$HOST/lib/wine/x86_64-unix"
cat > "$HOST/bin/wine" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo "wine-11.10"; exit 0 ;;
  wineboot|reg|wineserver) exit 0 ;;
esac
exec "$@"
SH
chmod +x "$HOST/bin/wine"
# i due marker delle patch CodeWeavers (la probe li legge con strings/nm)
printf 'WINEDLLPATH_PREPEND\n' > "$HOST/lib/wine/x86_64-unix/ntdll.so"
printf 'macdrv_functions\n'   > "$HOST/lib/wine/x86_64-unix/winemac.so"
# stage dei moduli (i PE servono anche a far esistere le coppie)
mkdir -p "$HOST/lib/wine/x86_64-windows"
STAGE="$T/stage/wine"; mkdir -p "$STAGE/x86_64-windows" "$STAGE/x86_64-unix"
for m in d3d11 dxgi; do : > "$STAGE/x86_64-windows/$m.dll"; : > "$STAGE/x86_64-unix/$m.so"; done
export GX_DXMF_WINE_ROOT="$HOST" GX_DXMF_STAGE="$STAGE"

echo "== setup (tmpdir mia, host finto): $T"
"$BIN" dxmf status 2>&1 | sed -n '2,4p'

echo
echo "== 1) la box col runtime dxmf"
"$BIN" box create gxdxmf-lockbox --runtime dxmf >/dev/null 2>&1 && ok "box creata" || bad "box create"

echo
echo "== 2) 'Steam' vivo (run di lunga vita) e 'gioco' lanciato INSIEME"
"$BIN" dxmf run gxdxmf-lockbox -- /bin/sleep 12 >"$T/steam.out" 2>&1 &
STEAM=$!
sleep 2
if [ -z "$(ls -A "$T/cache/locks" 2>/dev/null)" ]; then
  ok "nessun lock tenuto durante il run di lunga vita"
else
  bad "un run tiene ancora il lock: $(ls "$T/cache/locks")"
fi

"$BIN" dxmf run gxdxmf-lockbox -- /bin/echo GIOCO-PARTITO >"$T/game.out" 2>&1
GAME_EXIT=$?
GAME_LOG="$(sed -n 's/^log: //p' "$T/game.out" | tail -1)"
if [ "$GAME_EXIT" = 0 ] && [ -n "$GAME_LOG" ] && grep -q GIOCO-PARTITO "$GAME_LOG"; then
  ok "il SECONDO run passa mentre il primo e' vivo (la sequenza Steam+gioco e' possibile)"
else
  bad "il secondo run non e' andato a buon fine (exit=$GAME_EXIT, log=${GAME_LOG:-?})"
fi
if grep -qi "is locked by" "$T/game.out"; then bad "rifiuto da lock: $(grep -i 'is locked by' "$T/game.out")"; fi

echo
echo "== 3) valvola di sfogo: --no-lock non fallisce"
"$BIN" dxmf run gxdxmf-lockbox --no-lock -- /bin/echo OK >"$T/nolock.out" 2>&1 \
  && ok "--no-lock accettato" || bad "--no-lock rifiutato"

echo
echo "== 4) la box IN USO non si ricrea/rimuove senza --force (il caso 11,57 GB)"
U=$(id -u); BOX="$T/boxes/gxdxmf-lockbox"
SOCK="/tmp/.wine-$U/server-$(printf '%x' "$(stat -f '%d' "$BOX")")-$(printf '%x' "$(stat -f '%i' "$BOX")")"
mkdir -p "$SOCK"; : > "$SOCK/socket"          # simula il wineserver vivo di quella box
"$BIN" box remove gxdxmf-lockbox --yes >"$T/rm.out" 2>&1
if grep -qi "is in use" "$T/rm.out"; then ok "remove RIFIUTATO, nominando il socket"; else bad "remove non protetto: $(tail -1 "$T/rm.out")"; fi
"$BIN" box remove gxdxmf-lockbox --yes --force >"$T/rmf.out" 2>&1 \
  && ok "--force procede dichiarandolo" || bad "--force non procede"
rm -rf "$SOCK"

echo
echo "== 5) una MUTAZIONE in corso rifiuta il lancio (l'altra direzione)"
"$BIN" box create gxdxmf-mutbox --runtime dxmf >/dev/null 2>&1
# Lock tenuto da un pid VIVO (lo shell di questo script): un pid morto sarebbe "stantio".
mkdir -p "$T/cache/locks"
python3 -c '
import json, sys, time
json.dump({"pid": int(sys.argv[2]), "box": "gxdxmf-mutbox",
           "command": "gx steam install gxdxmf-mutbox", "reason": "install",
           "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
          open(sys.argv[1], "w"))
' "$T/cache/locks/gxdxmf-mutbox.lock" "$$"
"$BIN" dxmf run gxdxmf-mutbox -- /bin/echo X >"$T/blocked.out" 2>&1
if grep -qi "locked by" "$T/blocked.out"; then
  ok "il lancio e' RIFIUTATO se una mutazione e' in corso"
else
  bad "il lancio non e' stato fermato: $(tail -1 "$T/blocked.out")"
fi
"$BIN" dxmf run gxdxmf-mutbox --no-lock -- /bin/echo Y >"$T/forced.out" 2>&1 \
  && ok "--no-lock prosegue dichiarandolo" || bad "--no-lock non prosegue"

wait "$STEAM" 2>/dev/null
echo
echo "================================================================"
if [ "$FAIL" = 0 ]; then
  echo "VERDICT: PASS — la sequenza Steam+gioco e' possibile; il lock protegge le mutazioni"
else
  echo "VERDICT: FAIL — $FAIL controlli rossi"
fi
echo "log in: $T"
