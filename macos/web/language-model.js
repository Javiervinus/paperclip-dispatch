// Paperclip Dispatch: la IA integrada de Chrome (`LanguageModel`, su Prompt API) con el modelo de Apple de esta
// Mac.
//
// Los plugins de Paperclip que escriben con la IA de Chrome (Gemini Nano) la buscan en `window.LanguageModel`;
// aquí la misma forma la atiende la app con Apple Intelligence (LanguageModelBridge.swift). Trae lo que usan
// esos plugins, no la API entera:
// - `availability()`: "available", "downloading" (macOS todavía prepara el modelo) o "unavailable" (Apple
//   Intelligence apagado, una Mac sin él o un idioma que no habla). Nunca "downloadable": el modelo es del
//   sistema y la página no lo baja.
// - `create()` con `initialPrompts` (system, user y assistant), `temperature` y `topK`, `signal` y `monitor`
//   (no hay bajada que contar); y de cada sesión, `prompt()`, `promptStreaming()`, `clone()` y `destroy()`.
// - `responseConstraint`: la forma del JSON Schema se cumple siempre (objetos, listas y su cantidad, enum,
//   números con su rango). `pattern` y los largos de un texto no, porque el modelo de Apple no los acepta: la
//   página revisa lo que recibe, como con Chrome.
// - `promptStreaming()` entrega la respuesta entera, en un solo trozo.
// Si la página ya tiene un `LanguageModel` (un navegador que lo trae), no se toca.
(() => {
  if (window.top !== window || "LanguageModel" in window) return;
  const handler = window.webkit?.messageHandlers?.paperclipDispatchLanguageModel;
  if (!handler) return;

  // La app contesta los errores como «Nombre: mensaje», con el nombre del DOMException que daría Chrome.
  const call = async (message) => {
    try {
      return await handler.postMessage(message);
    } catch (error) {
      const text = String(error?.message ?? error);
      const [, name, detail] = /^(\w+): ([\s\S]*)$/.exec(text) ?? [];
      if (name === "TypeError") throw new TypeError(detail);
      throw name ? new DOMException(detail, name) : new DOMException(text, "UnknownError");
    }
  };

  const abortReason = (signal) => signal.reason ?? new DOMException("The operation was aborted.", "AbortError");
  let nextRequest = 0;
  // Un pedido que se puede cortar con `signal`: la página deja de esperarlo al tiro y la app lo suelta.
  const run = (message, signal) => {
    if (signal?.aborted) return Promise.reject(abortReason(signal));
    const request = `r${++nextRequest}`;
    const pending = call({ ...message, request });
    if (!signal) return pending;
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        call({ op: "cancel", request }).catch(() => {});
        reject(abortReason(signal));
      };
      signal.addEventListener("abort", onAbort, { once: true });
      pending.then(resolve, reject).finally(() => signal.removeEventListener("abort", onAbort));
    });
  };

  const languagesOf = (options) =>
    [...(options?.expectedInputs ?? []), ...(options?.expectedOutputs ?? [])].flatMap((expected) => expected?.languages ?? []);

  const textOf = (content) => {
    if (typeof content === "string") return content;
    throw new DOMException("Only text prompts are supported.", "NotSupportedError");
  };

  // Un prompt: un texto o una lista de mensajes del usuario.
  const promptText = (input) => {
    if (!Array.isArray(input)) return textOf(input);
    return input
      .map((message) => {
        if ((message?.role ?? "user") !== "user") throw new DOMException("Only user messages are supported.", "NotSupportedError");
        return textOf(message.content);
      })
      .join("\n\n");
  };

  // Las propiedades de un objeto van como lista: un diccionario en Swift no guarda su orden, y el modelo las
  // escribe en ese orden (el «id» antes que sus «frases»).
  const orderedSchema = (node) => {
    if (!node || typeof node !== "object" || Array.isArray(node)) return node;
    const copy = { ...node };
    if (node.properties && typeof node.properties === "object" && !Array.isArray(node.properties)) {
      copy.properties = Object.entries(node.properties).map(([name, schema]) => ({ name, schema: orderedSchema(schema) }));
    }
    if (node.items) copy.items = orderedSchema(node.items);
    if (Array.isArray(node.anyOf)) copy.anyOf = node.anyOf.map(orderedSchema);
    return copy;
  };

  const sampling = (options) => ({
    temperature: typeof options?.temperature === "number" ? options.temperature : null,
    topK: typeof options?.topK === "number" ? options.topK : null,
  });

  const created = Symbol("created");

  class LanguageModel extends EventTarget {
    #session;
    #settings;

    constructor(token, session, settings) {
      if (token !== created) throw new TypeError("Illegal constructor");
      super();
      this.#session = session;
      this.#settings = settings;
    }

    static async availability(options = {}) {
      return call({ op: "availability", languages: languagesOf(options) });
    }

    static async create(options = {}) {
      const initialPrompts = (options.initialPrompts ?? []).map((prompt) => ({
        role: prompt?.role ?? "user",
        content: textOf(prompt?.content),
      }));
      // Nunca hay bajada que contar, pero la página puede esperar su monitor.
      options.monitor?.(new EventTarget());
      const settings = sampling(options);
      const session = await run(
        { op: "create", initialPrompts, languages: languagesOf(options), ...settings },
        options.signal,
      );
      return new LanguageModel(created, session, settings);
    }

    get temperature() {
      return this.#settings.temperature ?? undefined;
    }

    get topK() {
      return this.#settings.topK ?? undefined;
    }

    async prompt(input, options = {}) {
      const schema = options.responseConstraint ? orderedSchema(options.responseConstraint) : null;
      return run({ op: "prompt", session: this.#session, text: promptText(input), schema }, options.signal);
    }

    promptStreaming(input, options = {}) {
      const answer = this.prompt(input, options);
      return new ReadableStream({
        async start(controller) {
          try {
            controller.enqueue(await answer);
            controller.close();
          } catch (error) {
            controller.error(error);
          }
        },
      });
    }

    async clone(options = {}) {
      const session = await run({ op: "clone", session: this.#session }, options.signal);
      return new LanguageModel(created, session, this.#settings);
    }

    destroy() {
      call({ op: "destroy", session: this.#session }).catch(() => {});
    }
  }

  Object.defineProperty(window, "LanguageModel", { value: LanguageModel, writable: true, configurable: true });
})();
