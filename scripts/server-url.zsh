#!/bin/zsh
# Imprime la dirección de Paperclip por Tailscale: la entrada de `tailscale serve` que apunta al puerto
# de Paperclip, leído de su config.json. La usan los dos builds; la dirección no se escribe en el repo.
set -eo pipefail

PAPERCLIP_CONFIG=${PAPERCLIP_CONFIG:-$HOME/.paperclip/instances/default/config.json}

port=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["server"]["port"])' "$PAPERCLIP_CONFIG")
url=$(tailscale serve status --json | python3 -I -c '
import json, sys
port = sys.argv[1]
for hostport, web in json.load(sys.stdin).get("Web", {}).items():
    proxy = web.get("Handlers", {}).get("/", {}).get("Proxy", "").rstrip("/")
    if proxy.endswith(":" + port):
        print("https://" + hostport.removesuffix(":443"))
        break
' "$port")
if [[ -z $url ]]; then
  print -u2 "No hay una entrada de tailscale serve hacia el puerto $port de Paperclip."
  exit 1
fi
print -r -- "$url"
