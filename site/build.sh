#!/usr/bin/env bash
# Arma la landing en una carpeta lista para servir o publicar (GitHub Pages): copia las páginas, estilos y
# scripts de site/, trae de docs/images solo las capturas que usa la página (docs/images es su única fuente:
# no se copian al repo) y llena los datos que no se escriben a mano.
#   site/build.sh                           deja la página en _site/ (ignorada por git)
#   OUTPUT_DIR=/tmp/landing site/build.sh   en otra carpeta (vacía, nueva o armada antes por este script)
# Para verla: python3 -m http.server 8080 --bind 127.0.0.1 --directory _site
#
# Los datos salen de:
#   %%REPO_URL%%    REPOSITORY_URL de macos/release.env (vacío: el remoto origin, si está en GitHub)
#   %%VERSION%%     el último release publicado en GitHub (tag_name, sin la «v»)
#   %%DMG_URL%%     el .dmg de ese release
#   %%BREW_CASK%%   <dueño en minúsculas>/tap/<cask>: el tap <dueño>/homebrew-tap y el cask que nombra
#                   macos/update-cask.sh (APP_NAME en minúsculas y con guiones). HOMEBREW_TAP y CASK_TOKEN lo cambian.
# Si GitHub no responde (sin red, límite de la API), el botón apunta a releases/latest y la versión se quita.
# GITHUB_TOKEN, si está, se usa para la API (en Actions evita el límite de pedidos).
set -euo pipefail

SITE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(dirname "$SITE")
MARKER=.landing-build

fail() { echo "build.sh: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "falta jq"

# La carpeta de salida, como ruta absoluta. Solo se borra si está vacía o la armó este script (MARKER).
OUTPUT_DIR=${OUTPUT_DIR:-$ROOT/_site}
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P)
case "$ROOT/" in "$OUTPUT_DIR"/*) fail "OUTPUT_DIR no puede ser el repo ni una carpeta que lo contenga: $OUTPUT_DIR" ;; esac
case "$OUTPUT_DIR/" in "$SITE"/*) fail "OUTPUT_DIR no puede estar dentro de site/: $OUTPUT_DIR" ;; esac
if [[ -n $(ls -A "$OUTPUT_DIR") && ! -f $OUTPUT_DIR/$MARKER ]]; then
  fail "$OUTPUT_DIR no está vacía y no la armó este script; usa otra carpeta"
fi

# shellcheck source=../macos/release.env
source "$ROOT/macos/release.env"
if [[ -z ${RELEASES_REPO:-} ]]; then
  # Como build.sh de la app: sin repo propio, el del remoto origin si está en GitHub.
  origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
  [[ $origin =~ github\.com[:/]([^/]+/[^/]+)$ ]] && RELEASES_REPO=${BASH_REMATCH[1]%.git}
fi
[[ -n ${RELEASES_REPO:-} ]] || fail "no hay repo de GitHub: RELEASES_REPO de macos/release.env está vacío y origin no es de GitHub"
REPOSITORY_URL=${REPOSITORY_URL:-https://github.com/$RELEASES_REPO}
OWNER=${RELEASES_REPO%%/*}
APP_NAME=${APP_NAME:-Paperclip Dispatch}
HOMEBREW_TAP=${HOMEBREW_TAP:-$(tr '[:upper:]' '[:lower:]' <<<"$OWNER")/tap}
CASK_TOKEN=${CASK_TOKEN:-$(tr '[:upper:]' '[:lower:]' <<<"$APP_NAME" | tr ' ' '-')}

# La última versión publicada y su DMG
VERSION=
DMG_URL=
auth=()
[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
if release=$(curl -fsSL --max-time 20 ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$RELEASES_REPO/releases/latest" 2>/dev/null); then
  VERSION=$(jq -r '.tag_name // empty | ltrimstr("v")' <<<"$release" 2>/dev/null || true)
  DMG_URL=$(jq -r '[(.assets // [])[] | select(.name | endswith(".dmg")) | .browser_download_url][0] // empty' \
    <<<"$release" 2>/dev/null || true)
fi
if [[ -z $VERSION || -z $DMG_URL ]]; then
  echo "build.sh: no pude leer el último release de $RELEASES_REPO; el botón va a releases/latest, sin versión" >&2
  VERSION=
  DMG_URL=$REPOSITORY_URL/releases/latest
fi

# Desde cero
find "$OUTPUT_DIR" -mindepth 1 -delete
touch "$OUTPUT_DIR/$MARKER"
mkdir -p "$OUTPUT_DIR/images"

# Solo lo que se publica: páginas, estilos y scripts, sin archivos ocultos ni este script
(cd "$SITE" && find . -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' \) ! -path '*/.*' -print0 |
  while IFS= read -r -d '' file; do
    mkdir -p "$OUTPUT_DIR/$(dirname "$file")"
    cp "$file" "$OUTPUT_DIR/$file"
  done)

# Las capturas que nombra la página, tal como están en docs/images
images=$(grep -rhoE 'images/[A-Za-z0-9._-]+\.png' "$OUTPUT_DIR" --include='*.html' --include='*.css' | sort -u)
for image in $images; do
  [[ -f $ROOT/docs/$image ]] || fail "la página usa $image y no está en docs/images"
  cp "$ROOT/docs/$image" "$OUTPUT_DIR/$image"
done

# Los datos
escape() { sed -e 's/[\/&|]/\\&/g' <<<"$1"; }
pages=0
while IFS= read -r -d '' page; do
  pages=$((pages + 1))
  if [[ -n $VERSION ]]; then
    sed -i.bak -e "s|%%VERSION%%|$(escape "$VERSION")|g" "$page"
  else
    # Sin versión se quita el elemento que la muestra, no la línea entera
    sed -i.bak -E -e 's|<span class="build-version[^"]*">[^<]*</span>||g' "$page"
  fi
  sed -i.bak \
    -e "s|%%REPO_URL%%|$(escape "$REPOSITORY_URL")|g" \
    -e "s|%%DMG_URL%%|$(escape "$DMG_URL")|g" \
    -e "s|%%BREW_CASK%%|$(escape "$HOMEBREW_TAP/$CASK_TOKEN")|g" \
    "$page"
  rm -f "$page.bak"
  if grep -n '%%[A-Z_]*%%' "$page" >&2; then fail "quedaron datos sin llenar en ${page#"$OUTPUT_DIR"/}"; fi
done < <(find "$OUTPUT_DIR" -name '*.html' -print0)
(( pages > 0 )) || fail "no quedó ninguna página en $OUTPUT_DIR"

echo "Página armada en $OUTPUT_DIR (versión ${VERSION:-sin número}, $(wc -w <<<"$images" | tr -d ' ') capturas)"
echo "Descarga: $DMG_URL"
