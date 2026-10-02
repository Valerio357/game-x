#!/usr/bin/env bash
#
# Build dello shim steamwebhelper per Game-X.
#
# Compila steamwebhelper_shim.c per le architetture usate da Steam
# (cef.win64 / cef.win7x64 -> 64-bit, cef.win7 -> 32-bit) e li copia accanto
# all'eseguibile reale nei prefix indicati, applicando chflags uchg.
#
# Requisiti: mingw-w64 (brew install mingw-w64)
#
# Uso:
#   scripts/build-steamwebhelper-shim.sh                 # build in dist/
#   scripts/build-steamwebhelper-shim.sh --install <prefix>
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Sources/GameXCore/Resources/steamwebhelper_shim.c"
OUT="$ROOT/dist"
CC64="${CC64:-x86_64-w64-mingw32-gcc}"
CC32="${CC32:-i686-w64-mingw32-gcc}"

die() { echo "error: $*" >&2; exit 1; }

command -v "$CC64" >/dev/null 2>&1 || die "manca $CC64 (brew install mingw-w64)"
command -v "$CC32" >/dev/null 2>&1 || die "manca $CC32 (brew install mingw-w64)"

mkdir -p "$OUT"
echo "==> Compilo shim 64-bit"
"$CC64" -O2 -o "$OUT/steamwebhelper_shim_x64.exe" "$SRC"
echo "==> Compilo shim 32-bit"
"$CC32" -O2 -o "$OUT/steamwebhelper_shim_x86.exe" "$SRC"

install_into_prefix() {
  local prefix="$1"
  local steam="$prefix/drive_c/Program Files (x86)/Steam"
  [ -d "$steam/bin/cef" ] || die "prefix senza Steam/bin/cef: $prefix"

  for d in cef.win64 cef.win7x64 cef.win7; do
    local dir="$steam/bin/cef/$d"
    [ -d "$dir" ] || continue
    chflags nouchg "$dir/steamwebhelper.exe" 2>/dev/null || true
    if [ ! -f "$dir/steamwebhelper_real.exe" ]; then
      mv "$dir/steamwebhelper.exe" "$dir/steamwebhelper_real.exe"
    fi
    if [ "$d" = "cef.win7" ]; then
      cp "$OUT/steamwebhelper_shim_x86.exe" "$dir/steamwebhelper.exe"
    else
      cp "$OUT/steamwebhelper_shim_x64.exe" "$dir/steamwebhelper.exe"
    fi
    chflags uchg "$dir/steamwebhelper.exe"
    echo "  installato: $dir/steamwebhelper.exe"
  done
}

if [ "${1:-}" = "--install" ]; then
  [ -n "${2:-}" ] || die "--install richiede il path del prefix"
  install_into_prefix "$2"
  echo "Fatto. Avvia Steam con: Steam.exe -no-cef-sandbox -forcedesktopscaling 1 -noverifyfiles"
else
  echo "Build completata in $OUT"
  echo "Per installare: $0 --install <WINEPREFIX>"
fi
