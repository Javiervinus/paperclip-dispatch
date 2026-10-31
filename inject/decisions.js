// Paperclip.app (Pake): número de Decisions en el ícono del Dock y aviso de macOS cuando llega una nueva.
//
// Pake inyecta este archivo en cada carga de la página y traduce navigator.setAppBadge() y
// new Notification() a las APIs nativas de macOS (src-tauri/src/inject/event.js). La app nativa
// (macos/) no lo usa: lo revisa en Swift, en DecisionsMonitor.swift.
// Los datos salen de la misma API que usa la barra lateral de Paperclip:
// GET /api/companies/{id}/attention, con la sesión del usuario.
(() => {
  if (window.top !== window || window.__paperclipAppDecisions) return;
  window.__paperclipAppDecisions = true;

  // La barra lateral de Paperclip pide /attention cada 60 s.
  const POLL_MS = 60_000;
  // Lo ya avisado, por company, para no repetir avisos al reabrir la app.
  const SEEN_KEY = "paperclip-app:decisions-seen";
  const SEEN_LIMIT = 500;

  let companies = null;
  let company = null;
  let polling = false;

  const api = async (path) => {
    const response = await fetch(`/api${path}`, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      throw Object.assign(new Error(`HTTP ${response.status}`), { status: response.status });
    }
    return response.json();
  };

  const routePrefix = () => (location.pathname.split("/")[1] ?? "").toUpperCase();

  // La company es la de la ruta abierta (/VIN/...). En rutas sin company (/plugins, /settings)
  // se queda con la última; al principio, con la primera activa.
  const pickCompany = () => {
    const prefix = routePrefix();
    return (
      companies.find((c) => c.issuePrefix?.toUpperCase() === prefix) ??
      companies.find((c) => c.id === company?.id) ??
      companies.find((c) => c.status === "active") ??
      companies[0] ??
      null
    );
  };

  const setBadge = (count) => {
    if (count > 0) navigator.setAppBadge?.(count);
    else navigator.clearAppBadge?.();
  };

  const readSeen = () => {
    try {
      const value = JSON.parse(localStorage.getItem(SEEN_KEY) ?? "null");
      return value && typeof value === "object" ? value : {};
    } catch {
      return {};
    }
  };

  // Navega dentro de la app sin recargar: el enrutador de Paperclip escucha popstate.
  const navigate = (href) => {
    if (!href || `${location.pathname}${location.hash}` === href) return;
    history.pushState({}, "", href);
    dispatchEvent(new PopStateEvent("popstate"));
  };

  const notify = (item) => {
    if (!("Notification" in window) || Notification.permission !== "granted") return;
    const title =
      [item.originAgentName, item.relatedIssue?.identifier].filter(Boolean).join(" · ") || "Paperclip";
    const body =
      item.detail?.promptExcerpt || item.subject?.title || item.whyNow || "Algo espera tu decisión.";
    const href = item.subject?.href ?? item.relatedIssue?.href;
    // `data.href` sirve a la app nativa cuando la página se recargó antes del clic.
    const notification = new Notification(title, { body, tag: item.id, data: { href } });
    notification.addEventListener("click", () => {
      window.focus();
      navigate(href);
    });
  };

  const poll = async () => {
    if (polling) return;
    polling = true;
    try {
      companies ??= await api("/companies");
      company = pickCompany();
      if (!company) {
        setBadge(0);
        return;
      }

      const attention = await api(`/companies/${company.id}/attention`);
      const items = attention.items ?? [];
      setBadge(attention.totalCount ?? items.length);

      const seen = readSeen();
      const previous = seen[company.id];
      // La primera vez solo se registra lo que ya había: avisar de todo junto sería ruido.
      // Con la ventana al frente no se avisa: la barra lateral ya lo muestra.
      if (previous && !document.hasFocus()) {
        const known = new Set(previous);
        items.filter((item) => !known.has(item.id)).forEach(notify);
      }
      seen[company.id] = [...new Set([...items.map((item) => item.id), ...(previous ?? [])])].slice(
        0,
        SEEN_LIMIT,
      );
      localStorage.setItem(SEEN_KEY, JSON.stringify(seen));
    } catch (error) {
      // Sin sesión (pantalla de inicio) no hay número; se vuelve a intentar en la próxima vuelta.
      if (error?.status === 401 || error?.status === 403) {
        companies = null;
        company = null;
        setBadge(0);
      }
    } finally {
      polling = false;
    }
  };

  setInterval(poll, POLL_MS);
  window.addEventListener("focus", poll);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") poll();
  });
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", poll, { once: true });
  } else {
    poll();
  }
})();
