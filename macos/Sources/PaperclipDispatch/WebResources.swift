import Foundation
import WebKit

/// Los archivos de la página que build.sh copia en Contents/Resources, en el orden en que se inyectan:
/// primero los estilos y después los scripts. Siempre van el puente con la app (tema y avisos), el
/// diseño de la ventana sin barra de título (layout.css y layout.js), la IA de Chrome con la de Apple
/// (language-model.js) y la API web de avisos con los de macOS (notifications.js); el vidrio (glass.css),
/// solo si se activa (Ajustes → General → Experimental), y después de layout.css, cuyas medidas ajusta.
@MainActor
enum WebResources {
    private static let bridge = "bridge.js"
    private static let layoutScript = "layout.js"
    private static let layoutStyle = "layout.css"
    private static let glassStyle = "glass.css"
    private static let languageModelScript = "language-model.js"
    private static let notificationsScript = "notifications.js"

    /// Los scripts de cada carga de la página. `notificationPermission`: con el que empieza la página
    /// (PageNotifications); sin él, los avisos de la página quedan en "default".
    static func userScripts(glass: Bool, notificationPermission: String? = nil) -> [WKUserScript] {
        let styles = glass ? [layoutStyle, glassStyle] : [layoutStyle]
        let scripts = [bridge, layoutScript, languageModelScript, notificationsScript]
        var sources = styles.compactMap(read).map(styleInjection) + scripts.compactMap(read)
        if let notificationPermission {
            sources.append("window.__paperclipDispatchNotifications?.permission(\(jsonLiteral(notificationPermission)));")
        }
        return sources.map {
            WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        }
    }

    /// Un texto como literal de JavaScript (JSON es JavaScript válido).
    static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func read(_ name: String) -> String? {
        let url = Bundle.main.resourceURL?.appending(path: name)
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("Paperclip Dispatch: %@ is missing from Contents/Resources; rebuild with build.sh", name)
            return nil
        }
        return text
    }

    // Al empezar la carga todavía puede no existir <head>: el estilo va donde se pueda.
    private static func styleInjection(_ css: String) -> String {
        """
        (() => {
          const style = document.createElement("style");
          style.dataset.paperclipDispatch = "";
          style.textContent = \(jsonLiteral(css));
          const parent = document.head ?? document.documentElement;
          if (parent) parent.appendChild(style);
          else document.addEventListener("DOMContentLoaded", () => document.head.appendChild(style), { once: true });
        })();
        """
    }
}
