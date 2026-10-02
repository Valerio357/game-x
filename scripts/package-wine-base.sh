#!/usr/bin/env bash
#
# Impacchetta una **base Wine rilocabile** per il runtime `wine-gptk`:
#   wine-cx/            (Wine dai sorgenti CodeWeavers: schema TEB-in-TSD)
#   wine-cx/x64deps/    (MoltenVK, freetype, **SDL2**, … per il controller)
#
# NON include D3DMetal (non ridistribuibile): quello lo innesta
# `gx runtime build-gptk` dai file Apple GPTK dell'utente. Lo stripping degli
# artefatti Apple è applicato qui ed è verificato (fallisce se ne resta qualcuno).
#
# Include la licenza di Wine (`LICENSE` + `COPYING.LIB`, LGPL-2.1-or-later) e un
# file `NOTICE` con l'elenco dei componenti di terze parti (conformità LGPL).
#
# Le dipendenze con percorsi assoluti verso `~/x64deps` vengono riscritte in
# `@loader_path/…` così la base funziona su un'altra macchina (username diverso).
#
# Uso: scripts/package-wine-base.sh [OUT_DIR]
#
set -euo pipefail

WINE_SRC="${HOME}/wine-cx"
DEPS_SRC="${HOME}/x64deps"
OUT="${1:-dist}"
NAME="wine-cx"
PKG_NAME="wine-cx-macos-x86_64.tar.xz"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY="${REPO_ROOT}/Resources/third-party"

[ -x "${WINE_SRC}/bin/wine" ] || { echo "ERRORE: ${WINE_SRC}/bin/wine non trovato"; exit 1; }
[ -d "${DEPS_SRC}" ]         || { echo "ERRORE: ${DEPS_SRC} non trovato"; exit 1; }

WORK="$(mktemp -d)"
STAGE="${WORK}/${NAME}"
echo "==> stage: ${STAGE}"
cp -c -R "${WINE_SRC}" "${STAGE}" 2>/dev/null || cp -R "${WINE_SRC}" "${STAGE}"
echo "==> x64deps (dentro la base)"
cp -c -R "${DEPS_SRC}" "${STAGE}/x64deps" 2>/dev/null || cp -R "${DEPS_SRC}" "${STAGE}/x64deps"

# --- rimozione artefatti Apple D3DMetal (non ridistribuibili) ----------------
echo "==> rimozione artefatti Apple D3DMetal"
rm -rf "${STAGE}/lib/external"
find "${STAGE}/lib/wine" -type l 2>/dev/null | while IFS= read -r l; do
  case "$(readlink "$l")" in
    *external*) rm -f "$l"; echo "    symlink rimosso: $(basename "$l")" ;;
  esac
done
apple_removed=0
while IFS= read -r f; do
  # NB: niente `grep -q` (con pipefail la SIGPIPE su strings farebbe fallire l'if).
  if strings -a "$f" 2>/dev/null | grep -E 'D3DMetalDLLsBase|D3D4Mac' >/dev/null 2>&1; then
    rm -f "$f"; apple_removed=$((apple_removed+1)); echo "    thunk Apple rimosso: ${f#"${STAGE}"/}"
  fi
done < <(find "${STAGE}" -type f \( -name '*.dll' -o -name '*.so' -o -name '*.exe' \
      -o -name '*.drv' -o -name '*.sys' \) 2>/dev/null)
echo "    $apple_removed file Apple rimossi"
if [ -e "${STAGE}/lib/external" ]; then echo "ERRORE: lib/external ancora presente"; exit 1; fi
leftover=0
while IFS= read -r f; do
  if strings -a "$f" 2>/dev/null | grep -E 'D3DMetalDLLsBase|D3D4Mac' >/dev/null 2>&1; then
    echo "    RESIDUO Apple: ${f#"${STAGE}"/}"; leftover=$((leftover+1))
  fi
done < <(find "${STAGE}" -type f \( -name '*.dll' -o -name '*.so' -o -name '*.exe' \
      -o -name '*.drv' -o -name '*.sys' \) 2>/dev/null)
[ "${leftover}" = 0 ] || { echo "ERRORE: ${leftover} artefatti Apple residui"; exit 1; }

# --- ripristino DLL builtin di Wine (i thunk Apple le avevano sostituite) ----
# Gli esperimenti D3DMetal lasciano backup `X.gamex-bak`: se `X` non esiste lo
# ripristiniamo (è la DLL builtin di Wine, LGPL), altrimenti lo scartiamo.
while IFS= read -r bak; do
  orig="${bak%.gamex-bak}"
  if [ -e "$orig" ]; then
    rm -f "$bak"
  else
    mv "$bak" "$orig"; echo "    ripristinata DLL Wine: ${orig#"${STAGE}"/}"
  fi
done < <(find "${STAGE}" -type f -name '*.gamex-bak' 2>/dev/null)

# --- licenza Wine (LGPL-2.1-or-later) + NOTICE ------------------------------
echo "==> licenza Wine + NOTICE"
cp -f "${THIRD_PARTY}/wine-LICENSE"     "${STAGE}/LICENSE"
cp -f "${THIRD_PARTY}/wine-COPYING.LIB" "${STAGE}/COPYING.LIB"
cat > "${STAGE}/NOTICE" <<'NOTICE'
Game-X — Wine base package (wine-cx) — third-party components
==============================================================

This package contains a build of Wine built from the CodeWeavers public
sources (TEB-in-TSD scheme) plus runtime dependency libraries. It does NOT
contain D3DMetal: no Apple D3DMetal framework, no libd3dshared.dylib and no
Apple D3DMetal PE thunks (d3d11.dll, dxgi.dll, d3d12.dll, nvapi64.dll,
nvngx.dll, atidxx64.dll) are included. Game-X injects D3DMetal locally from
the user's own Apple Game Porting Toolkit copy at runtime.

Components
----------
* Wine (built from CodeWeavers public sources)
    License: GNU Lesser General Public License v2.1 or later (LGPL-2.1-or-later)
    Full text: LICENSE  ·  GNU LGPL 2.1 text: COPYING.LIB
    Source: https://gitlab.winehq.org/wine/wine  and  https://www.codeweavers.com/
    Redistribution of the unmodified library binaries is permitted under the
    LGPL. Game-X does not modify Wine's own libraries; the D3DMetal files are
    supplied separately by the user and are not part of this package.

* x64deps/ (MoltenVK, libSDL2, freetype, brotli, libMacportsLegacySupport, …)
    Third-party libraries under their own licenses, redistributed as
    unmodified binaries together with the Wine build.

No Valve/Steam binaries are included. No Apple D3DMetal/GPTK binaries are
included. Users obtain those directly from the respective vendors.
NOTICE

echo "==> strip simboli di debug (riduce molto il pacchetto)"
if command -v x86_64-w64-mingw32-strip >/dev/null; then
  n=0
  while IFS= read -r f; do
    x86_64-w64-mingw32-strip --strip-debug "$f" 2>/dev/null && n=$((n+1))
  done < <(find "${STAGE}" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.so' -o -name '*.sys' -o -name '*.drv' \) 2>/dev/null)
  echo "    $n file PE"
fi
while IFS= read -r f; do
  /usr/bin/strip -S "$f" 2>/dev/null || true
done < <(find "${STAGE}" -type f \( -name '*.dylib' -o -name 'wine' -o -name 'wineserver' \) 2>/dev/null)

echo "==> dipendenze rilocabili (@loader_path)"
python3 - "${STAGE}" <<'PY'
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
            rel = os.path.relpath(os.path.join(stage, 'x64deps', leaf), root)
            new = '@loader_path/' + rel
            r = subprocess.run(['/usr/bin/install_name_tool','-change',dep,new,p],
                               capture_output=True, text=True)
            if r.returncode == 0:
                changed += 1
        if p.endswith('.dylib'):
            idn = subprocess.run(['/usr/bin/otool','-D',p], capture_output=True, text=True).stdout
            idl = idn.strip().splitlines()
            if len(idl) > 1 and '/x64deps/' in idl[1]:
                leaf = os.path.basename(idl[1].strip())
                subprocess.run(['/usr/bin/install_name_tool','-id','@loader_path/'+leaf,p],
                               capture_output=True)
                changed += 1
        if p.endswith(('.so', '.dylib')) or os.access(p, os.X_OK):
            subprocess.run(['/usr/bin/codesign','--force','--sign','-',p],
                           capture_output=True)
print(f"    {changed} dipendenze riscritte")
PY

echo "==> tarball"
mkdir -p "${OUT}"
OUT_ABS="$(cd "${OUT}" && pwd)"
PKG="${OUT_ABS}/${PKG_NAME}"
export XZ_OPT="-T0 -6"
( cd "${WORK}" && tar -cJf "${PKG}" "${NAME}" )
SIZE=$(stat -f%z "${PKG}")
SHA=$(shasum -a 256 "${PKG}" | awk '{print $1}')
rm -rf "${WORK}"
echo
echo "OK  ${PKG}"
echo "    dimensione: $(printf '%.1f' "$(echo "${SIZE}/1048576" | bc -l)") MB"
echo "    sha256:     ${SHA}"
echo
echo "Sull'altra macchina:"
echo "  tar -xJf ${PKG_NAME} -C \"\$HOME\"        # → ~/wine-cx"
echo "  gx runtime build-gptk"
