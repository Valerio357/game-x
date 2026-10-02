#!/usr/bin/env bash
#
# Builds the self-contained **wine-gptk** runtime for Game-X:
#
#   <runtimes>/<name>/
#     bin/wine                                  Wine built from CodeWeavers public sources
#     lib/wine/x86_64-{unix,windows}/…          D3DMetal (d3d11, dxgi, d3d12, nvapi64, nvngx)
#     lib/external/{D3DMetal.framework,libd3dshared.dylib}   (from Apple's Game Porting Toolkit)
#     x64deps/…                                 MoltenVK, freetype, SDL2 …
#     share/wine/mono/wine-mono-*.msi           (optional)
#     manifest.json
#
# Why a CodeWeavers Wine (not upstream Wine). Apple's D3DMetal glue calls Mach-O
# functions directly from PE code (fast path `gGFXTDispatch+0x150` in
# `dxgi.dll!Thunk_Thread`): that code uses libc, so `%gs` must be the macOS TSD.
# Upstream Wine puts the Windows TEB in `%gs` → the first libc call
# (`pthread_setname_np("D3DMetalWineThread")`) page-faults on 0x0. CodeWeavers Wine
# uses the TEB-in-TSD scheme (no `_thread_set_tsd_base`).
#
# Usage:
#   scripts/build-runtime-gptk.sh [--wine-root DIR] [--gptk-dmg FILE | --redist DIR]
#                                 [--name NAME] [--x64deps DIR] [--dry-run]
#
# D3DMetal source (one of):
#   --gptk-dmg FILE   Apple's "Evaluation environment for Windows games" DMG.
#                     If omitted we look in ~/Downloads automatically.
#   --redist DIR      a folder containing `external/` and `wine/` (advanced).
#
# Defaults:
#   --wine-root  ~/wine-cx   (a CodeWeavers Wine build; `gx runtime build-gptk`
#                             downloads it automatically when missing)
#
set -euo pipefail

WINE_ROOT="${HOME}/wine-cx"
GPTK_DMG=""
REDIST_ARG=""
NAME="wine-gptk"
X64DEPS="${HOME}/x64deps"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wine-root) WINE_ROOT="$2"; shift 2 ;;
    --gptk-dmg)  GPTK_DMG="$2"; shift 2 ;;
    --redist)    REDIST_ARG="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --x64deps)   X64DEPS="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    -h|--help)   sed -n '2,34p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# --- D3DMetal redist resolution ---------------------------------------------
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  [ -n "$MOUNT" ] && rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

if [ -n "$REDIST_ARG" ]; then
  REDIST="$REDIST_ARG"
else
  if [ -z "$GPTK_DMG" ]; then
    GPTK_DMG="$(ls -t "${HOME}/Downloads/"Evaluation_environment_for_Windows_games_*.dmg 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$GPTK_DMG" ] || [ ! -e "$GPTK_DMG" ]; then
    echo "ERROR: D3DMetal source not found."
    echo "  Download Apple's Game Porting Toolkit 4 DMG (\"Evaluation environment for"
    echo "  Windows games\") from developer.apple.com, then run:"
    echo "    gx runtime build-gptk --gptk-dmg <file.dmg>"
    exit 1
  fi
  MOUNT="$(mktemp -d)"
  echo "==> mounting $(basename "$GPTK_DMG")"
  hdiutil attach "$GPTK_DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
  REDIST="${MOUNT}/redist/lib"
fi

RUNTIMES="${GX_RUNTIMES_ROOT:-${HOME}/Library/Application Support/game-x/runtimes}"
DST="${RUNTIMES}/${NAME}"

[ -x "${WINE_ROOT}/bin/wine" ] || {
  echo "ERROR: ${WINE_ROOT}/bin/wine not found."
  echo "  A Wine built from CodeWeavers public sources is required (TEB-in-TSD scheme)."
  echo "  gx runtime build-gptk downloads it automatically, or pass --wine-root <dir>."
  exit 1
}
[ -d "${REDIST}/external" ] || {
  echo "ERROR: D3DMetal redist not found in ${REDIST}"
  echo "  Download Apple's Game Porting Toolkit 4 DMG, then:"
  echo "    gx runtime build-gptk --gptk-dmg <file.dmg>"
  exit 1
}

echo "==> sources"
echo "    wine     : ${WINE_ROOT}  ($("${WINE_ROOT}/bin/wine" --version 2>/dev/null || echo '?'))"
echo "    redist   : ${REDIST}"
echo "    runtime  : ${DST}"

if [ "$DRY" = 1 ]; then echo "(dry-run)"; exit 0; fi

echo "==> 1/6 cloning the runtime (APFS clonefile, instant)"
mkdir -p "$RUNTIMES"
rm -rf "$DST"
if ! cp -c -R "$WINE_ROOT" "$DST" 2>/dev/null; then
  cp -R "$WINE_ROOT" "$DST"           # filesystem without clonefile
fi

echo "==> 2/6 installing the D3DMetal redist"
rm -rf "${DST}/lib/external"; mkdir -p "${DST}/lib/external"
cp -a "${REDIST}/external/." "${DST}/lib/external/"
cp -a "${REDIST}/wine/x86_64-unix/." "${DST}/lib/wine/x86_64-unix/"
cp -a "${REDIST}/wine/x86_64-windows/." "${DST}/lib/wine/x86_64-windows/"

echo "==> 3/6 d3d10 sanity check"
SHARED_MD5="$(md5 -q "${DST}/lib/external/libd3dshared.dylib" 2>/dev/null || echo x)"
for arch in x86_64-windows x86_64-unix; do
  for ext in dll so; do
    f="${DST}/lib/wine/${arch}/d3d10.${ext}"
    [ -e "$f" ] || continue
    if [ "$(md5 -q "$f" 2>/dev/null || echo y)" = "$SHARED_MD5" ]; then
      # it is just a copy of libd3dshared (old layout) → restore Wine's own d3d10
      src="${WINE_ROOT}/lib/wine/${arch}/d3d10.${ext}"
      if [ -e "$src" ]; then cp -f "$src" "$f"; echo "    restored Wine's d3d10.${ext}"; fi
    fi
  done
done

echo "==> 4/6 dependencies (x64deps) and wine-mono"
if [ -d "$X64DEPS" ] && [ ! -d "${DST}/x64deps" ]; then
  cp -c -R "$X64DEPS" "${DST}/x64deps" 2>/dev/null || cp -R "$X64DEPS" "${DST}/x64deps"
fi
mkdir -p "${DST}/share/wine/mono"
for msi in "${HOME}/.cache/wine/wine-mono-"*.msi; do
  [ -e "$msi" ] && cp -f "$msi" "${DST}/share/wine/mono/" || true
done

echo "==> 5/6 quarantine/provenance"
for d in "${DST}/lib/external" "${DST}/lib/wine/x86_64-unix" "${DST}/lib/wine/x86_64-windows"; do
  xattr -dr com.apple.quarantine "$d" 2>/dev/null || true
  xattr -dr com.apple.provenance  "$d" 2>/dev/null || true
done

echo "==> 6/6 manifest + verify"
VERSION="$("${DST}/bin/wine" --version 2>/dev/null || echo 'unknown')"
D3DM_VERSION="$(plutil -extract CFBundleShortVersionString raw "${DST}/lib/external/D3DMetal.framework/Versions/A/Resources/version.plist" 2>/dev/null || echo '?')"
MONO="$(basename "$(ls "${DST}/share/wine/mono/"wine-mono-*.msi 2>/dev/null | head -1)" 2>/dev/null || echo '')"

# Detected features (read by `gx doctor`: without SDL2 the controller does not work).
feat_bool() { if "$@"; then echo true; else echo false; fi; }
SDL2=$(feat_bool bash -c "[ -e '${DST}/x64deps/libSDL2.dylib' ] || [ -e '${DST}/x64deps/libSDL2-2.0.0.dylib' ] || strings '${DST}/lib/wine/x86_64-unix/winebus.so' 2>/dev/null | grep -q libSDL2")
VULKAN=$(feat_bool bash -c "[ -e '${DST}/x64deps/libvulkan.dylib' ] || [ -e '${DST}/x64deps/libMoltenVK.dylib' ]")
MONO_FEAT=$(feat_bool bash -c "ls '${DST}/share/wine/mono/'wine-mono-*.msi >/dev/null 2>&1")
cat > "${DST}/manifest.json" <<JSON
{
  "name": "${NAME}",
  "wineVersion": "${VERSION}",
  "d3dmetalVersion": "${D3DM_VERSION}",
  "mono": "${MONO}",
  "features": { "sdl2": ${SDL2}, "vulkan": ${VULKAN}, "mono": ${MONO_FEAT} },
  "source": "Apple Game Porting Toolkit redist + CodeWeavers public Wine sources",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

fail=0
for f in bin/wine lib/external/D3DMetal.framework lib/external/libd3dshared.dylib \
         lib/wine/x86_64-windows/d3d11.dll lib/wine/x86_64-unix/d3d11.so; do
  [ -e "${DST}/${f}" ] || { echo "   MISSING ${f}"; fail=1; }
done
echo "   wine ${VERSION} · D3DMetal ${D3DM_VERSION}"
if [ "$fail" = 0 ]; then
  echo "==> OK: runtime '${NAME}' ready"
else
  echo "==> ERROR: incomplete runtime"; exit 1
fi
echo
echo "Quick check:"
echo "  gx runtime list"
echo "  gx box exec <box> --runtime ${NAME} -- C:/d3dvis.exe 20"
