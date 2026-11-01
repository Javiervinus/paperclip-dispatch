#!/bin/zsh
# Pone al día el String Catalog de la app con los textos del código, como hace Xcode al compilar, y revisa que
# todos tengan su traducción. El código está en inglés; el catálogo trae el español.
#   macos/strings.zsh          sincroniza Localizable.xcstrings y revisa
#   macos/strings.zsh --check  solo revisa, sin tocar nada (lo usa el CI)
# Falla si un texto no tiene traducción al español, si alguna está marcada para revisar, si quedan textos que el
# código ya no usa o, con --check, si el catálogo no está al día con el código.
#
# El compilador anota cada texto localizable (Text("…"), Button("…"), String(localized: "…")…) con su clave
# exacta (`%@`, `%lld`…) y xcstringstool los suma al catálogo. Un texto nuevo se traduce en el catálogo: con
# Xcode (abriendo Package.swift) o a mano, en el JSON, con "state" : "translated". Un String que llega a
# Text(variable) no se traduce solo: tiene que salir de String(localized:).
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
CATALOG=$ROOT/Sources/PaperclipDispatch/Localizable.xcstrings
LANGUAGES=(es)
CHECK=false
case ${1:-} in
  --check) CHECK=true ;;
  "") ;;
  *) print -u2 "Uso: strings.zsh [--check]"; exit 2 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# En una carpeta de compilación aparte: con otras opciones, la de siempre se recompilaría entera dos veces.
# Sin el llavero: SwiftPM lo consulta al bajar Sparkle y, con la pantalla bloqueada, se queda esperando.
if ! swift build --package-path "$ROOT" --disable-keychain --scratch-path "$WORK/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >"$WORK/build.log" 2>&1
then
  cat "$WORK/build.log" >&2
  exit 1
fi

TARGET=$CATALOG
if $CHECK; then
  TARGET=$WORK/Localizable.xcstrings
  cp "$CATALOG" "$TARGET"
fi
xcrun xcstringstool sync "$TARGET" --stringsdata "$WORK"/strings/*.stringsdata

failed=0
# Se compara el contenido, no el formato: otra versión de Xcode puede escribir el mismo JSON con otro espaciado.
if $CHECK && ! python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' \
  "$CATALOG" "$TARGET"; then
  print -u2 "El catálogo no está al día con el código: corre macos/strings.zsh y traduce lo nuevo."
  failed=1
fi
python3 - "$TARGET" "${LANGUAGES[@]}" <<'PYTHON' || failed=1
import json, sys

catalog = json.load(open(sys.argv[1]))
languages = sys.argv[2:]
problems = []

def units(localization):
    """Los stringUnit de una traducción, también los de sus variantes (plurales, dispositivos)."""
    if "stringUnit" in localization:
        yield localization["stringUnit"]
    for variants in localization.get("variations", {}).values():
        for variant in variants.values():
            yield from units(variant)

for key, entry in catalog["strings"].items():
    if entry.get("extractionState") == "stale":
        problems.append(f"El código ya no lo usa: {key!r}")
        continue
    if entry.get("shouldTranslate") is False:
        continue
    for language in languages:
        localization = entry.get("localizations", {}).get(language)
        found = list(units(localization)) if localization else []
        if not found or any(unit.get("state") != "translated" or not unit.get("value") for unit in found):
            problems.append(f"Sin traducción al {language} (o marcada para revisar): {key!r}")

for problem in problems:
    print(problem, file=sys.stderr)
print(f"{len(catalog['strings'])} textos en el catálogo; {len(problems)} con problemas.")
sys.exit(1 if problems else 0)
PYTHON
exit $failed
