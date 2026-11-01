#!/bin/zsh
# Ensayo visual: captura ventanas de la app sin abrir nada en pantalla.
#   macos/snapshot.zsh settings [carpeta]       cada pestaña de Ajustes, en claro y en oscuro
#   macos/snapshot.zsh window [carpeta]         la ventana de Paperclip, normal y con Liquid Glass
#   macos/snapshot.zsh welcome [carpeta]        cada paso de la bienvenida y la ventana sin conexión
#   macos/snapshot.zsh page <ruta> [carpeta]    una página de Paperclip con la app, para mostrarla
#       SIZE=1512x982 (tamaño de la ventana, en puntos)
#       ANCHORS="|En qué se fue la semana" (una captura por ancla, separadas por «|»; vacía = arriba)
#       La captura de page lleva la sombra de la ventana, para ponerla sobre un fondo.
#   SHADOW=1 deja la sombra también en settings, window y welcome.
#   APP_PATH=<ruta a un .app> ensaya otra copia (una de prueba fuera de Aplicaciones); si no, la instalada.
#   ACTIVE=1 las muestra de a una en el centro de la pantalla, al frente, para que se vean activas (botones
#       de color). Tapa la pantalla unos segundos por ventana: solo cuando nadie está usando la Mac.
# Por defecto usa una carpeta temporal e imprime cuál. Abre una segunda copia de la app instalada, que pone
# las ventanas fuera de la pantalla y anota sus números en windows.txt. Aquí se capturan con
# screencapture -l, que dibuja el Liquid Glass de verdad. La terminal necesita permiso de Grabación de
# pantalla.
set -euo pipefail

USAGE="Uso: snapshot.zsh settings|window|welcome [carpeta] · snapshot.zsh page <ruta> [carpeta]"
KIND=${1:?$USAGE}
APP_NAME=${APP_NAME:-Paperclip Dispatch}
APP=${APP_PATH:-$APP_NAME}
EXTRA=()
NO_SHADOW=(-o)
case $KIND in
  settings|window|welcome)
    OUT=${2:-$(mktemp -d)/$KIND} ;;
  page)
    ROUTE=${2:?$USAGE}
    OUT=${3:-$(mktemp -d)/$KIND}
    EXTRA=(-PaperclipSnapshotPath "$ROUTE" -PaperclipSnapshotSize "${SIZE:-1512x982}"
      -PaperclipSnapshotAnchors "${ANCHORS:-}")
    NO_SHADOW=() ;;
  *)
    print -u2 "$USAGE"; exit 2 ;;
esac
[[ ${SHADOW:-} == 1 ]] && NO_SHADOW=()
mkdir -p "$OUT"
rm -f "$OUT/windows.txt" "$OUT/captured" "$OUT"/window-*.txt(N) "$OUT"/captured-*(N) "$OUT/done"

if [[ ${ACTIVE:-} == 1 ]]; then
  # Sin -g: la copia abre al frente, para que sus ventanas puedan quedar activas.
  open -n -a "$APP" --args -PaperclipSnapshot "$KIND" -PaperclipSnapshotDirectory "$OUT" \
    -PaperclipSnapshotActive YES "${EXTRA[@]}"
  pid=
  for _ in {1..30}; do
    pid=$(pgrep -f -- "-PaperclipSnapshotDirectory $OUT" | head -1) && [[ -n $pid ]] && break
    sleep 0.5
  done
  number=1
  while true; do
    for _ in {1..90}; do
      [[ -s $OUT/window-$number.txt || -e $OUT/done ]] && break
      sleep 1
    done
    [[ -s $OUT/window-$number.txt ]] || break
    # La app no termina la línea con un salto: `read` llega al final y devuelve error aunque leyó.
    read -r window file < "$OUT/window-$number.txt" || true
    # macOS no deja que una app se ponga al frente sola si otra tiene el foco: se la pone desde aquí.
    [[ -n $pid ]] && osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null
    sleep 1
    screencapture -x "${NO_SHADOW[@]}" -l "$window" "$OUT/$file"
    touch "$OUT/captured-$number"
    (( number++ ))
  done
  (( number > 1 )) || { print -u2 "La app no mostró ninguna ventana en 90 s."; exit 1; }
  print "$OUT"
  exit 0
fi

open -g -n -a "$APP" --args -PaperclipSnapshot "$KIND" -PaperclipSnapshotDirectory "$OUT" "${EXTRA[@]}"

for _ in {1..90}; do
  [[ -s $OUT/windows.txt ]] && break
  sleep 1
done
[[ -s $OUT/windows.txt ]] || { print -u2 "La app no anotó sus ventanas en 90 s."; exit 1; }

while read -r window file || [[ -n ${window:-} ]]; do
  screencapture -x "${NO_SHADOW[@]}" -l "$window" "$OUT/$file"
done < "$OUT/windows.txt"
touch "$OUT/captured"
print "$OUT"
