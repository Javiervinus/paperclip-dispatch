# Cambios

Lo que cambió para quien usa Paperclip Dispatch, en palabras simples. Lo que nadie puede notar queda
fuera a propósito. Paperclip tiene sus propias versiones y sus propias novedades; no van aquí.

Paperclip Dispatch sigue el [versionado semántico](https://semver.org/lang/es/). Las fechas van en
ISO 8601. Las mismas novedades están en inglés en [CHANGELOG.md](CHANGELOG.md): las dos van a la par.

La app muestra la sección más nueva en su panel de actualizaciones, así que cada punto empieza con una
frase en negrita que se entiende sola y suma una o dos más, como mucho. Desde el sexto punto, el panel
manda aquí.

## Unreleased

### Nuevo

- **Contesta desde Telegram las tarjetas de varios pasos de Paperclip.** Los formularios de varias
  preguntas, las tareas sugeridas, las casillas, las revisiones por ítem y las decisiones con campos llegan
  en un solo mensaje que se va actualizando. A Paperclip no le llega nada hasta el botón final, así que el
  agente despierta una sola vez.
- **Te enteras de las tareas que un agente te asigna.** Un aviso en la Mac y un mensaje en Telegram dicen
  qué tarea es, quién te la asignó, su proyecto y cómo empieza; responde al mensaje para comentar en la
  tarea. Cuando se cierra o se reasigna, el mensaje lo dice. Las que te asignas tú no avisan, y se apaga en
  Ajustes → Avisos.
- **Más decisiones se contestan desde Telegram.** Las solicitudes de acceso, las revisiones que te esperan,
  las aprobaciones de board, las corridas fallidas, los errores de agentes y los topes de presupuesto traen
  sus propios botones, y «Despertar» solo aparece si el agente no va en camino: si tiene una corrida en
  cola o en curso, el mensaje y el aviso de la Mac lo dicen en su lugar.
- **«Ver en vivo» en las tarjetas cuya tarea tiene algo servido para mirar.** Cuando un agente registra en la
  tarea una vista de su trabajo (una página, una app web), el aviso de la Mac y el mensaje de Telegram de su
  decisión o de la tarea asignada traen un botón que la abre, en todos los pasos de una tarjeta de varios
  pasos. Una dirección `localhost` lleva el botón solo en la Mac.
- **Te enteras cuando un agente llega a su tope diario de corridas.** Paperclip se salta entonces todo lo que
  lo despertaría, sin decirlo: un aviso en la Mac y un mensaje en Telegram dicen qué agente es, su tope y a qué
  hora se reinicia la cuenta, con un botón a su página para subirlo. Una vez al día por agente, y se apaga en
  Ajustes → Avisos.

### Arreglado

- **Las decisiones llegan a Telegram con sus botones, y una pregunta de texto tiene un solo botón para
  escribir.** Hasta ahora, las decisiones decían «Se contesta en Paperclip» aunque se podían contestar desde
  Telegram.

## 0.1.0 — 2026-11-01

La primera versión. Todo lo de abajo es nuevo, así que esta entrada describe la app en vez de listar
cambios.

### Nuevo

- **Paperclip en su propia ventana de Mac.** Una app nativa en vez de una pestaña del navegador:
  Paperclip ocupa la ventana entera, sin barra de título, en su blanco y negro y con Liquid Glass y los
  menús, atajos y ventanas de la Mac.
- **Las decisiones sin tener que mirar.** Un aviso de macOS cuando un agente pregunta algo, pide una
  aprobación o falla, o cuando salta una alerta de presupuesto, y en el ícono del Dock el mismo número que
  Decisions en la barra lateral de Paperclip.
- **Responder desde Telegram.** Vincula un bot de Telegram para recibir cada decisión en el teléfono y
  aprobarla, rechazarla, responderla o pedir «explícamela» desde ahí.
- **Destrabar una tarea con un clic.** Cuando una tarea queda trabada a nombre de un agente (p. ej. un
  revisor que Paperclip no despertó), el aviso de la Mac y el mensaje de Telegram traen un botón para
  despertar a ese agente y te dicen si Paperclip lo despertó o lo saltó.
- **Una bienvenida que te deja listo.** La primera vez la app se presenta, encuentra Paperclip en esta Mac
  (lo enciende, ayuda a instalarlo o toma la dirección de otro) y muestra cómo se ven los avisos antes de
  pedirlos. Si quedan apagados, te lo recuerda, sin estorbar.
- **Las actualizaciones de los dos, en un solo lugar.** El botón de arriba a la derecha muestra la versión
  de Paperclip y la de esta app. Paperclip se actualiza solo cuando tú dices; la app baja sus versiones
  sola y las instala cuando la reinicias o la cierras.
- **En inglés o en español.** La app sigue el idioma de la Mac, y el bot de Telegram y sus respuestas a
  «explícamela» también.
