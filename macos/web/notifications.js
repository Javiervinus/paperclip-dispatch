// Paperclip Dispatch: la API web de avisos (`Notification`) con avisos de macOS.
//
// WKWebView trae `Notification`, pero siempre bloqueado: un plugin que avisa con ella (como «Aviso del
// sistema» de Oficina global) quedaba en «Bloqueado» y con instrucciones de Chrome. Aquí la atiende la app
// (PageNotifications.swift), como un navegador:
// - `Notification.permission` empieza en "default" y pasa a "granted" cuando la página lo pide con
//   `requestPermission()` y macOS deja avisar a la app; "denied" si macOS no deja. Se apaga en Ajustes →
//   Avisos, y la app lo cambia aquí en vivo (`permission`).
// - `new Notification(título, { body, tag, silent, data })` muestra un aviso de macOS; la misma `tag`
//   reemplaza al anterior. Un clic en el aviso trae la ventana y dispara `click` en el objeto, si la página
//   sigue abierta. `close()` lo quita.
// No trae botones (`actions`), imágenes ni avisos desde un service worker.
(() => {
  if (window.top !== window) return;
  const handler = window.webkit?.messageHandlers?.paperclipDispatchNotifications;
  if (!handler) return;

  let permission = "default";
  let nextId = 0;
  const open = new Map();
  const created = Symbol("created");

  const handlerProperty = (target, type) => {
    let current = null;
    Object.defineProperty(target, `on${type}`, {
      get: () => current,
      set: (value) => {
        if (current) target.removeEventListener(type, current);
        current = typeof value === "function" ? value : null;
        if (current) target.addEventListener(type, current);
      },
    });
  };

  class Notification extends EventTarget {
    #id;
    #options;

    constructor(title, options = {}) {
      super();
      if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required.");
      this.#id = `n${++nextId}`;
      this.#options = {
        title: String(title),
        body: String(options.body ?? ""),
        tag: String(options.tag ?? ""),
        silent: options.silent === true,
        data: options.data ?? null,
        icon: String(options.icon ?? ""),
        lang: String(options.lang ?? ""),
        dir: options.dir ?? "auto",
        requireInteraction: options.requireInteraction === true,
        timestamp: typeof options.timestamp === "number" ? options.timestamp : Date.now(),
      };
      for (const type of ["show", "click", "close", "error"]) handlerProperty(this, type);
      if (permission !== "granted") {
        queueMicrotask(() => this.dispatchEvent(new Event("error")));
        return;
      }
      open.set(this.#id, this);
      const { title: text, body, tag, silent } = this.#options;
      handler
        .postMessage({ op: "show", id: this.#id, title: text, body, tag, silent })
        .then(() => this.dispatchEvent(new Event("show")))
        .catch(() => {
          open.delete(this.#id);
          this.dispatchEvent(new Event("error"));
        });
    }

    static get permission() {
      return permission;
    }

    static get maxActions() {
      return 0;
    }

    static async requestPermission(callback) {
      try {
        permission = await handler.postMessage({ op: "request" });
      } catch {
        // La app no contestó: queda como estaba.
      }
      if (typeof callback === "function") callback(permission);
      return permission;
    }

    get title() { return this.#options.title; }
    get body() { return this.#options.body; }
    get tag() { return this.#options.tag; }
    get silent() { return this.#options.silent; }
    get data() { return this.#options.data; }
    get icon() { return this.#options.icon; }
    get lang() { return this.#options.lang; }
    get dir() { return this.#options.dir; }
    get requireInteraction() { return this.#options.requireInteraction; }
    get timestamp() { return this.#options.timestamp; }
    get actions() { return []; }
    get badge() { return ""; }
    get image() { return ""; }
    get renotify() { return false; }

    close() {
      if (!open.delete(this.#id)) return;
      handler.postMessage({ op: "close", id: this.#id, tag: this.#options.tag }).catch(() => {});
      this.dispatchEvent(new Event("close"));
    }
  }

  // Lo que llama la app: el permiso cambió (Ajustes, macOS) o se hizo clic en un aviso de esta página.
  Object.defineProperty(window, "__paperclipDispatchNotifications", {
    value: Object.freeze({
      permission: (value) => {
        if (value === "granted" || value === "denied" || value === "default") permission = value;
      },
      click: (id) => {
        const notification = open.get(id);
        if (!notification) return;
        notification.dispatchEvent(new Event("click", { cancelable: true }));
      },
    }),
  });
  Object.defineProperty(window, "Notification", { value: Notification, writable: true, configurable: true });
})();
