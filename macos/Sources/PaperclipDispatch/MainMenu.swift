import AppKit

/// Menús de la app. Las acciones viajan por la cadena de respuesta: la vista de Paperclip (Edición),
/// la ventana, su controlador (Archivo, Visualización, Ir) y el AppDelegate.
@MainActor
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        let services = submenu(String(localized: "Services"), [])
        main.addItem(submenu(appName, [
            item(String(localized: "About \(appName)"), #selector(AppDelegate.showAbout(_:))),
            // Junto a «Acerca de», donde la ponen las apps de Mac que se actualizan solas.
            item(String(localized: "Check for Updates…"), #selector(AppDelegate.checkForUpdates(_:))),
            .separator(),
            item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            services,
            .separator(),
            item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "Quit \(appName)"), #selector(NSApplication.terminate(_:)), "q"),
        ]))
        NSApp.servicesMenu = services.submenu
        main.addItem(submenu(String(localized: "File"), [
            // Para pegar una tarea en un chat o abrirla en otro equipo.
            item(String(localized: "Copy Link to This Page"), #selector(MainWindowController.copyPageLink(_:)), "c", [.command, .shift]),
            item(String(localized: "Open in Browser"), #selector(MainWindowController.openPageInBrowser(_:))),
            .separator(),
            item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu(String(localized: "Edit"), [
            item(String(localized: "Undo"), Selector(("undo:")), "z"),
            item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu(String(localized: "View"), [
            item(String(localized: "Reload Page"), #selector(AppDelegate.reloadPage(_:)), "r"),
            .separator(),
            item(String(localized: "Actual Size"), #selector(MainWindowController.resetZoom(_:)), "0"),
            item(String(localized: "Zoom In"), #selector(MainWindowController.zoomIn(_:)), "+"),
            item(String(localized: "Zoom Out"), #selector(MainWindowController.zoomOut(_:)), "-"),
            .separator(),
            item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        // Los atajos de un navegador, también en Finder y Safari.
        main.addItem(submenu(String(localized: "Go"), [
            item(String(localized: "Back"), #selector(MainWindowController.navigateBack(_:)), "["),
            item(String(localized: "Forward"), #selector(MainWindowController.navigateForward(_:)), "]"),
            .separator(),
            item(String(localized: "Home"), #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]),
        ]))
        let window = submenu(String(localized: "Window"), [
            item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            // Cerrar la ventana no cierra la app: desde aquí vuelve, como al tocar el ícono del Dock.
            item(appName, #selector(AppDelegate.showMainWindow(_:)), "0"),
            .separator(),
            item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu(String(localized: "Help"), helpItems(appName: appName))
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    /// Los enlaces a GitHub solo si build.sh supo cuál es el repositorio (`AppInfo`).
    private static func helpItems(appName: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let repository = AppInfo.repositoryURL {
            items.append(link(String(localized: "\(appName) on GitHub"), repository))
        }
        if let releases = AppInfo.releasesURL {
            items.append(link(String(localized: "Release Notes"), releases))
        }
        if let issue = AppInfo.newIssueURL {
            items.append(link(String(localized: "Report an Issue…"), issue))
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(link(String(localized: "Paperclip Documentation"), AppInfo.paperclipDocsURL))
        items.append(link(String(localized: "Paperclip Website"), AppInfo.paperclipURL))
        return items
    }

    private static func link(_ title: String, _ url: URL) -> NSMenuItem {
        let item = item(title, #selector(AppDelegate.openLink(_:)))
        item.representedObject = url
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
