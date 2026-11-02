// Los avisos de ejemplo del hero, como los de macOS: llegan de a uno arriba y empujan a los demás hacia abajo;
// en la pila caben tres y el más viejo se pliega al fondo. Se cierran con la X, con un clic (como al abrirlos) o
// deslizándolos a la derecha. «Wake up CEO» cierra el suyo y trae la respuesta de Paperclip, como en la app.
// Sin JS quedan los tres de la página, quietos. Con «reducir movimiento» no llegan solos: solo se reponen cuando
// cierras uno. Se detienen con el botón «Pause», fuera de la vista y con la pestaña oculta; mientras el mouse está
// sobre un aviso o el teclado recorre la pila, el que sigue espera. Los textos (también la X y el botón de pausa)
// vienen del HTML, así sirve igual en /es/.
const desk = document.querySelector(".desk");

if (desk) {
  const stack = desk.querySelector(".stack");
  const deck = desk.querySelector("template.deck");
  const note = desk.querySelector(".desk-note");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  // En un teléfono, :hover queda pegado después de un toque: ahí no cuenta
  const mouse = matchMedia("(hover: hover) and (pointer: fine)");
  const capacity = 3;
  // Cada cuánto llega uno con la pila llena, con lugar libre (más rápido, para que se llene) y con la pila vacía
  // (enseguida: que no quede el hueco)
  const every = 4200;
  const refill = 1500;
  const empty = 900;
  // Después de cerrar uno o despertar a alguien, si quedan avisos, el que sigue espera esto: que no llegue uno justo
  // donde ibas a tocar
  const settle = 2500;
  // Cada cuánto vuelve a mirar si ya puede llegar el que sigue, mientras el mouse o el teclado están encima
  const recheck = 400;
  // Lo que tarda la respuesta de Paperclip después de «Wake up CEO»
  const replyDelay = 700;
  // Un aviso que se fue no vuelve antes de esto (si hay otro que pueda llegar)
  const rest = 15000;
  const { closeLabel, pauseLabel, resumeLabel } = desk.dataset;

  // Un modelo por tipo de aviso: los de la página y los de la plantilla. Los que son respuesta (data-reply) no
  // llegan solos.
  const models = new Map();
  for (const item of [...stack.children, ...deck.content.children]) {
    models.set(item.dataset.kind, item.cloneNode(true));
  }
  const cycle = [...models.keys()].filter((kind) => !models.get(kind).hasAttribute("data-reply"));
  // El primero que llega es el que sigue a los de la página
  let next = stack.children.length;
  let live = [];
  // Cuándo se fue cada tipo de aviso
  const leftAt = new Map();
  let timer = 0;
  let paused = false;
  let inView = true;

  const closeIcon = '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M2.75 2.75l4.5 4.5M7.25 2.75l-4.5 4.5"/></svg>';

  // Le da a un aviso sus botones: la acción (si tiene) y la X
  const upgrade = (card) => {
    card.classList.add("is-live");
    const action = card.querySelector("span.notice-action");
    if (action) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "notice-action";
      button.textContent = action.textContent;
      button.dataset.then = action.dataset.then;
      action.replaceWith(button);
    }
    const close = document.createElement("button");
    close.type = "button";
    close.className = "notice-close";
    close.setAttribute("aria-label", closeLabel);
    close.innerHTML = closeIcon;
    card.append(close);
    return card;
  };

  const place = () => live.forEach((card, slot) => card.style.setProperty("--slot", slot));

  // Se va: deslizándose a la derecha (cerrar), hundiéndose al fondo de la pila (plegarse, cuando llega uno con la
  // pila llena) o achicándose donde está (abrirlo con un clic)
  const leave = (card, how = "is-leaving") => {
    // Si lo estabas recorriendo con el teclado, el foco pasa al siguiente (o al botón de pausa) en vez de perderse
    const keyboard = card.querySelector(":focus-visible");
    live = live.filter((other) => other !== card);
    leftAt.set(card.dataset.kind, performance.now());
    card.inert = true;
    if (how === "is-folding") card.style.setProperty("--slot", capacity - 0.75);
    card.classList.add(how);
    const done = () => card.remove();
    card.addEventListener("transitionend", done, { once: true });
    setTimeout(done, 700);
    place();
    if (keyboard) (live[0]?.querySelector(".notice-close") ?? note.querySelector(".desk-pause"))?.focus({ preventScroll: true });
    if (reduce.matches && !timer) schedule(refill);
  };

  const arrive = (kind) => {
    // Como en macOS, uno nuevo del mismo tipo reemplaza al que ya estaba
    const twin = live.find((card) => card.dataset.kind === kind);
    if (twin) leave(twin, "is-opening");
    const card = upgrade(models.get(kind).cloneNode(true));
    card.classList.add("is-entering");
    card.style.setProperty("--slot", 0);
    stack.prepend(card);
    live.unshift(card);
    if (live.length > capacity) leave(live[live.length - 1], "is-folding");
    place();
    // Que el navegador vea el punto de partida antes de soltarlo
    card.getBoundingClientRect();
    card.classList.remove("is-entering");
  };

  // El siguiente del ciclo que no esté en la pila y no se haya ido hace poco; si todos se fueron hace poco, el que
  // se fue hace más tiempo
  const deliver = () => {
    const now = performance.now();
    let fallback = null;
    for (let tries = 0; tries < cycle.length; tries++) {
      const kind = cycle[(next + tries) % cycle.length];
      if (live.some((card) => card.dataset.kind === kind)) continue;
      const left = leftAt.get(kind) ?? -Infinity;
      if (now - left >= rest) {
        next += tries + 1;
        return arrive(kind);
      }
      if (!fallback || left < fallback.left) fallback = { kind, left };
    }
    if (fallback) arrive(fallback.kind);
  };

  const running = () => !paused && inView && !document.hidden;
  // El mouse sobre un aviso o el foco del teclado en la pila (el de un clic o un toque no se ve, y no cuenta)
  const held = () => (mouse.matches && stack.querySelector(".notice.is-live:hover")) || desk.querySelector(":focus-visible");
  const gap = () => (live.length === 0 ? empty : live.length < capacity ? refill : every);

  function schedule(delay) {
    clearTimeout(timer);
    timer = setTimeout(() => {
      timer = 0;
      if (reduce.matches) {
        if (live.length < capacity) deliver();
        if (live.length < capacity) schedule(refill);
        return;
      }
      // Pausado, fuera de la vista o en otra pestaña: vuelve con resume()
      if (!running()) return;
      if (held()) return schedule(recheck);
      deliver();
      schedule(gap());
    }, delay);
  }

  // Al volver (quitar la pausa, volver a la vista o a la pestaña), el que sigue espera media vuelta, o casi nada si
  // la pila está vacía
  const resume = () => {
    if (timer || !running() || reduce.matches) return;
    schedule(live.length ? every / 2 : empty);
  };
  const halt = () => {
    if (reduce.matches) return;
    clearTimeout(timer);
    timer = 0;
  };
  // Después de cerrar uno o despertar a alguien
  const acted = (wait = 0) => {
    if (reduce.matches) return;
    schedule(Math.max(wait, live.length ? settle : empty));
  };

  // Los de la página pasan a ser avisos vivos, sin moverse de su lugar
  live = [...stack.children].map(upgrade);
  place();

  stack.addEventListener("click", (event) => {
    const card = event.target.closest(".notice.is-live");
    if (!card) return;
    const action = event.target.closest(".notice-action");
    if (action) {
      leave(card);
      // La respuesta de Paperclip llega primero; el que sigue, después
      acted(replyDelay + refill);
      const reply = action.dataset.then;
      if (models.has(reply)) setTimeout(() => arrive(reply), replyDelay);
    } else if (event.target.closest(".notice-close")) {
      leave(card);
      acted();
    }
  });

  // Deslizar a la derecha lo cierra; un toque sin moverse lo «abre» (en macOS, el aviso se va y se abre la app)
  stack.addEventListener("pointerdown", (event) => {
    const card = event.target.closest(".notice.is-live");
    if (!card || event.button !== 0 || event.target.closest("button")) return;
    const startX = event.clientX;
    const startTime = performance.now();
    let dx = 0;
    let dragging = false;
    card.setPointerCapture(event.pointerId);

    const move = (moved) => {
      dx = moved.clientX - startX;
      if (!dragging && Math.abs(dx) > 4) {
        dragging = true;
        card.classList.add("is-dragging");
      }
      // Hacia la izquierda se resiste: ahí no hay adónde ir
      if (dragging) card.style.transform = "translateX(" + (dx < 0 ? dx / 4 : dx) + "px)";
    };
    const end = (ended) => {
      card.removeEventListener("pointermove", move);
      card.removeEventListener("pointerup", end);
      card.removeEventListener("pointercancel", end);
      const speed = dx / Math.max(1, performance.now() - startTime);
      card.classList.remove("is-dragging");
      card.style.transform = "";
      if (!dragging) {
        if (ended.type === "pointerup") {
          leave(card, "is-opening");
          acted();
        }
      } else if (dx > card.offsetWidth * 0.3 || speed > 0.6) {
        leave(card);
        acted();
      }
    };
    card.addEventListener("pointermove", move);
    card.addEventListener("pointerup", end);
    card.addEventListener("pointercancel", end);
  });

  new IntersectionObserver(([entry]) => {
    inView = entry.isIntersecting;
    if (inView) resume();
    else halt();
  }).observe(desk);
  document.addEventListener("visibilitychange", () => (document.hidden ? halt() : resume()));

  // Pausar (WCAG 2.2.2): solo hace falta cuando llegan solos
  const pause = document.createElement("button");
  pause.type = "button";
  pause.className = "desk-pause";
  pause.textContent = pauseLabel;
  pause.addEventListener("click", () => {
    paused = !paused;
    pause.textContent = paused ? resumeLabel : pauseLabel;
    if (paused) halt();
    else resume();
  });
  const showPause = () => {
    pause.hidden = reduce.matches;
  };
  note.append(" ", pause);
  showPause();
  reduce.addEventListener("change", () => {
    showPause();
    halt();
    resume();
  });

  // El primero llega cuando terminan de entrar los de la página
  if (!reduce.matches) schedule(every);
}
