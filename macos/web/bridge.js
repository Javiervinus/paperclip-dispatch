// Paperclip Swift: puente entre la página y la app.
//
// - Tema: lo decide la app (Ajustes → Apariencia) y la página lo sigue por prefers-color-scheme, que es lo
//   que hace Paperclip cuando nadie eligió tema. Si se elige en el menú de Paperclip, la app lo adopta
//   como ajuste, así que los dos lugares quedan de acuerdo.
// - Tocar un aviso de macOS abre esa decisión sin recargar la página.
(() => {
  if (window.top !== window || window.__paperclipNative) return;
  const handler = window.webkit?.messageHandlers?.paperclipApp;
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
