import Foundation
import WebKit

/// Los archivos de la página que build.sh copia en Contents/Resources, en el orden en que se inyectan:
/// primero el CSS, después el puente con la app y el script del vidrio. El puente no cambia cómo se ve la
/// página (tema y avisos); el vidrio sí, por eso va solo si se activa (Ajustes → General → Experimental).
@MainActor
enum WebResources {
    private static let bridge = "bridge.js"
    private static let glassScript = "glass.js"
    private static let glassStyle = "glass.css"

    /// Los scripts de cada carga de la página.
    static func userScripts(glass: Bool) -> [WKUserScript] {
        let styles = glass ? [glassStyle] : []
        let scripts = glass ? [bridge, glassScript] : [bridge]
        let sources = styles.compactMap(read).map(styleInjection) + scripts.compactMap(read)
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
            NSLog("Paperclip: falta %@ en Contents/Resources; vuelve a armar con build.sh", name)
            return nil
        }
        return text
    }

    // Al empezar la carga todavía puede no existir <head>: el estilo va donde se pueda.
    private static func styleInjection(_ css: String) -> String {
        """
        (() => {
          const style = document.createElement("style");
          style.dataset.paperclipApp = "";
          style.textContent = \(jsonLiteral(css));
          const parent = document.head ?? document.documentElement;
          if (parent) parent.appendChild(style);
          else document.addEventListener("DOMContentLoaded", () => document.head.appendChild(style), { once: true });
        })();
        """
    }
}
