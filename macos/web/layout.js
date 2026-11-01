// Paperclip Dispatch: le cuenta a la app lo que necesita saber de la página.
//
// - El alto de las barras de arriba y si la página está en su vista de escritorio, para el botón de la
//   versión.
// - Si el puntero está sobre una parte vacía de esas barras: desde ahí se mueve la ventana, que no tiene
//   barra de título. La app decide en el clic mismo, así que se avisa al mover el puntero.
// - Para Liquid Glass: dónde están la barra lateral y el panel de propiedades de una tarea, para poner un
//   panel de vidrio justo detrás de cada uno (glass.css les quita el fondo), y el color de fondo de
//   Paperclip, que la app pinta alrededor.
(() => {
  if (window.top !== window || window.__paperclipDispatchLayout) return;
  window.__paperclipDispatchLayout = true;
  const handler = window.webkit?.messageHandlers?.paperclipDispatch;
  if (!handler) return;

  const post = (message) => handler.postMessage(message);

  // Paperclip pasa a su vista móvil bajo 768 px (MOBILE_BREAKPOINT de SidebarContext): ahí la barra
  // lateral es un cajón y no lleva vidrio.
  const desktop = window.matchMedia("(min-width: 768px)");
  // Cada cuánto se vuelve a mirar la página por si cambió sin aviso (ver start).
  const RECHECK_INTERVAL_MS = 1000;
  // Las dos barras de arriba (cabecera de Sidebar y BreadcrumbBar) miden --sz-60px. Otros elementos
  // usan min-h-(--sz-60px), por eso además tienen que empezar arriba de todo.
  const TOP_BAR_SELECTOR = '[class*="h-(--sz-60px)"]';
  const INTERACTIVE_SELECTOR = [
    "a",
    "button",
    "input",
    "select",
    "textarea",
    "label",
    "summary",
    '[role="button"]',
    '[role="link"]',
    '[role="menuitem"]',
    '[role="tab"]',
    '[role="separator"]',
    '[contenteditable=""]',
    '[contenteditable="true"]',
  ].join(", ");

  const cssPixels = (name) =>
    parseFloat(getComputedStyle(document.documentElement).getPropertyValue(name)) || 0;

  // Un lienzo de 1×1 pasa cualquier color de CSS (oklch, color(), nombres) a bytes sRGB.
  let colorProbe = null;
  const cssColorBytes = (name) => {
    const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    if (!value) return null;
    colorProbe ??= Object.assign(document.createElement("canvas"), { width: 1, height: 1 }).getContext("2d", {
      willReadFrequently: true,
    });
    if (!colorProbe) return null;
    colorProbe.clearRect(0, 0, 1, 1);
    colorProbe.fillStyle = "#000";
    colorProbe.fillStyle = value;
    colorProbe.fillRect(0, 0, 1, 1);
    const [red, green, blue] = colorProbe.getImageData(0, 0, 1, 1).data;
    return [red, green, blue];
  };

  // El espacio que SidebarShell reserva a la barra lateral (ancho completo o riel). Si la barra se asoma
  // sobre el contenido, ese panel flota con fondo propio y el vidrio se queda en lo reservado.
  const sidebarArea = () =>
    document.querySelector(".primary-sidebar-surface")?.parentElement?.parentElement?.parentElement ?? null;
  // El panel de propiedades de una tarea o el de tareas del chat (SidePanelFrame de Paperclip): su <aside>,
  // solo al costado. Maximizado (o mientras se agranda o se achica) Paperclip lo pone fijo encima del
  // contenido, y ahí el vidrio, que va detrás de toda la página, dejaría ver lo de abajo.
  const inspectorArea = () => {
    for (const section of document.querySelectorAll(
      'section[data-presentation="docked"][data-maximized="false"]',
    )) {
      const aside = section.closest("aside");
      if (aside && !aside.classList.contains("fixed") && aside.getBoundingClientRect().width > 0) return aside;
    }
    return null;
  };

  let titlebar = 0;
  let lastLayout = "";
  let observed = [];
  let pending = 0;

  // Se vigila el tamaño de los paneles, que cambian sin que cambie la ventana (al plegar la barra o
  // arrastrar el borde del panel de propiedades).
  const observe = (areas) => {
    const next = areas.filter(Boolean);
    observed.filter((area) => !next.includes(area)).forEach((area) => resizeObserver.unobserve(area));
    next.filter((area) => !observed.includes(area)).forEach((area) => resizeObserver.observe(area));
    observed = next;
  };

  const rectOf = (area) => {
    const rect = area?.getBoundingClientRect();
    return rect && rect.width > 0 && rect.height > 0
      ? { x: rect.left, y: rect.top, width: rect.width, height: rect.height }
      : null;
  };

  const report = () => {
    pending = 0;
    titlebar = cssPixels("--paperclip-dispatch-titlebar");
    const sidebar = desktop.matches ? sidebarArea() : null;
    const inspector = desktop.matches ? inspectorArea() : null;
    observe([sidebar, inspector]);
    const inset = cssPixels("--paperclip-dispatch-sidebar-inset");
    const message = {
      type: "layout",
      desktop: desktop.matches,
      background: cssColorBytes("--background"),
      topBar: cssPixels("--sz-60px"),
      inset,
      radius: Math.max(0, cssPixels("--paperclip-dispatch-window-radius") - inset),
      sidebar: rectOf(sidebar),
      inspector: rectOf(inspector),
    };
    const key = JSON.stringify(message);
    if (key === lastLayout) return;
    lastLayout = key;
    post(message);
  };

  const schedule = () => {
    if (!pending) pending = requestAnimationFrame(report);
  };
  const resizeObserver = new ResizeObserver(schedule);

  let overDragArea = false;
  const setDragArea = (value) => {
    if (value === overDragArea) return;
    overDragArea = value;
    post({ type: "dragArea", value });
  };
  const isDragArea = (event) => {
    const target = event.target;
    if (!(target instanceof Element) || target.closest(INTERACTIVE_SELECTOR)) return false;
    if (event.clientY < titlebar) return true;
    const bar = target.closest(TOP_BAR_SELECTOR);
    return Boolean(bar) && bar.getBoundingClientRect().top <= titlebar;
  };

  const start = () => {
    report();
    window.addEventListener("resize", schedule);
    desktop.addEventListener("change", schedule);
    new MutationObserver(schedule).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class"],
    });
    // Paperclip arma y cambia la interfaz sin recargar (React): se revisa seguido y solo se avisa si
    // algo cambió.
    setInterval(schedule, RECHECK_INTERVAL_MS);

    document.addEventListener("mousemove", (event) => setDragArea(isDragArea(event)), {
      capture: true,
      passive: true,
    });
    document.documentElement.addEventListener("mouseleave", () => setDragArea(false));
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
})();
