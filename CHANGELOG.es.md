# Cambios

Lo que cambió para quien usa Paperclip Dispatch, en palabras simples. Lo que nadie puede notar queda
fuera a propósito. Paperclip tiene sus propias versiones y sus propias novedades; no van aquí.

Paperclip Dispatch sigue el [versionado semántico](https://semver.org/lang/es/). Las fechas van en
ISO 8601. Las mismas novedades están en inglés en [CHANGELOG.md](CHANGELOG.md): las dos van a la par.

La app muestra la sección más nueva en su panel de actualizaciones, así que cada punto empieza con una
frase en negrita que se entiende sola y suma una o dos más, como mucho. Desde el sexto punto, el panel
manda aquí.

## 0.4.2 — 2026-11-07

### Arreglado

- **Actualizar Paperclip desde la app ya funciona.** Cuando Paperclip pide iniciar sesión, su propio
  actualizador no lograba confirmar la versión nueva, deshacía la actualización al minuto y dejaba Paperclip
  en la anterior. Ahora la app respalda la base de datos, detiene Paperclip, lo actualiza y lo vuelve a
  arrancar, mostrando cada paso.

## 0.4.1 — 2026-11-07

### Arreglado

- **Una versión nueva de Paperclip ya no aparece como error.** Cuando salía una, el panel de
  actualizaciones decía «No pude revisar Paperclip» con la respuesta en bruto de Paperclip, en vez de ofrecer
  actualizar.

## 0.4.0 — 2026-11-02

### Nuevo

- **Actualiza los plugins de Paperclip desde su propio botón.** Un botón chico con una pieza, al lado del de
  actualizaciones, lista todos los plugins, y los instalados desde npm muestran su versión nueva con un botón
  «Actualizar»: Paperclip cambia el plugin sin detener a tus agentes. Una versión nueva de un plugin solo le
  pone un punto a ese botón, y la lista se desplaza en vez de crecer, por muchos plugins que tengas.
- **La app te avisa cuando sale una versión nueva.** De la app, de Paperclip o de un plugin, una vez por
  versión y sin sonido: abajo en la ventana si la estás mirando y, si no, en un aviso de la Mac, y la ventana
  te lo muestra al volver. Los plugins van juntos y como mucho una vez al día; la campana del panel de
  actualizaciones lo apaga.

### Cambios

- **La palomita de lo que está al día va en negro o en blanco, según el tema.** El color queda para lo que te
  necesita.

## 0.3.0 — 2026-11-02

### Nuevo

- **Los plugins de Paperclip que escriben con la IA de Chrome funcionan en la app, con Apple Intelligence.**
  Los que la usan, como las conversaciones de Oficina global, reciben el modelo de esta Mac, sin bajar nada.
  Necesita Apple Intelligence activado en Ajustes del Sistema.
- **Los plugins te pueden avisar en la Mac, si los dejas.** Un plugin que pide mostrar avisos, como el aviso
  del sistema de Oficina global, ahora manda avisos de la Mac en vez de quedar «Bloqueado», y un clic te lleva
  a él. Se apagan en Ajustes → Avisos.

### Arreglado

- **Las versiones nuevas te llegan en menos de una hora.** La app las busca cada hora y no cada seis, así
  que ya no hace falta «Buscar ahora» para tener una el mismo día que sale.
- **La vista 3D de un plugin sigue al mouse.** Como en Chrome, un clic captura el puntero para mirar
  alrededor y Esc lo suelta; antes había que arrastrar.
- **Los PDF tienen cómo volver y su botón de descargar funciona.** Un PDF o cualquier otro archivo que se
  abre desde Paperclip muestra un botón de atrás junto a los de la ventana, y el de descargar del visor
  pregunta dónde guardarlo.
- **El visor de imágenes ya no choca con los botones de la ventana.** El nombre del archivo queda a su
  derecha, como el título de una ventana.

## 0.2.0 — 2026-11-01

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
- **Se despierta al agente que Paperclip olvida.** Cuando Paperclip 2026.1023.0 le pasa una tarea a un agente
  (a revisión, de vuelta a quien la hizo o a alguien nuevo) y pierde su despertar, la app lo despierta una
  vez, sin avisar, a los dos minutos; si eso falla, o si no puede leer lo que contesta Paperclip, te llega el
  aviso de la tarea trabada. Viene activado y se apaga en Ajustes → Paperclip.
- **«Ver en vivo» en las tarjetas cuya tarea tiene algo servido para mirar.** Cuando un agente registra en la
  tarea una vista de su trabajo (una página, una app web), el aviso de la Mac trae una acción que la abre, y
  el mensaje de Telegram de su decisión o de la tarea asignada, un enlace junto a la descripción, en todos los
  pasos de una tarjeta de varios pasos. Una dirección `localhost` solo se abre desde la Mac.
- **Te enteras cuando un agente llega a su tope diario de corridas.** Paperclip se salta entonces todo lo que
  lo despertaría, sin decirlo: un aviso en la Mac y un mensaje en Telegram dicen qué agente es, su tope y a qué
  hora se reinicia la cuenta, con un botón a su página para subirlo. Una vez al día por agente, y se apaga en
  Ajustes → Avisos.
- **Si Paperclip cambia lo que contesta, lo nuevo se aparta en vez de adivinar.** Una tarjeta, un botón o un
  aviso que la app no sabe leer bien vuelve a «Abrir en Paperclip», y si Paperclip rechaza una respuesta, el
  mensaje dice que no se pudo y ofrece abrirla ahí.

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
