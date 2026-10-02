#!/bin/bash
# Crea un runtime Game-X Wine+DXMT **auto-consistente** (una cartella che si
# può copiare su un'altra macchina e passare a un amico) e la impacchetta in
# un .tar.xz con manifesto e sha256.
#
#   ./scripts/package-runtime.sh [--out DIR] [--source DIR] [--no-deps]
#
# Default: prende la build corrente da $HOME/wine-d3dmetal, il renderer DXMT
# da ~/Workspace/d3dmetal-wine/renderers/dxmt/wine e le dylib da ~/x64deps.
#
# Il pacchetto risultante si installa con:
#   gx runtime install --tar game-x-wine-dxmt-<ver>.tar.xz --sha256 <hash>
set -euo pipefail

WORK="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$WORK/dist"
WINE_SRC="${WINE_SRC:-$HOME/wine-d3dmetal}"
RENDERER_SRC="${RENDERER_SRC:-$HOME/Workspace/d3dmetal-wine/renderers/dxmt/wine}"
DEPS_SRC="${DEPS_SRC:-$HOME/x64deps}"
VERSION="${VERSION:-11.10}"
DXMT_VERSION="${DXMT_VERSION:-0.80}"
MONO_VERSION="${MONO_VERSION:-11.1.0}"
WITH_DEPS=1

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --wine) WINE_SRC="$2"; shift 2 ;;
        --renderer) RENDERER_SRC="$2"; shift 2 ;;
        --deps) DEPS_SRC="$2"; shift 2 ;;
        --no-deps) WITH_DEPS=0; shift ;;
        *) echo "opzione sconosciuta: $1"; exit 2 ;;
    esac
done

STAGE="$OUT/wine-dxmt"
PKG="$OUT/game-x-wine-dxmt-$VERSION-macos-x86_64.tar.xz"

echo "== 1. copio l'installazione Wine =="
[ -x "$WINE_SRC/bin/wine" ] || { echo "Wine non trovato in $WINE_SRC"; exit 1; }
rm -rf "$STAGE"; mkdir -p "$STAGE"
# bin, lib, share/wine (font+mono). Lo scripting di Wine non serve a giocare.
for d in bin lib; do
    [ -d "$WINE_SRC/$d" ] && cp -R "$WINE_SRC/$d" "$STAGE/"
done
mkdir -p "$STAGE/share"
# share/wine completo: fonts, nls, mono, wine.inf… (senza nls Wine non parte)
[ -d "$WINE_SRC/share/wine" ] && cp -R "$WINE_SRC/share/wine" "$STAGE/share/"

echo "== 2. copio il renderer DXMT =="
[ -f "$RENDERER_SRC/x86_64-windows/d3d11.dll" ] || { echo "DXMT non trovato in $RENDERER_SRC"; exit 1; }
mkdir -p "$STAGE/renderers/dxmt"
cp -R "$RENDERER_SRC" "$STAGE/renderers/dxmt/wine"

echo "== 3. dylib di supporto (freetype/gnutls/MoltenVK) =="
if [ "$WITH_DEPS" = "1" ] && [ -d "$DEPS_SRC" ]; then
    mkdir -p "$STAGE/x64deps"
    cp -RL "$DEPS_SRC"/*.dylib "$STAGE/x64deps/" 2>/dev/null || true
    echo "   $(ls "$STAGE/x64deps" | wc -l | tr -d ' ') dylib"
fi

echo "== 4. symlink winemetal (ntdll.so / winemac.so) =="
# winemetal.so ha LC_RPATH=@loader_path/ e cerca ntdll.so/winemac.so accanto a sé.
# Il symlink deve risolvere allo STESSO file che Wine carica dal proprio lib/wine,
# altrimenti dyld carica due winemac.so e le classi ObjC duplicate fanno crashare.
for f in ntdll.so winemac.so; do
    t="$STAGE/lib/wine/x86_64-unix/$f"
    # da <stage>/renderers/dxmt/wine/x86_64-unix → <stage>/lib/wine/x86_64-unix
    [ -e "$t" ] && ln -sf "../../../../lib/wine/x86_64-unix/$f" "$STAGE/renderers/dxmt/wine/x86_64-unix/$f" || true
done
python3 - "$STAGE" <<'PY2'
import os, sys
stage = sys.argv[1]
for f in ("ntdll.so", "winemac.so"):
    a = os.path.realpath(os.path.join(stage, "renderers/dxmt/wine/x86_64-unix", f))
    b = os.path.realpath(os.path.join(stage, "lib/wine/x86_64-unix", f))
    print(f"   {f}: allineato={'sì' if a == b else 'NO'}")
PY2

echo "== 4b. rimuovo i simboli di debug (build di Wine ~-60%) =="
if command -v x86_64-w64-mingw32-strip >/dev/null; then
    n=0
    while IFS= read -r f; do
        x86_64-w64-mingw32-strip --strip-debug "$f" 2>/dev/null && n=$((n+1))
    done < <(find "$STAGE" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.so' -o -name '*.sys' -o -name '*.drv' \) 2>/dev/null)
    echo "   $n file PE"
else
    echo "   (mingw-w64 assente: PE non strippati — brew install mingw-w64 per dimezzare il pacchetto)"
fi
/usr/bin/find "$STAGE" -name '*.dylib' -o -name 'wine' -o -name 'wineserver' 2>/dev/null | while read -r f; do
    /usr/bin/strip -S "$f" 2>/dev/null || true
done


echo "== 5. rendo le dylib **rilocabili** (@loader_path) =="
# Le .so di Wine sono linkate con percorsi assoluti verso x64deps: riscriviamo
# ogni dipendenza che puntava a una dylib del runtime.
python3 - "$STAGE" <<'PY'
import os, subprocess, sys
stage = sys.argv[1]
changed = 0
for root, _dirs, files in os.walk(stage):
    for fn in files:
        p = os.path.join(root, fn)
        try:
            with open(p, 'rb') as fh:
                if fh.read(4) not in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
                    continue
        except OSError:
            continue
        out = subprocess.run(['/usr/bin/otool','-L',p], capture_output=True, text=True).stdout
        for line in out.splitlines()[1:]:
            dep = line.strip().split(' (')[0]
            if '/x64deps/' not in dep:
                continue
            leaf = os.path.basename(dep)
            # percorso relativo da questa cartella a <stage>/x64deps
            rel = os.path.relpath(os.path.join(stage, 'x64deps', leaf), root)
            new = '@loader_path/' + rel
            r = subprocess.run(['/usr/bin/install_name_tool','-change',dep,new,p],
                               capture_output=True, text=True)
            if r.returncode == 0:
                changed += 1
        # l'id deve essere rilocabile per le dylib
        if p.endswith('.dylib'):
            idn = subprocess.run(['/usr/bin/otool','-D',p], capture_output=True, text=True).stdout
            idl = idn.strip().splitlines()
            if len(idl) > 1 and '/x64deps/' in idl[1]:
                leaf = os.path.basename(idl[1].strip())
                subprocess.run(['/usr/bin/install_name_tool','-id',
                                '@loader_path/'+leaf,p], capture_output=True)
                changed += 1
print(f"   {changed} dipendenze riscritte")
PY

echo "== 6. manifesto =="
cat > "$STAGE/manifest.json" <<EOF
{
  "name": "wine-dxmt",
  "wineVersion": "wine-$VERSION",
  "dxmtVersion": "$DXMT_VERSION",
  "monoVersion": "$MONO_VERSION",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "== 7. impacchetto =="
mkdir -p "$OUT"
rm -f "$PKG"
export XZ_OPT="-T0 -6"           # multi-thread: molto più veloce su x86_64 di grandi dimensioni
( cd "$STAGE" && tar -cJf "$PKG" . ) 2>/dev/null || ( cd "$OUT" && tar -cJf "$PKG" wine-dxmt )
SIZE=$(stat -f%z "$PKG")
SHA=$(shasum -a 256 "$PKG" | awk '{print $1}')
echo
echo "OK  $PKG"
echo "    dimensione: $(printf '%.1f' "$(echo "$SIZE/1048576" | bc -l)") MB"
echo "    sha256:     $SHA"
echo
echo "Su un'altra macchina:"
echo "  gx runtime install --tar $(basename "$PKG") --sha256 $SHA"
