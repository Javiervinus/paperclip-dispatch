// Paperclip.app (Pake): mover la ventana desde las barras de arriba y avisar al CSS de la pantalla completa.
//
// Con --hide-title-bar no queda barra nativa de dónde arrastrar. La franja propia de Pake (20 px de
// ancho completo) tapa los botones de la barra de Paperclip, así que titlebar.css la esconde y aquí se
// hace como en una barra de título de macOS: la ventana se mueve desde cualquier parte vacía de las
// barras de arriba (la del selector de company y la de la ruta) y el doble clic la amplía.
(() => {
  if (window.top !== window || window.__paperclipAppTitlebar) return;
  window.__paperclipAppTitlebar = true;

  // Las dos barras de arriba de Paperclip (cabecera de Sidebar y BreadcrumbBar) miden --sz-60px.
  // Otros elementos usan min-h-(--sz-60px), por eso además tienen que empezar arriba de todo.
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

  const appWindow = () => window.__TAURI__?.window?.getCurrentWindow?.();

  // Alto de la franja de los botones de la ventana, definido en titlebar.css.
  const titlebarHeight = () =>
    parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--paperclip-app-titlebar")) || 0;

  const isDragArea = (event) => {
    const target = event.target;
    if (!(target instanceof Element) || target.closest(INTERACTIVE_SELECTOR)) return false;
    // La franja vacía de la vista angosta (body::before en titlebar.css).
    if (target === document.body || target === document.documentElement) {
      return event.clientY < titlebarHeight();
    }
    const bar = target.closest(TOP_BAR_SELECTOR);
    return Boolean(bar) && bar.getBoundingClientRect().top <= titlebarHeight();
  };

  document.addEventListener(
    "mousedown",
    (event) => {
      if (event.button !== 0 || event.detail > 1 || !isDragArea(event)) return;
      event.preventDefault();
      appWindow()?.startDragging().catch(() => {});
    },
    true,
  );

  // Lo mismo que el doble clic en una barra de título con el ajuste de fábrica de macOS («Rellenar»).
  document.addEventListener(
    "dblclick",
    (event) => {
      if (!isDragArea(event)) return;
      appWindow()?.toggleMaximize().catch(() => {});
    },
    true,
  );

  // En pantalla completa macOS esconde los botones: titlebar.css deja de reservarles la franja.
  const syncFullscreen = async () => {
    try {
      const fullscreen = await appWindow()?.isFullscreen();
      document.documentElement.toggleAttribute("data-paperclip-app-fullscreen", Boolean(fullscreen));
    } catch {
      // Sin acceso a la ventana (página fuera del sitio empaquetado): se queda la franja.
    }
  };
  window.addEventListener("resize", syncFullscreen);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", syncFullscreen, { once: true });
  } else {
    syncFullscreen();
  }
})();
