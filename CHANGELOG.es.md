# Cambios

Lo que cambió para quien usa Paperclip Dispatch, en palabras simples. Lo que nadie puede notar queda
fuera a propósito. Paperclip tiene sus propias versiones y sus propias novedades; no van aquí.

Paperclip Dispatch sigue el [versionado semántico](https://semver.org/lang/es/). Las fechas van en
ISO 8601. Las mismas novedades están en inglés en [CHANGELOG.md](CHANGELOG.md): las dos van a la par.

La app muestra la sección más nueva en su panel de actualizaciones, así que cada punto empieza con una
frase en negrita que se entiende sola y suma una o dos más, como mucho. Desde el sexto punto, el panel
manda aquí.

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
