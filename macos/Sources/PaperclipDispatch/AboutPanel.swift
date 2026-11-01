import AppKit

/// «Acerca de»: el panel de macOS (ícono, nombre, versión y derechos) con quién hizo la app, dónde está su
/// código y que no es parte del proyecto Paperclip.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits(),
            // Sin el número de compilación entre paréntesis, que repetiría la versión.
            .version: "",
        ])
    }

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let text = NSMutableAttributedString()
        func append(_ string: String, link: URL? = nil, color: NSColor = .labelColor) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let link { attributes[.link] = link }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        if let author = AppInfo.author {
            append(String(localized: "Made by "))
            append(author, link: AppInfo.authorURL)
            append("\n")
        }
        if let repository = AppInfo.repositoryURL {
            append(String(localized: "Open source on "))
            append("GitHub", link: repository)
            append("\n")
        }
        append(String(localized: "Not affiliated with "), color: .secondaryLabelColor)
        append("Paperclip", link: AppInfo.paperclipURL)
        append(".", color: .secondaryLabelColor)
        return text
    }
}
