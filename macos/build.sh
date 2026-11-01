#!/bin/zsh
# Arma Paperclip Dispatch, la app nativa (Swift, Liquid Glass), y la instala en /Applications.
#
# Compila con `swift build`, arma el .app a mano (Info.plist, ícono, Sparkle, archivos de la página) y lo
# firma con la identidad Developer ID del llavero. La dirección de Paperclip la elige cada uno en la
# bienvenida. Si la app está abierta, se cierra solo para reemplazarla y se vuelve a abrir.
#
# Variables (con su valor por defecto). Las de tu Mac pueden ir en macos/build.local.env, que no se sube:
#   APP_NAME="Paperclip Dispatch"  APP_ID=com.javiervinueza.paperclip-dispatch  INSTALL_DIR=/Applications
#   APP_VERSION=<la de macos/VERSION>
#   OUTPUT_DIR=<vacía: instala en INSTALL_DIR; con valor, deja el .app ahí y no instala (release.sh)>
#   UNIVERSAL=1 compila para Apple Silicon e Intel (más lento; lo usa release.sh)
#   NOTARIZE=1 firma con la hora del servidor de Apple, que pide la notarización (lo usa release.sh)
#   RELEASE=1 arma la versión para repartir (lo usa release.sh): no lee macos/build.local.env y deja fuera
#       PAPERCLIP_SERVER_URL, PAPERCLIP_UPDATE_SCRIPT y TELEGRAM_API_URL aunque vengan en el entorno, porque son
#       de esta Mac
#   PAPERCLIP_SERVER_URL=<vacía: la bienvenida la pide; con valor, la app la adopta la primera vez>
#   PAPERCLIP_UPDATE_SCRIPT=<vacía: actualiza con `paperclipai update`; con valor, con ese script>
#   SIGN_IDENTITY=<la primera «Developer ID Application» del llavero; «-» firma sin identidad>
#   TELEGRAM_API_URL=<vacía: el bot habla con Telegram; con valor, solo para probar, con un Telegram simulado
#       en esa dirección (p. ej. http://127.0.0.1:8081). RELEASE=1 la deja fuera>
# Las de las actualizaciones de la app (appcast, llave pública) y las de «Acerca de» (autor, repositorio)
# están en macos/release.env.
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
REPO=${ROOT:h}
# Lo que se reparte no lleva nada de la Mac que lo arma: ni sus ajustes locales ni la dirección de su
# Paperclip, la ruta a su script o un Telegram simulado.
if [[ $RELEASE == 1 ]]; then
  unset PAPERCLIP_SERVER_URL PAPERCLIP_UPDATE_SCRIPT TELEGRAM_API_URL
elif [[ -f $ROOT/build.local.env ]]; then
  source "$ROOT/build.local.env"
fi
source "$ROOT/release.env"
APP_NAME=${APP_NAME:-Paperclip Dispatch}
APP_ID=${APP_ID:-com.javiervinueza.paperclip-dispatch}
APP_VERSION=${APP_VERSION:-$(<"$ROOT/VERSION")}
INSTALL_DIR=${INSTALL_DIR:-/Applications}
EXECUTABLE=PaperclipDispatch
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
# Los scripts y estilos de la página (WebResources.swift dice cuáles se inyectan y en qué orden).
cp "$ROOT"/web/*.js "$ROOT"/web/*.css "$APP/Contents/Resources/"
# Los textos: el código está en inglés y los String Catalogs del target traen el español. `swift build` no los
# compila (solo Xcode lo hace), así que van aquí: en.lproj y es.lproj, con Localizable.strings (y .stringsdict
# si hay plurales) e InfoPlist.strings. Con esas carpetas, la app sigue el idioma de la Mac, y macOS también da
# en ese idioma sus propios textos (errores, menús que agrega el sistema).
for catalog in "$ROOT"/Sources/$EXECUTABLE/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources" >/dev/null
done
# El ícono es un documento de Icon Composer (AppIcon.icon): claro, oscuro, transparente y tintado, como
# los íconos de macOS 26. actool lo compila en Assets.car, más un AppIcon.icns para lo que no lee el .car.
# En el mismo Assets.car va el color de acento de la app (Assets.xcassets/AccentColor): la tinta de Paperclip.
# macOS lo usa cuando el acento del sistema es «Multicolor»; si se eligió otro color, manda ese.
xcrun actool "$ROOT/AppIcon.icon" "$ROOT/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist "$WORK/icon.plist" \
  --errors --warnings >/dev/null
# Las variantes clara y oscura en PNG, para dibujos de ejemplo dentro de la app (el ícono de la app en sí se le
# pide a macOS, que lo dibuja según el estilo de íconos elegido). Las exporta el ictool de Icon Composer.
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
plist NSAccentColorName string AccentColor
plist CFBundlePackageType string APPL
plist CFBundleShortVersionString string "$APP_VERSION"
plist CFBundleVersion string "$APP_VERSION"
plist CFBundleDevelopmentRegion string en
# Los idiomas de la app, los de sus .lproj. Sin esto, los textos de macOS (errores de conexión, menús que agrega
# el sistema) salen siempre en inglés.
plist CFBundleLocalizations json '["en","es"]'
plist LSMinimumSystemVersion string 26.0
plist LSApplicationCategoryType string public.app-category.productivity
plist NSPrincipalClass string NSApplication
plist NSHighResolutionCapable bool true
# Los textos de los permisos, en inglés, de InfoPlist.xcstrings (cada .lproj trae los suyos en InfoPlist.strings).
# Micrófono y cámara, por si Paperclip los pide: sin estos textos, macOS cierra la app. La Red local la pide
# macOS al hablar con Paperclip en otra computadora de la red.
# Si falta uno, se para aquí: un texto vacío haría que macOS cierre la app al pedir el permiso.
for key in NSMicrophoneUsageDescription NSCameraUsageDescription NSLocalNetworkUsageDescription; do
  text=$(plutil -extract $key raw "$APP/Contents/Resources/en.lproj/InfoPlist.strings")
  [[ -n $text ]] || { print -u2 "Falta $key en InfoPlist.xcstrings."; exit 1; }
  plist $key string "$text"
done
[[ -n $PAPERCLIP_SERVER_URL ]] && plist PaperclipServerURL string "$PAPERCLIP_SERVER_URL"
[[ -n $PAPERCLIP_UPDATE_SCRIPT ]] && plist PaperclipUpdateScript string "$PAPERCLIP_UPDATE_SCRIPT"
[[ -n $TELEGRAM_API_URL ]] && plist TelegramAPIURL string "$TELEGRAM_API_URL"
# Actualizaciones de la app (Sparkle). Sin appcast, la app no busca versiones.
if [[ -n $UPDATE_FEED_URL ]]; then
  plist SUFeedURL string "$UPDATE_FEED_URL"
  plist SUPublicEDKey string "$UPDATE_PUBLIC_KEY"
  # Buscar y descargar solas desde el primer día, sin el diálogo de Sparkle que pregunta si buscar.
  plist SUEnableAutomaticChecks bool true
  plist SUAutomaticallyUpdate bool true
  plist SUScheduledCheckInterval integer "$UPDATE_CHECK_INTERVAL"
fi
# Quién la hace y dónde está su código («Acerca de» y el menú Ayuda). Sin REPOSITORY_URL, el del remoto
# origin si está en GitHub, como hace release.sh.
if [[ -z $REPOSITORY_URL ]]; then
  ORIGIN=$(git -C "$REPO" remote get-url origin 2>/dev/null) || ORIGIN=
  [[ $ORIGIN == *github.com* ]] &&
    REPOSITORY_URL=https://github.com/$(sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##' <<<"$ORIGIN")
fi
if [[ -n $APP_AUTHOR ]]; then
  plist DispatchAuthor string "$APP_AUTHOR"
  plist NSHumanReadableCopyright string "© $(date +%Y) $APP_AUTHOR"
fi
[[ -n $APP_AUTHOR_URL ]] && plist DispatchAuthorURL string "$APP_AUTHOR_URL"
[[ -n $REPOSITORY_URL ]] && plist DispatchRepositoryURL string "$REPOSITORY_URL"
plutil -lint "$PLIST" >/dev/null

# De adentro hacia afuera y sin --deep, como pide Sparkle: sus ayudantes, el framework y la app.
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
# Para notarizar (release.sh), Apple pide la hora firmada por su servidor.
TIMESTAMP=()
[[ $NOTARIZE == 1 ]] && TIMESTAMP=(--timestamp)
# El runtime endurecido (lo pide la notarización) solo carga librerías del mismo equipo de desarrollador. Firmada
# sin identidad («-») no hay equipo: con el runtime, dyld rechaza Sparkle y la app se cae al abrir.
RUNTIME=(--options runtime)
[[ $SIGN_IDENTITY == - ]] && RUNTIME=()
sign() { codesign --force "${RUNTIME[@]}" "${TIMESTAMP[@]}" --sign "$SIGN_IDENTITY" "$@"; }
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
