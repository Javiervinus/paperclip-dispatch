#!/bin/zsh
# Arma la app nativa (Swift, Liquid Glass) y la instala en /Applications.
#
# Compila con `swift build`, arma el .app a mano (Info.plist, ícono, archivos de la página) y lo firma
# con la identidad Developer ID del llavero. La dirección de Paperclip la elige cada uno en la bienvenida.
# Si la app está abierta, se cierra solo para reemplazarla y se vuelve a abrir.
#
# Variables (con su valor por defecto). Las de tu Mac pueden ir en macos/build.local.env, que no se sube:
#   APP_NAME="Paperclip Swift"  APP_ID=com.javiervinueza.paperclip.swift  INSTALL_DIR=/Applications
#   PAPERCLIP_SERVER_URL=<vacía: la bienvenida la pide; con valor, la app la adopta la primera vez>
#   PAPERCLIP_UPDATE_SCRIPT=<vacía: actualiza con `paperclipai update`; con valor, con ese script>
#   SIGN_IDENTITY=<la primera «Developer ID Application» del llavero; «-» firma sin identidad>
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
REPO=${ROOT:h}
[[ -f $ROOT/build.local.env ]] && source "$ROOT/build.local.env"
APP_NAME=${APP_NAME:-Paperclip Swift}
APP_ID=${APP_ID:-com.javiervinueza.paperclip.swift}
APP_VERSION=${APP_VERSION:-0.1.0}
INSTALL_DIR=${INSTALL_DIR:-/Applications}
EXECUTABLE=PaperclipApp
APP_PATH=$INSTALL_DIR/$APP_NAME.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -z $SIGN_IDENTITY ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
fi
SIGN_IDENTITY=${SIGN_IDENTITY:--}

if [[ -n $PAPERCLIP_UPDATE_SCRIPT && ! -f $PAPERCLIP_UPDATE_SCRIPT ]]; then
  print -u2 "Ojo: no existe $PAPERCLIP_UPDATE_SCRIPT; la app no podrá actualizar Paperclip."
fi

print "Compilando $APP_NAME → $APP_PATH"
swift build -c release --package-path "$ROOT"
BINARY=$(swift build -c release --package-path "$ROOT" --show-bin-path)/$EXECUTABLE

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP=$WORK/$APP_NAME.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/web/bridge.js" "$ROOT/web/glass.js" "$ROOT/web/glass.css" "$APP/Contents/Resources/"
# La app está en español: con esta carpeta, macOS también le da en español sus textos (errores, menús).
mkdir -p "$APP/Contents/Resources/es.lproj"
touch "$APP/Contents/Resources/es.lproj/Localizable.strings"
"$REPO/scripts/make-icns.zsh" "$APP/Contents/Resources/AppIcon.icns"

PLIST=$APP/Contents/Info.plist
plutil -create xml1 "$PLIST"
plist() { plutil -insert "$1" "-$2" "$3" "$PLIST"; }
plist CFBundleIdentifier string "$APP_ID"
plist CFBundleName string "$APP_NAME"
plist CFBundleDisplayName string "$APP_NAME"
plist CFBundleExecutable string "$EXECUTABLE"
plist CFBundleIconFile string AppIcon
plist CFBundlePackageType string APPL
plist CFBundleShortVersionString string "$APP_VERSION"
plist CFBundleVersion string "$APP_VERSION"
plist CFBundleDevelopmentRegion string es
# Sin esto, los textos de macOS (errores de conexión, menús que agrega el sistema) salen en inglés.
plist CFBundleLocalizations json '["es"]'
plist LSMinimumSystemVersion string 26.0
plist LSApplicationCategoryType string public.app-category.productivity
plist NSPrincipalClass string NSApplication
plist NSHighResolutionCapable bool true
# Por si Paperclip pide el micrófono o la cámara: sin estos textos, macOS cierra la app.
plist NSMicrophoneUsageDescription string "Paperclip pide el micrófono para dictar."
plist NSCameraUsageDescription string "Paperclip pide la cámara."
[[ -n $PAPERCLIP_SERVER_URL ]] && plist PaperclipServerURL string "$PAPERCLIP_SERVER_URL"
[[ -n $PAPERCLIP_UPDATE_SCRIPT ]] && plist PaperclipUpdateScript string "$PAPERCLIP_UPDATE_SCRIPT"
plutil -lint "$PLIST" >/dev/null

codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

# Reemplazo: se cierra la app recién ahora, para que no quede cerrada durante la compilación.
WAS_RUNNING=false
if pgrep -qf "$APP_PATH/Contents/MacOS/"; then
  WAS_RUNNING=true
  osascript -e "quit app \"$APP_NAME\"" || true
  while pgrep -qf "$APP_PATH/Contents/MacOS/"; do sleep 0.5; done
fi
mkdir -p "$INSTALL_DIR"
rm -rf "$APP_PATH"
ditto "$APP" "$APP_PATH"
# Que el Dock y Finder tomen el ícono de esta app (solo registra esta app).
"$LSREGISTER" -f "$APP_PATH"

if $WAS_RUNNING; then open "$APP_PATH"; fi
print "Listo: $APP_PATH (firmada con: $SIGN_IDENTITY)"
