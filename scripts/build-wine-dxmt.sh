#!/bin/bash
# Costruisce da zero il runtime **Game-X Wine+DXMT** (Wine 11.x x86_64 con le
# patch CodeWeavers + renderer DXMT) e lo installa in
#   ~/Library/Application Support/game-x/runtimes/wine-dxmt
#
#   ./scripts/build-wine-dxmt.sh [--jobs N] [--build DIR] [--keep]
#
# Tempo: ~40-60 min su M1/M4. Richiede: Xcode Command Line Tools, python3,
# bison e vulkan-headers (`brew install bison vulkan-headers`) e le dylib
# x86_64 di supporto (freetype/gnutls/MoltenVK): se non le trovi in
# $HOME/x64deps lo script prova a ricavarle da Wine Staging.app.
set -euo pipefail

WORK="$(cd "$(dirname "$0")/.." && pwd)"
WINE_VERSION="${WINE_VERSION:-11.10}"
DXMT_VERSION="${DXMT_VERSION:-0.80}"
MONO_VERSION="${MONO_VERSION:-11.1.0}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
BUILD="${BUILD:-$HOME/.cache/game-x-wine-build}"
RUN_ROOT="${RUN_ROOT:-$HOME/Library/Application Support/game-x/runtimes}"
DEPS="${DEPS:-$HOME/x64deps}"
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) JOBS="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --deps) DEPS="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "opzione sconosciuta: $1"; exit 2 ;;
    esac
done

STAGE="$RUN_ROOT/wine-dxmt"
mkdir -p "$BUILD" "$RUN_ROOT"
echo "== Game-X Wine+DXMT build =="
echo "   wine $WINE_VERSION · DXMT $DXMT_VERSION · mono $MONO_VERSION"
echo "   build:  $BUILD"
echo "   stage:  $STAGE"

# ---------------------------------------------------------------- prerequisiti
command -v clang >/dev/null || { echo "serve Xcode Command Line Tools"; exit 1; }
command -v python3 >/dev/null || { echo "serve python3"; exit 1; }
if ! command -v bison >/dev/null || [ "$(bison --version | head -1 | grep -oE '[0-9]+' | head -1)" -lt 3 ] 2>/dev/null; then
    echo "! serve bison >= 3 (brew install bison)"; exit 1
fi
[ -f /opt/homebrew/include/vulkan/vulkan.h ] || echo "! mancano gli header Vulkan (brew install vulkan-headers): Vulkan verrà saltato"

# ------------------------------------------------------- dylib x86_64 di appoggio
mkdir -p "$DEPS"
if [ -z "$(ls -A "$DEPS"/*.dylib 2>/dev/null || true)" ]; then
    WSLIB="/Applications/Wine Staging.app/Contents/Resources/wine/lib"
    if [ -d "$WSLIB" ]; then
        echo "== ricavo le dylib x86_64 da Wine Staging.app =="
        cp -RL "$WSLIB"/*.dylib "$DEPS/" 2>/dev/null || true
        ( cd "$DEPS" && for f in *.dylib; do
              install_name_tool -id "$DEPS/$f" "$f" 2>/dev/null || true
          done )
    else
        echo "! nessuna dylib in $DEPS e Wine Staging.app assente:"
        echo "  installa Wine Staging (https://github.com/Gcenx/macOS_Wine_builds) o passa --deps DIR"
        exit 1
    fi
fi
# libvulkan → MoltenVK (ANGLE/CEF lo richiede)
[ -e "$DEPS/libMoltenVK.dylib" ] && {
    ln -sf "$DEPS/libMoltenVK.dylib" "$DEPS/libvulkan.dylib"
    ln -sf "$DEPS/libMoltenVK.dylib" "$DEPS/libvulkan.1.dylib"
}

# pkg-config per le dipendenze (gli header sono arch-indipendenti)
PCDIR="$BUILD/pkgconfig"
mkdir -p "$PCDIR"
cat > "$PCDIR/freetype2.pc" <<EOF
prefix=$DEPS
libdir=\${prefix}
includedir=/opt/homebrew/include

Name: freetype2
Description: FreeType (x86_64)
Version: 2.13.0
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir} -I\${includedir}/freetype2
EOF
cat > "$PCDIR/gnutls.pc" <<EOF
prefix=$DEPS
libdir=\${prefix}
includedir=/opt/homebrew/include

Name: gnutls
Description: GnuTLS (x86_64)
Version: 3.8.0
Libs: -L\${libdir} -lgnutls
Cflags: -I\${includedir}
EOF
cat > "$PCDIR/vulkan.pc" <<EOF
prefix=$DEPS
libdir=\${prefix}
includedir=/opt/homebrew/include

Name: vulkan
Description: Vulkan via MoltenVK (x86_64)
Version: 1.3.0
Libs: -L\${libdir} -lvulkan
Cflags: -I\${includedir}
EOF
cp "$PCDIR/vulkan.pc" "$PCDIR/MoltenVK.pc"
sed -i '' 's/^Name: vulkan/Name: MoltenVK/' "$PCDIR/MoltenVK.pc" 2>/dev/null || true

# ------------------------------------------------------------------ sorgente wine
SRC="$BUILD/wine-$WINE_VERSION"
if [ ! -d "$SRC" ]; then
    TAR="$BUILD/wine-$WINE_VERSION.tar.xz"
    [ -f "$TAR" ] || {
        echo "== scarico Wine $WINE_VERSION =="
        curl -L --fail -o "$TAR" "https://dl.winehq.org/wine/source/11.x/wine-$WINE_VERSION.tar.xz"
    }
    echo "== estraggo =="
    tar -xf "$TAR" -C "$BUILD"
fi

echo "== applico le patch (CW HACK 22435 + winemetal) =="
cd "$SRC"
for p in "$WORK"/Patches/*.patch; do
    if git apply --check "$p" 2>/dev/null; then
        git apply "$p" && echo "   applicata $(basename "$p")"
    elif patch -p1 --dry-run -s -f --fuzz=3 < "$p" >/dev/null 2>&1; then
        patch -p1 -s -f --fuzz=3 < "$p" && echo "   applicata (fuzz) $(basename "$p")"
    else
        echo "   (già applicata?) $(basename "$p")"
    fi
done

# ------------------------------------------------------------------- compilazione
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="$PCDIR:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"
export LDFLAGS="-L$DEPS"          # il test -lvulkan non usa il nostro -L da .pc
export CPPFLAGS="-I/opt/homebrew/include"

echo "== configure =="
./configure --prefix="$STAGE/wine" \
    --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 --disable-tests \
    CC="clang -arch x86_64" CXX="clang++ -arch x86_64" OBJC="clang -arch x86_64" \
    --without-x --without-cups --without-dbus --without-sane \
    --without-v4l2 --without-gphoto --without-oss \
    > "$BUILD/configure.log" 2>&1 || { tail -20 "$BUILD/configure.log"; exit 1; }
grep -E "checking for -l(freetype|gnutls|MoltenVK)" "$BUILD/configure.log" | sed 's/^/   /'

echo "== make -j$JOBS (lungo: ~40 min) =="
make -j"$JOBS" > "$BUILD/make.log" 2>&1 || { tail -30 "$BUILD/make.log"; exit 1; }

echo "== make install =="
make install > "$BUILD/install.log" 2>&1 || { tail -20 "$BUILD/install.log"; exit 1; }

# ------------------------------------------------------------------------- DXMT
echo "== installo DXMT $DXMT_VERSION =="
DXMT_TAR="$BUILD/dxmt-v$DXMT_VERSION-builtin.tar.gz"
[ -f "$DXMT_TAR" ] || curl -L --fail -o "$DXMT_TAR" \
    "https://github.com/3Shain/dxmt/releases/download/v$DXMT_VERSION/dxmt-v$DXMT_VERSION-builtin.tar.gz"
rm -rf "$STAGE/renderers"; mkdir -p "$STAGE/renderers/dxmt"
TMPD="$BUILD/dxmt-extract"; rm -rf "$TMPD"; mkdir -p "$TMPD"
tar -xf "$DXMT_TAR" -C "$TMPD"
if [ -d "$TMPD/wine" ]; then
    cp -R "$TMPD/wine" "$STAGE/renderers/dxmt/wine"
else
    # l'archivio può contenere la cartella x86_64-windows/x86_64-unix diretta
    mkdir -p "$STAGE/renderers/dxmt/wine"
    cp -R "$TMPD"/* "$STAGE/renderers/dxmt/wine/" 2>/dev/null || true
fi
for f in ntdll.so winemac.so; do
    [ -e "$STAGE/wine/lib/wine/x86_64-unix/$f" ] && \
        ln -sf "$STAGE/wine/lib/wine/x86_64-unix/$f" "$STAGE/renderers/dxmt/wine/x86_64-unix/$f"
done

# ------------------------------------------------------------------------ mono
echo "== wine-mono $MONO_VERSION =="
mkdir -p "$STAGE/wine/share/wine/mono"
MSI="$STAGE/wine/share/wine/mono/wine-mono-$MONO_VERSION-x86.msi"
[ -f "$MSI" ] || curl -L --fail -o "$MSI" \
    "https://dl.winehq.org/wine/wine-mono/$MONO_VERSION/wine-mono-$MONO_VERSION-x86.msi"

# --------------------------------------------------------------------- deps+manifesto
if [ -d "$DEPS" ]; then
    mkdir -p "$STAGE/x64deps"; cp -RL "$DEPS"/*.dylib "$STAGE/x64deps/" 2>/dev/null || true
fi
cat > "$STAGE/manifest.json" <<EOF
{
  "name": "wine-dxmt",
  "wineVersion": "wine-$WINE_VERSION",
  "dxmtVersion": "$DXMT_VERSION",
  "monoVersion": "$MONO_VERSION",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo
echo "== FATTO =="
"$STAGE/wine/bin/wine" --version
echo "runtime: $STAGE"
echo "verifica: gx runtime status"
[ "$KEEP" = "0" ] && echo "(sorgenti in $SRC, log in $BUILD)"
