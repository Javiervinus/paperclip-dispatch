#!/bin/zsh
# Pone una versión publicada de Paperclip Dispatch en su cask de Homebrew (`version` y `sha256`) y la
# commitea en el tap. Lo llama release.sh --publish después de crear el release en GitHub; también se puede
# correr solo, por ejemplo contra una copia del tap (HOMEBREW_TAP_DIR) para ver qué cambiaría.
#
#   macos/update-cask.sh <versión> <dmg>                 actualiza el cask y lo commitea en el tap, sin subirlo
#   macos/update-cask.sh --push <versión> <dmg>          además sube el tap (solo lo hace release.sh --publish)
#   macos/update-cask.sh --check [--push] [<versión> <nombre del dmg>]
#                                                        solo comprueba que el tap está listo, sin cambiar nada
#
# Variables (con su valor por defecto; las de una Mac pueden ir en macos/build.local.env):
#   HOMEBREW_TAP_DIR=<la carpeta homebrew-tap junto a la del repo>  el repo git del tap
#   CASK_TOKEN=paperclip-dispatch  el cask, en Casks/<CASK_TOKEN>.rb
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
REPO=${ROOT:h}
[[ -f $ROOT/build.local.env ]] && source "$ROOT/build.local.env"
APP_NAME=${APP_NAME:-Paperclip Dispatch}
CASK_TOKEN=${CASK_TOKEN:-${${(L)APP_NAME}// /-}}

fail() {
  print -u2 "update-cask: $*"
  exit 1
}

CHECK_ONLY=false
PUSH=false
while [[ $1 == --* ]]; do
  case $1 in
    --check) CHECK_ONLY=true ;;
    --push) PUSH=true ;;
    *) fail "opción desconocida: $1" ;;
  esac
  shift
done
VERSION=$1
DMG=$2
$CHECK_ONLY || [[ -n $VERSION && -n $DMG ]] || fail "uso: update-cask.sh [--push] <versión> <dmg>"

# El tap vive junto a la carpeta principal del repo (también desde un worktree, que está en otro lado).
if [[ -z $HOMEBREW_TAP_DIR ]]; then
  COMMON=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || COMMON=$REPO/.git
  HOMEBREW_TAP_DIR=${COMMON:h:h}/homebrew-tap
fi
TAP=$HOMEBREW_TAP_DIR
CASK_PATH=Casks/$CASK_TOKEN.rb
CASK=$TAP/$CASK_PATH

# ------------------------------------------------------------ el tap está listo

[[ $(git -C "$TAP" rev-parse --show-toplevel 2>/dev/null) == ${TAP:A} ]] \
  || fail "$TAP no es un repo git: define HOMEBREW_TAP_DIR con la carpeta del tap"
git -C "$TAP" ls-files --error-unmatch -- "$CASK_PATH" >/dev/null 2>&1 \
  || fail "$CASK_PATH no existe o no está commiteado en el tap"
(( $(grep -cE '^  version "[^"]*"$' "$CASK") == 1 )) || fail "$CASK_PATH no tiene una sola línea «version»"
(( $(grep -cE '^  sha256 ' "$CASK") == 1 )) || fail "$CASK_PATH no tiene una sola línea «sha256»"
git -C "$TAP" diff --quiet HEAD -- "$CASK_PATH" || fail "$CASK_PATH tiene cambios sin commitear en el tap"
if $PUSH; then
  git -C "$TAP" rev-parse -q --verify '@{upstream}' >/dev/null \
    || fail "la rama del tap no sigue a ninguna remota: no hay adónde subirlo"
  git -C "$TAP" fetch --quiet
  # Al día con su remota: así no se sube de paso un commit de prueba que quedó en el tap.
  [[ $(git -C "$TAP" rev-parse HEAD) == $(git -C "$TAP" rev-parse '@{upstream}') ]] \
    || fail "el tap no está al día con su remota (git -C $TAP status): súbelo o descarta lo que sobra"
fi

if [[ -n $VERSION ]]; then
  [[ $VERSION =~ '^[0-9A-Za-z.+-]+$' ]] || fail "versión no válida: $VERSION"
  # El cask arma la URL del DMG con la versión: el archivo que se publica tiene que llamarse igual.
  URL=$(sed -nE 's/^  url "([^"]*)".*/\1/p' "$CASK")
  [[ -n $URL ]] || fail "$CASK_PATH no tiene una línea «url»"
  EXPECTED=${${URL:t}//\#\{version\}/$VERSION}
  [[ $EXPECTED == ${DMG:t} ]] || fail "el cask baja $EXPECTED, pero el DMG se llama ${DMG:t}"
fi
$CHECK_ONLY && exit 0

# ------------------------------------------------------------ actualizar

[[ -f $DMG ]] || fail "no existe $DMG"
SHA=$(shasum -a 256 "$DMG" | awk '{ print $1 }')

# Se edita una copia y solo si queda válida reemplaza al cask: un error no deja el tap a medias.
EDITED=$(mktemp)
trap 'rm -f "$EDITED"' EXIT
sed -E \
  -e "s/^  version \"[^\"]*\"\$/  version \"$VERSION\"/" \
  -e "s/^  sha256 .*/  sha256 \"$SHA\"/" \
  "$CASK" > "$EDITED"
ruby -c "$EDITED" >/dev/null || fail "el cask editado tiene un error de sintaxis; el tap quedó igual"
cat "$EDITED" > "$CASK"

if git -C "$TAP" diff --quiet -- "$CASK_PATH"; then
  print "El cask ya estaba en $VERSION ($SHA)."
else
  git -C "$TAP" commit --quiet -m "$CASK_TOKEN $VERSION" -- "$CASK_PATH"
  git -C "$TAP" --no-pager show --stat --patch --format='%h %s' HEAD
  print "Cask $CASK_TOKEN $VERSION commiteado en $TAP."
fi

if $PUSH; then
  git -C "$TAP" push --quiet || fail "commiteado, pero no pude subir el tap: git -C $TAP push"
  print "Tap subido."
fi
