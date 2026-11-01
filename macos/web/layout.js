// Paperclip Dispatch: le cuenta a la app lo que necesita saber de la página.
//
// - El alto de las barras de arriba y si la página está en su vista de escritorio, para el botón de la
//   versión.
// - Si el puntero está sobre una parte vacía de esas barras: desde ahí se mueve la ventana, que no tiene
//   barra de título. La app decide en el clic mismo, así que se avisa al mover el puntero.
// - Para Liquid Glass: dónde está la barra lateral, para poner el panel de vidrio justo detrás (glass.css
//   le quita el fondo), y el color de fondo de Paperclip, que la app pinta alrededor del panel.
(() => {
  if (window.top !== window || window.__paperclipAppLayout) return;
  window.__paperclipAppLayout = true;
  const handler = window.webkit?.messageHandlers?.paperclipApp;
  if (!handler) return;

  const post = (message) => handler.postMessage(message);

  // Paperclip pasa a su vista móvil bajo 768 px (MOBILE_BREAKPOINT de SidebarContext): ahí la barra
  // lateral es un cajón y no lleva vidrio.
  const desktop = window.matchMedia("(min-width: 768px)");
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

  let titlebar = 0;
  let lastLayout = "";
  let observed = null;
  let pending = 0;

  const report = () => {
    pending = 0;
    titlebar = cssPixels("--paperclip-app-titlebar");
    const area = desktop.matches ? sidebarArea() : null;
    if (area !== observed) {
      if (observed) resizeObserver.unobserve(observed);
      if (area) resizeObserver.observe(area);
      observed = area;
    }
    const rect = area?.getBoundingClientRect();
    const inset = cssPixels("--paperclip-app-sidebar-inset");
    const message = {
      type: "layout",
      desktop: desktop.matches,
      background: cssColorBytes("--background"),
      topBar: cssPixels("--sz-60px"),
      sidebar:
        rect && rect.width > 0 && rect.height > 0
          ? {
              x: rect.left,
              y: rect.top,
              width: rect.width,
              height: rect.height,
              inset,
              radius: Math.max(0, cssPixels("--paperclip-app-window-radius") - inset),
            }
          : null,
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
    setInterval(schedule, 1000);

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
