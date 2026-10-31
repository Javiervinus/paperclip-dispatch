# Paperclip.app

Paperclip como app de la Mac, sin tocar su código. Es una ventana de [Pake](https://github.com/tw93/Pake)
(Tauri y Rust) que abre el Paperclip local por su dirección de Tailscale, más un script propio que pone
el número de Decisions en el ícono del Dock y avisa con una notificación de macOS cuando llega una nueva.

La app es solo la ventana: Paperclip corre aparte, como servicio de la sesión (LaunchAgent
`ing.paperclip.paperclipai`), y el iPhone entra por `tailscale serve`. Cerrar la app no apaga Paperclip.

## Armar o rearmar

```sh
./build.sh
```

- Pide Node, Rust (`rustc` 1.85 o más) y `rsvg-convert` (Homebrew `librsvg`).
- La dirección sale de `tailscale serve status` (la entrada que apunta al puerto de Paperclip de
  `~/.paperclip/instances/default/config.json`). No se escribe en el repo.
- Compila en una carpeta temporal, reemplaza `/Applications/Paperclip.app` y borra el caché de Rust
  (~1,5 GB). Tarda unos 2 minutos. Si la app estaba abierta, la cierra solo para reemplazarla y la vuelve a abrir.
- Otra versión de Pake: `PAKE_VERSION=3.18.0 ./build.sh`.

Hay que rearmar solo si cambia el ícono, el script o sale un Pake mejor. Las versiones nuevas de
Paperclip llegan solas: la página viene del servidor y se recarga cuando el servidor se actualiza.

## Archivos

- `icon/icon.svg`: el ícono, con el clip de Paperclip (`favicon.svg` del servidor) sobre la plantilla de
  íconos de macOS. Pake no puede bajar el del sitio porque es privado, y sin esto pone una «T».
  `build.sh` lo convierte en `.icns`, porque a un PNG Pake le aplica su máscara y lo achica.
- `inject/decisions.js`: cada 60 s, y al volver a la ventana, pide `GET /api/companies/{id}/attention`
  (la misma API de la barra lateral) con la sesión de la página.
  - Pone `totalCount` en el ícono del Dock, o sea todo lo pendiente, no solo lo de hoy como la burbuja de Paperclip.
  - Avisa de cada elemento nuevo solo si la ventana no está al frente. Tocar el aviso abre esa decisión.
- `inject/titlebar.css` y `inject/titlebar.js`: la app se arma con `--hide-title-bar`, así que la página
  llega hasta arriba y los botones de la ventana quedan sobre la barra lateral, sin franja aparte.
  - El CSS baja el selector de company dentro de su fila para dejarles lugar. Usa la clase
    `.primary-sidebar-surface` y la variable `--sz-safe-top` de Paperclip. En la vista angosta (menos de
    768 px) baja la página entera.
  - El JS mueve la ventana desde cualquier parte vacía de las dos barras de arriba; con doble clic la
    amplía. Reemplaza la franja de arrastre de Pake, que tapaba los botones de la barra. En pantalla
    completa quita el espacio de los botones.
  - Si una versión nueva de Paperclip cambia esa barra, lo peor que pasa es que los botones se monten
    sobre el selector. Se arregla aquí, sin tocar Paperclip.

## Número en el Dock y avisos

Los dos dependen del permiso de notificaciones de macOS: **Ajustes del Sistema → Notificaciones →
Paperclip → Permitir notificaciones**, con «Mostrar contadores en íconos» activado. Sin ese permiso la
app igual pone el número (`lsappinfo info -only StatusLabel -app com.javiervinueza.paperclip`), pero
macOS no lo dibuja. Si se niega el aviso del primer arranque, macOS no vuelve a preguntar.

## Uso

- Cerrar la ventana (botón rojo o Cmd+W) la esconde, y la app sigue contando y avisando. Cmd+Q la cierra del todo.
- Para quitarla: borrar `/Applications/Paperclip.app`.

## App nativa (prototipo): `macos/`

«Paperclip Swift» (`com.javiervinueza.paperclip.swift`) es la misma idea en Swift y AppKit, sin Pake, para
tener lo que Pake no deja: Liquid Glass y un botón para actualizar Paperclip.

```sh
macos/build.sh
```

- Pide Xcode 26 (SDK de macOS 26) y `rsvg-convert`. Compila con `swift build`, arma el .app, lo firma
  con la identidad «Developer ID Application» del llavero y lo instala en `/Applications`. Tarda
  segundos.
- Variables: `APP_NAME`, `APP_ID`, `INSTALL_DIR` (por defecto `/Applications`), `PAPERCLIP_SERVER_URL`,
  `PAPERCLIP_UPDATE_SCRIPT` y `SIGN_IDENTITY`. Las de una Mac en particular van en `macos/build.local.env`,
  que no se sube. En esta Mac lleva `PAPERCLIP_UPDATE_SCRIPT` con el `update.sh` de
  `Personal/paperclip/scripts`; con `PAPERCLIP_UPDATE_SCRIPT=` (vacía) se arma como para cualquiera.
- **No trae ninguna dirección escrita.** La dirección se guarda en los ajustes de la app (`serverURL`). Si
  un build trae `PAPERCLIP_SERVER_URL`, la app la adopta la primera vez.
- **Bienvenida** (`WelcomeView.swift`, `PaperclipLocator.swift`). Se abre la primera vez y desde Ajustes →
  Paperclip → «Cambiar…». Busca Paperclip donde lo deja su CLI: `~/.paperclip/instances/<id>/`, o
  `PAPERCLIP_HOME` y `PAPERCLIP_INSTANCE_ID` (`config.json`, `runtime-info.json`, y el LaunchAgent
  `ing.paperclip.paperclipai`). Lo comprueba con `GET /api/health`, que no pide sesión.
  - Si responde, ofrece abrirlo con la dirección que da Paperclip (`dashboardUrl`; aquí, la de Tailscale).
  - Si está instalado pero apagado, lo enciende con su servicio (`launchctl kickstart` o `bootstrap`) o, sin
    servicio, con `paperclipai run` en la Terminal. Sigue buscando hasta que responde.
  - Si no está, ofrece instalarlo o escribir la dirección de otro. Instalar revisa Node.js (24.11 o más)
    y abre la Terminal con el comando oficial (`npx paperclipai@latest onboard --yes`: modo local, sin
    contraseña). La Terminal se abre con un `.command` en la caché de la app, sin pedir permisos.
  - Una dirección escrita se guarda solo si responde un Paperclip.
  - La primera vez, cerrar la bienvenida cierra la app. Al cambiar de Paperclip, la app se vuelve a abrir:
    la ventana, los avisos y el bot quedan atados a la dirección con que arrancaron.
- **Sin conexión** (`OfflineView.swift`). Si Paperclip no responde (o un proxy como `tailscale serve`
  contesta 502, 503 o 504), la ventana lo dice en vez de quedar en blanco. Vuelve a probar cada 3 s y
  regresa sola a la página. Ofrece «Reintentar», «Cambiar dirección…» y, si es el de esta Mac y está
  apagado, «Encender Paperclip». Los errores de conexión van traducidos, porque el proceso de red de WebKit
  no usa el idioma de la app.
- **La ventana tiene dos modos** (`MainWindowController.swift`). Por defecto muestra Paperclip tal cual,
  debajo de una barra de ventana de macOS con el título de la página y el botón de la versión: no depende
  de cómo esté hecho el HTML de Paperclip. Solo se inyecta `web/bridge.js`, que no cambia cómo se ve
  (tema y avisos).
- **Liquid Glass en la página, experimental** (Ajustes → General → Experimental, apagado por defecto).
  Retoca la página por dentro, así que una versión nueva de Paperclip lo puede descuadrar. Se aplica al
  momento: cambia la ventana y recarga la página. Con él, la ventana tiene tres capas: abajo, el mismo
  color de fondo de Paperclip; en medio, un panel translúcido con Liquid Glass (`NSGlassEffectView`) justo
  detrás de la barra lateral; arriba, la página transparente.
  - `web/glass.css` le quita el fondo a la barra lateral y fija las medidas: margen del panel, radio
    concéntrico con la ventana y la franja de los botones.
  - `web/glass.js` le avisa a la app dónde está la barra lateral, el color de fondo de Paperclip y desde
    dónde se arrastra la ventana.
  - La ventana lleva una barra de herramientas vacía (`NSToolbar` con estilo `.unified`). No dibuja nada,
    pero hace que macOS 26 redondee más las esquinas (26 pt, como WhatsApp) y baje los botones de la
    ventana dentro del panel, sin moverlos a mano.
  - El arrastre de la ventana solo actúa sobre la página: los botones de la ventana reciben sus clics.
  - En pantalla completa esa barra se esconde y aparece con la barra de menús, como en Safari, y el
    panel toma el color de la ventana en vez del fondo de pantalla.
  - Ensayo visual de los dos modos, también al cambiar de uno a otro con la página cargada:
    `macos/snapshot.zsh window [carpeta]` (ver el ensayo de Ajustes, abajo).
- **Decisions: avisos de macOS y número del Dock.** Los revisa la app misma cada minuto
  (`DecisionsMonitor.swift`), con la sesión de la página y la misma API que la barra lateral. No los revisa
  la página, porque macOS frena las páginas que no se ven: así sigue avisando con la ventana cerrada.
  - Decisions incluye las preguntas y aprobaciones de los agentes, sus fallos y las alertas de presupuesto.
  - La primera vez avisa de lo que ya estaba pendiente (si son más de 3, en un solo aviso). Después, de
    cada decisión nueva, salvo que se esté mirando la ventana. Tocar el aviso abre esa decisión.
- **Decisions en Telegram** (`TelegramChannel.swift`). Cada decisión nueva llega como mensaje, con el
  contexto que escribió el agente y sus botones; lo que se toca ahí se aplica en Paperclip con la sesión de
  la app, a nombre del usuario.
  - El bot es de cada uno: se crea con @BotFather y el token se pega en Ajustes → Telegram. Queda en el
    llavero de la Mac (`Keychain.swift`), nunca en archivos. La app lo atiende con `getUpdates`, así que no
    hace falta una dirección pública ni Tailscale.
  - Para vincular el chat, Ajustes muestra un QR (y un enlace) que abre el bot con un código de un solo
    uso. El bot no le contesta a ningún otro chat.
  - Botones según el tipo (`DecisionResolver.swift`, con la API REST de Paperclip): confirmaciones (con
    los textos del agente y el motivo si lo pide), preguntas de una sola respuesta, aprobaciones y
    decisiones sin campos. Lo demás dice «Se contesta en Paperclip», con el enlace si la dirección no es
    local.
  - Responder con texto a un mensaje de una decisión (mantenerlo apretado → Responder) lo deja como
    comentario en su tarea, y Paperclip despierta al agente. El bot confirma con «💬 Comentario agregado en
    VIN-…».
  - Los botones que piden texto («Hubo un problema», «Otra respuesta…», «Pedir cambios») mandan la
    pregunta con `force_reply`: Telegram abre el teclado ya respondiéndola, con la pista en el campo. Es lo
    más parecido al campo de texto de Paperclip que deja la API de bots.
  - **Es un bot de avisos, no conversa.** Lo que se escribe cuenta solo como el texto que pidió un botón o
    como comentario respondiendo a una decisión. Un mensaje suelto vale como el texto del último botón que
    lo pidió, si fue hace menos de 10 minutos, y el bot contesta a qué decisión fue («✅ Enviado a VIN-…»).
    Si no, no se aplica a nada, porque puede haber varias decisiones abiertas: el bot contesta cómo se usa,
    como mucho una vez al día, y si no, calla. Preguntar lo que sea queda para un agente con su canal
    (OpenClaw, Hermes…).
  - **«Explícamela»** (`DecisionExplainer.swift`) cuenta la decisión en pocas líneas, una vez: de qué trata
    la tarea, qué hizo el agente, qué pide y qué pasa con cada opción.
    - No tiene herramientas, no decide ni escribe en Paperclip. Solo lee el contexto de la
      API oficial (`heartbeat-context`, la misma que leen los agentes, con el resumen que lleva el agente,
      más los últimos comentarios). No depende de ningún plugin.
    - Ajustes → Telegram → **Explicar decisiones**: interruptor, «Con» y «Modelo».
      - «Con»: «Automático» (muestra el CLI detectado: el que más usan los agentes de Paperclip entre los
        instalados), los CLIs instalados (Claude Code, Codex, OpenCode) y «Otro comando…», para cualquier
        otro CLI que reciba el texto por la entrada y responda por la salida.
      - «Modelo»: «Automático» (el que el CLI tenga por defecto) o los que lista cada CLI: alias de Claude
        Code (Opus, Sonnet, Haiku), `codex debug models` y `opencode models` (con sus modelos gratis).
      - El esfuerzo va bajo en Claude y Codex; si un modelo no lo acepta, se reintenta sin él. Tarda de 3 a
        10 s.
    - La app lee el PATH de la terminal (`zsh -l -i`) para encontrar el CLI, porque abierta desde el Dock no
      lo hereda.
  - Cuando se resuelve o se cancela en otro lado, el mensaje se marca «Ya no está pendiente» y pierde los
    botones. Si se toca un botón en ese momento, la app vuelve a revisar y avisa que ya no estaba
    pendiente, sin cambiar nada. Si llegan más de 5 juntas, el resto va en un resumen.
  - Lo enviado y el chat vinculado se guardan en `~/Library/Application Support/<bundle id>/telegram.json`.
- **Ajustes (Cmd+,)** (`SettingsWindowController.swift`, `SettingsView.swift`, `TelegramSettings.swift`).
  Ventana de tamaño fijo, como Ajustes del Sistema: lo que no cabe se desplaza por debajo de la barra.
  - Arriba, un selector de pestañas de Liquid Glass (la barra la arma SwiftUI con `sceneBridgingOptions`).
    Cada pestaña tiñe la parte de arriba de la ventana con su color y el vidrio lo refleja. Al cambiar de
    pestaña, el color y el contenido se funden en una sola animación; la ventana no cambia de tamaño.
  - Las pestañas empiezan directo con su contenido: un encabezado con ícono repetiría el nombre que ya dice
    el selector. Solo Paperclip lleva uno, con el ícono de la app, la versión y su estado, como un «Acerca
    de». Los estados van en su fila, en una cápsula de vidrio («Permitidos», «Al día»). Abre en la última
    pestaña usada.
  - **General:** el tema con miniaturas (Sistema, Claro, Oscuro), abrir al iniciar sesión (`SMAppService`)
    y, en Experimental, Liquid Glass en la página.
    «Sistema» sigue a la Mac aunque cambie por horario; `web/bridge.js` borra el tema que guarda Paperclip
    (`paperclip.theme`) para que la página siga a la app, y si se elige en el menú de Paperclip, la app lo
    adopta como ajuste.
  - **Avisos:** de decisiones, también con la ventana al frente, número del Dock, permiso de macOS y un
    aviso de prueba.
  - **Telegram:** conectar el bot en dos pasos, vincular el chat con el QR (con el avión de Telegram al
    centro, por eso va con corrección alta), y ya conectado: envío, prueba, «Explicar decisiones» y quitar
    el bot (pide confirmación). Al vincular, la pestaña pasa sola a lo de conectado.
  - **Paperclip:** versión, «Actualizar a …» si hay una nueva (lo mismo que el botón de arriba), la
    dirección con botones para copiarla y para cambiarla (abre la bienvenida), y «Buscar ahora», que
    muestra el resultado y la hora ahí mismo, sin alertas.
  - Medidas, colores y tiempos comunes en `SettingsDesign`.
  - Ensayo visual, para revisar el diseño sin tapar nada en pantalla: `macos/snapshot.zsh settings
    [carpeta]` (`Snapshot.swift`). Abre una segunda copia de la app, sin ícono ni foco, que pone cada
    pestaña en una ventana fuera de la pantalla, en claro y en oscuro (Telegram también sin bot y sin
    vincular). El script las captura con `screencapture -l`, que dibuja el vidrio de verdad (la terminal
    necesita permiso de Grabación de pantalla), y la copia se cierra. Solo lee el estado; no atiende el bot
    ni avisa. En las capturas los interruptores y el vidrio salen más apagados, porque la ventana no está
    activa.
    - macOS solo captura ventanas que tocan una pantalla: cada una queda con un punto adentro, en el borde
      izquierdo (`SnapshotableWindow` evita que macOS la acomode). Con la pantalla bloqueada no captura.
    - `window` en vez de `settings` captura la ventana de Paperclip en sus dos modos.
    - `welcome` captura cada paso de la bienvenida, con datos de muestra, y la ventana sin conexión.
    - `SHADOW=1` deja la sombra de la ventana también en `settings`, `window` y `welcome`.
    - Fuera de la pantalla las ventanas salen inactivas (botones e interruptores grises). `ACTIVE=1` las
      muestra de a una en el centro de la pantalla, al frente (el script la pone al frente con System
      Events), para capturas de muestra. Tapa la pantalla unos segundos por ventana: solo cuando nadie usa
      la Mac.
    - `page <ruta>` captura una página de Paperclip con la app, para mostrarla: con los ajustes de la app
      (modo y apariencia), de `SIZE` puntos (por defecto 1512x982) y con la sombra de la ventana, para
      ponerla sobre un fondo. Con `ANCHORS="|En qué se fue la semana"` saca una por ancla, con la página
      desplazada hasta ese texto (vacía = arriba de todo). Ejemplo, la página del plugin de consumo:
      `SIZE=1512x982 ANCHORS="|En qué se fue la semana|Cada semana de" macos/snapshot.zsh page
      /VIN/agent-usage`.
- **La versión de Paperclip, arriba a la derecha** (en la barra de la ventana; con Liquid Glass, sobre la
  barra de la ruta de Paperclip). Si es la última dice «Al día · 2026.1023.0», discreto;
  con un clic vuelve a revisar. Si sale una nueva, cambia a «Actualizar a …», en el color de acento. La app
  revisa con `paperclipai update --check --latest --json` cada 6 h y desde el menú «Buscar actualización de
  Paperclip…». Con Liquid Glass, en la vista angosta de Paperclip (menos de 768 px) no se muestra.
  - Al apretarlo pide confirmación y actualiza con el comando oficial (`paperclipai update --latest`) o,
    si el build trae `PAPERCLIP_UPDATE_SCRIPT`, con ese script, con sus pasos en el botón. El oficial
    respalda la base antes; en modo autenticado con el servicio encendido se revierte solo (bug #13697),
    por eso esta Mac usa `update.sh`.
  - Solo con el Paperclip de esta Mac. Si es el de otra computadora, o falta el comando `paperclipai`
    (instalado con `npx` no queda), no hay botón y Ajustes explica por qué (y cómo instalarlo).
  - Nunca actualiza sola, porque reiniciar Paperclip corta lo que estén haciendo los agentes.
  - Ensayo, para verlo sin esperar una versión: con la app cerrada,
    `open -a "Paperclip Swift" --args -PaperclipPreviewUpdate 2026.1101.0`. Finge esa versión y
    «Actualizar» muestra los pasos del script sin correrlo. Se sale cerrando la app (Cmd+Q).
- Al estrenarla pide iniciar sesión una vez, porque no comparte los datos de la app de Pake. Con las dos
  abiertas, los avisos llegan dos veces. La de Pake sigue usando `inject/decisions.js`.
- `scripts/make-icns.zsh` sirve a los dos builds; `scripts/server-url.zsh`, solo a la de Pake.
