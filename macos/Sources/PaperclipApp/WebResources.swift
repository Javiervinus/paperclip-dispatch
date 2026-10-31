import Foundation
import WebKit

/// Los archivos de la página que build.sh copia en Contents/Resources, en el orden en que se inyectan:
/// primero el CSS, después el puente con la app y el script del vidrio.
@MainActor
enum WebResources {
    private static let scripts = ["bridge.js", "glass.js"]
    private static let styles = ["glass.css"]

    /// Los scripts de cada carga de la página.
    static func userScripts() -> [WKUserScript] {
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
