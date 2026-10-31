#!/bin/zsh
# Arma Paperclip.app con Pake y la instala en /Applications.
#
# La dirección no se escribe aquí: la saca scripts/server-url.zsh de `tailscale serve`. Si la app
# está abierta, se cierra solo para reemplazarla y se vuelve a abrir.
#
# La barra de título va superpuesta (--hide-title-bar): los botones de la ventana quedan sobre la
# barra lateral de Paperclip, y inject/titlebar.* les hace lugar y mueve la ventana desde las barras.
#
# Uso: ./build.sh            (PAKE_VERSION=x.y.z ./build.sh para otra versión de Pake)
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
PAKE_VERSION=${PAKE_VERSION:-3.17.8}
APP_NAME=Paperclip
APP_ID=com.javiervinueza.paperclip
APP_PATH=/Applications/$APP_NAME.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

URL=$("$ROOT/scripts/server-url.zsh")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$ROOT/scripts/make-icns.zsh" "$WORK/icon.icns"

print "Armando $APP_NAME.app → $URL (Pake $PAKE_VERSION)"
cd "$WORK"
npx -y "pake-cli@$PAKE_VERSION" "$URL" \
  --name "$APP_NAME" \
  --identifier "$APP_ID" \
  --icon "$WORK/icon.icns" \
  --inject "$ROOT/inject/titlebar.css,$ROOT/inject/titlebar.js,$ROOT/inject/decisions.js" \
  --hide-title-bar \
  --width 1440 --height 900 \
  --iterative-build

if [[ ! -d $WORK/$APP_NAME.app ]]; then
  print -u2 "Pake no dejó $APP_NAME.app en $WORK."
  exit 1
fi

# Reemplazo: se cierra la app recién ahora, para que no quede cerrada durante la compilación.
WAS_RUNNING=false
if pgrep -qf "$APP_PATH/Contents/MacOS/"; then
  WAS_RUNNING=true
  osascript -e "quit app \"$APP_NAME\"" || true
  while pgrep -qf "$APP_PATH/Contents/MacOS/"; do sleep 0.5; done
fi
rm -rf "$APP_PATH"
ditto "$WORK/$APP_NAME.app" "$APP_PATH"
# Que el Dock y Finder tomen el ícono nuevo de esta app (solo registra esta app).
"$LSREGISTER" -f "$APP_PATH"

# La compilación de Rust deja ~1,5 GB en el caché de npx; rearmar toma unos 2 minutos.
for target in "$(npm config get cache)"/_npx/*/node_modules/pake-cli/src-tauri/target(N); do
  rm -rf "$target"
done

if $WAS_RUNNING; then open "$APP_PATH"; fi
print "Listo: $APP_PATH"
