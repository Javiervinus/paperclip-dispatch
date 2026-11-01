#!/bin/zsh
# Arma Paperclip Dispatch, la app nativa (Swift, Liquid Glass), y la instala en /Applications.
#
# Compila con `swift build`, arma el .app a mano (Info.plist, ícono, Sparkle, archivos de la página) y lo
# firma con la identidad Developer ID del llavero. La dirección de Paperclip la elige cada uno en la
# bienvenida. Si la app está abierta, se cierra solo para reemplazarla y se vuelve a abrir.
#
# Variables (con su valor por defecto). Las de tu Mac pueden ir en macos/build.local.env, que no se sube:
#   APP_NAME="Paperclip Dispatch"  APP_ID=com.javiervinueza.paperclip.swift  INSTALL_DIR=/Applications
#   APP_VERSION=<la de macos/VERSION>
#   OUTPUT_DIR=<vacía: instala en INSTALL_DIR; con valor, deja el .app ahí y no instala (release.sh)>
#   UNIVERSAL=1 compila para Apple Silicon e Intel (más lento; lo usa release.sh)
#   NOTARIZE=1 firma con la hora del servidor de Apple, que pide la notarización (lo usa release.sh)
#   PAPERCLIP_SERVER_URL=<vacía: la bienvenida la pide; con valor, la app la adopta la primera vez>
#   PAPERCLIP_UPDATE_SCRIPT=<vacía: actualiza con `paperclipai update`; con valor, con ese script>
#   SIGN_IDENTITY=<la primera «Developer ID Application» del llavero; «-» firma sin identidad>
# Las de las actualizaciones de la app (appcast, llave pública) están en macos/release.env.
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
REPO=${ROOT:h}
[[ -f $ROOT/build.local.env ]] && source "$ROOT/build.local.env"
source "$ROOT/release.env"
APP_NAME=${APP_NAME:-Paperclip Dispatch}
APP_ID=${APP_ID:-com.javiervinueza.paperclip.swift}
APP_VERSION=${APP_VERSION:-$(<"$ROOT/VERSION")}
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

# Sin el llavero: SwiftPM lo consulta al bajar Sparkle y, con la pantalla bloqueada, se queda esperando.
SWIFT_FLAGS=(-c release --package-path "$ROOT" --disable-keychain)
[[ $UNIVERSAL == 1 ]] && SWIFT_FLAGS+=(--arch arm64 --arch x86_64)
print "Compilando $APP_NAME $APP_VERSION → ${OUTPUT_DIR:-$APP_PATH}"
swift build "${SWIFT_FLAGS[@]}"
BIN_DIR=$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)
BINARY=$BIN_DIR/$EXECUTABLE

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP=$WORK/$APP_NAME.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE"
# Sparkle va dentro de la app; el ejecutable lo busca en Contents/Frameworks. Sus servicios XPC solo sirven
# a apps con sandbox, y esta no lo tiene: fuera.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ROOT/web/bridge.js" "$ROOT/web/glass.js" "$ROOT/web/glass.css" "$APP/Contents/Resources/"
# La app está en español: con esta carpeta, macOS también le da en español sus textos (errores, menús).
mkdir -p "$APP/Contents/Resources/es.lproj"
touch "$APP/Contents/Resources/es.lproj/Localizable.strings"
# El ícono es un documento de Icon Composer (AppIcon.icon): claro, oscuro, transparente y tintado, como
# los íconos de macOS 26. actool lo compila en Assets.car, más un AppIcon.icns para lo que no lee el .car.
xcrun actool "$ROOT/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist "$WORK/icon.plist" \
  --errors --warnings >/dev/null
# Las variantes clara y oscura en PNG, para el ícono dentro de la app (panel, bienvenida, Ajustes): el que da
# macOS a la app es siempre el claro. Las exporta el ictool de Icon Composer, que viene con Xcode.
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
for rendition in Default:AppIconLight Dark:AppIconDark; do
  "$ICTOOL" "$ROOT/AppIcon.icon" --export-image --output-file "$APP/Contents/Resources/${rendition#*:}.png" \
    --platform macOS --rendition "${rendition%%:*}" --width 256 --height 256 --scale 1 >/dev/null
done

PLIST=$APP/Contents/Info.plist
plutil -create xml1 "$PLIST"
plist() { plutil -insert "$1" "-$2" "$3" "$PLIST"; }
plist CFBundleIdentifier string "$APP_ID"
plist CFBundleName string "$APP_NAME"
plist CFBundleDisplayName string "$APP_NAME"
plist CFBundleExecutable string "$EXECUTABLE"
plist CFBundleIconFile string AppIcon
plist CFBundleIconName string AppIcon
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
# Actualizaciones de la app (Sparkle). Sin appcast, la app no busca versiones.
if [[ -n $UPDATE_FEED_URL ]]; then
  plist SUFeedURL string "$UPDATE_FEED_URL"
  plist SUPublicEDKey string "$UPDATE_PUBLIC_KEY"
  # Buscar y descargar solas desde el primer día, sin el diálogo de Sparkle que pregunta si buscar.
  plist SUEnableAutomaticChecks bool true
  plist SUAutomaticallyUpdate bool true
  plist SUScheduledCheckInterval integer "$UPDATE_CHECK_INTERVAL"
fi
plutil -lint "$PLIST" >/dev/null

# De adentro hacia afuera y sin --deep, como pide Sparkle: sus ayudantes, el framework y la app.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
# Para notarizar (release.sh), Apple pide la hora firmada por su servidor.
TIMESTAMP=()
[[ $NOTARIZE == 1 ]] && TIMESTAMP=(--timestamp)
sign() { codesign --force --options runtime "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY" "$@"; }
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"
codesign --verify --strict --deep "$APP"

if [[ -n $OUTPUT_DIR ]]; then
  mkdir -p "$OUTPUT_DIR"
  rm -rf "$OUTPUT_DIR/$APP_NAME.app"
  ditto "$APP" "$OUTPUT_DIR/$APP_NAME.app"
  print "Listo: $OUTPUT_DIR/$APP_NAME.app (firmada con: $SIGN_IDENTITY)"
  exit 0
fi

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
