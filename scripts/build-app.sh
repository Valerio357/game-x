#!/usr/bin/env bash
#
# Costruisce GameX.app (bundle macOS) da SwiftPM.
# SwiftPM non produce bundle .app: questo script impacchetta l'eseguibile
# `GameX` + Info.plist + il resource bundle di GameXCore.
#
# Uso: scripts/build-app.sh [debug|release]   (default: release)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/dist/GameX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> eseguibile"
cp "$BIN_DIR/GameX" "$APP/Contents/MacOS/GameX"

# Il CLI `gx` è incluso nel bundle: l'app lo usa per le azioni che non può fare
# da sola (es. `gx runtime build-gptk`) e così l'utente non deve installarlo a parte.
echo "==> CLI gx (incluso nel bundle)"
if [ -f "$BIN_DIR/gx" ]; then
  cp "$BIN_DIR/gx" "$APP/Contents/MacOS/gx"
  chmod +x "$APP/Contents/MacOS/gx"
else
  echo "   ATTENZIONE: binario gx non trovato in $BIN_DIR"
fi

echo "==> resource bundle"
if [ -d "$BIN_DIR/game-x_GameXCore.bundle" ]; then
  # Solo dentro Contents/Resources: mettere file nella RADICE del .app rende il
  # bundle non sigillabile ("unsealed contents present in the bundle root") e
  # Gatekeeper lo segnala come danneggiato. Le risorse si risolvono via
  # BundledResources (non Bundle.module).
  cp -R "$BIN_DIR/game-x_GameXCore.bundle" "$APP/Contents/Resources/"
fi

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  echo "==> icona"
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Icona Dock/Cmd-Tab tramite CFBundleIconFile (AppIcon.icns).

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Game-X</string>
    <key>CFBundleDisplayName</key>     <string>Game-X</string>
    <key>CFBundleIdentifier</key>      <string>dev.gamex.app</string>
    <key>CFBundleExecutable</key>      <string>GameX</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> firma ad-hoc (inside-out)"
# Prima i binari annidati, poi il bundle. Niente file nella radice del .app.
SIGN_OK=1
if [ -f "$APP/Contents/MacOS/gx" ]; then
  codesign --force --sign - --identifier dev.gamex.gx "$APP/Contents/MacOS/gx" >/dev/null 2>&1 || SIGN_OK=0
fi
codesign --force --sign - --identifier dev.gamex.app "$APP" >/dev/null 2>&1 || SIGN_OK=0
if [ "$SIGN_OK" = 1 ] && codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
  echo "   firma valida"
else
  echo "   ATTENZIONE: firma ad-hoc non valida (l'app verrà segnalata come danneggiata)"
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3 || true
fi

echo "==> fatto: $APP"
echo "Avvia con: open \"$APP\"   (al primo avvio: tasto destro → Apri)"
