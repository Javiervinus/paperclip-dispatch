// Paperclip Dispatch: puente entre la página y la app.
//
// - Tema: lo decide la app (Ajustes → Apariencia) y la página lo sigue por prefers-color-scheme, que es lo
//   que hace Paperclip cuando nadie eligió tema. Si se elige en el menú de Paperclip, la app lo adopta
//   como ajuste, así que los dos lugares quedan de acuerdo.
// - Tocar un aviso de macOS abre esa decisión sin recargar la página.
// - Si lo que hay bajo el puntero todavía se desplaza a lo ancho, y hacia qué lado: ese desplazamiento es
//   de la página y no el gesto de atrás y adelante de la app (PaperclipWebView), como con el de WebKit.
(() => {
  if (window.top !== window || window.__paperclipNative) return;
  const handler = window.webkit?.messageHandlers?.paperclipDispatch;
  if (!handler) return;

  const post = (message) => handler.postMessage(message);

  // La clave de ThemeProvider de Paperclip (y de su script en línea de index.html): con un valor, el tema
  // queda fijo; sin él, sigue a prefers-color-scheme.
  const THEME_KEY = "paperclip.theme";
  const takeStoredTheme = () => {
    try {
      const value = localStorage.getItem(THEME_KEY);
      if (value !== null) localStorage.removeItem(THEME_KEY);
      return value;
    } catch {
      return null;
    }
  };
  // Este archivo corre antes que los scripts de Paperclip: lo que quedó guardado de antes no cuenta,
  // manda Ajustes.
  takeStoredTheme();
  // Paperclip guarda el tema elegido justo después de cambiar la clase de <html>.
  new MutationObserver(() => {
    const chosen = takeStoredTheme();
    if (chosen === "light" || chosen === "dark") post({ type: "themeChosen", theme: chosen });
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });

  // Navega dentro de Paperclip sin recargar: su enrutador escucha popstate.
  const navigate = (href) => {
    if (!href || `${location.pathname}${location.search}${location.hash}` === href) return;
    history.pushState({}, "", href);
    dispatchEvent(new PopStateEvent("popstate"));
  };

  // Hacia qué lado se puede desplazar a lo ancho lo que hay bajo el puntero (un tablero, una tabla ancha).
  let pointerTarget = null;
  let horizontalScroll = { back: false, forward: false };
  let pendingScrollCheck = 0;
  const scrollableSides = (target) => {
    const sides = { back: false, forward: false };
    for (let element = target; element && element !== document.documentElement; element = element.parentElement) {
      if (element.scrollWidth <= element.clientWidth) continue;
      const overflow = getComputedStyle(element).overflowX;
      if (overflow !== "auto" && overflow !== "scroll") continue;
      if (element.scrollLeft > 0) sides.back = true;
      if (element.scrollLeft + element.clientWidth < element.scrollWidth - 1) sides.forward = true;
    }
    return sides;
  };
  const checkHorizontalScroll = () => {
    pendingScrollCheck = 0;
    const sides = scrollableSides(pointerTarget);
    if (sides.back === horizontalScroll.back && sides.forward === horizontalScroll.forward) return;
    horizontalScroll = sides;
    post({ type: "horizontalScroll", ...sides });
  };
  const scheduleScrollCheck = () => {
    if (!pendingScrollCheck) pendingScrollCheck = requestAnimationFrame(checkHorizontalScroll);
  };

  document.addEventListener(
    "mousemove",
    (event) => {
      pointerTarget = event.target instanceof Element ? event.target : null;
      scheduleScrollCheck();
    },
    { capture: true, passive: true },
  );
  document.addEventListener("scroll", scheduleScrollCheck, { capture: true, passive: true });

  window.__paperclipNative = {
    // La app lo llama cuando cambia la apariencia. Paperclip ya la sigue si nadie eligió tema; esto cubre
    // el caso en que se eligió en su menú durante esta carga (ahí deja de escuchar al sistema).
    setTheme(theme) {
      takeStoredTheme();
      const dark = theme === "dark";
      const root = document.documentElement;
      if (root.classList.contains("dark") === dark) return;
      root.classList.toggle("dark", dark);
      root.style.colorScheme = dark ? "dark" : "light";
    },
    navigate,
  };
})();
