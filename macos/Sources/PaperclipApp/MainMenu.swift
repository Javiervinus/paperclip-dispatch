import AppKit

/// Menús de la app. Las acciones viajan por la cadena de respuesta: la vista de Paperclip (Edición),
/// la ventana, su controlador (Archivo, Visualización, Ir) y el AppDelegate.
@MainActor
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        let services = submenu("Servicios", [])
        main.addItem(submenu(appName, [
            item("Acerca de \(appName)", #selector(AppDelegate.showAbout(_:))),
            // Junto a «Acerca de», donde la ponen las apps de Mac que se actualizan solas.
            item("Buscar actualizaciones…", #selector(AppDelegate.checkForUpdates(_:))),
            .separator(),
            item("Ajustes…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            services,
            .separator(),
            item("Ocultar \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Ocultar otras", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Mostrar todas", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Salir de \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        NSApp.servicesMenu = services.submenu
        main.addItem(submenu("Archivo", [
            // Para pegar una tarea en un chat o abrirla en otro equipo.
            item("Copiar enlace de esta página", #selector(MainWindowController.copyPageLink(_:)), "c", [.command, .shift]),
            item("Abrir en el navegador", #selector(MainWindowController.openPageInBrowser(_:))),
            .separator(),
            item("Cerrar ventana", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edición", [
            item("Deshacer", Selector(("undo:")), "z"),
            item("Rehacer", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cortar", #selector(NSText.cut(_:)), "x"),
            item("Copiar", #selector(NSText.copy(_:)), "c"),
            item("Pegar", #selector(NSText.paste(_:)), "v"),
            item("Seleccionar todo", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("Visualización", [
            item("Recargar", #selector(AppDelegate.reloadPage(_:)), "r"),
            .separator(),
            item("Tamaño real", #selector(MainWindowController.resetZoom(_:)), "0"),
            item("Ampliar", #selector(MainWindowController.zoomIn(_:)), "+"),
            item("Reducir", #selector(MainWindowController.zoomOut(_:)), "-"),
            .separator(),
            item("Pantalla completa", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))
        // Los atajos de un navegador, también en Finder y Safari.
        main.addItem(submenu("Ir", [
            item("Atrás", #selector(MainWindowController.navigateBack(_:)), "["),
            item("Adelante", #selector(MainWindowController.navigateForward(_:)), "]"),
            .separator(),
            item("Inicio", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]),
        ]))
        let window = submenu("Ventana", [
            item("Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            // Cerrar la ventana no cierra la app: desde aquí vuelve, como al tocar el ícono del Dock.
            item(appName, #selector(AppDelegate.showMainWindow(_:)), "0"),
            .separator(),
            item("Traer todo al frente", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Ayuda", helpItems(appName: appName))
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    /// Los enlaces a GitHub solo si build.sh supo cuál es el repositorio (`AppInfo`).
    private static func helpItems(appName: String) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let repository = AppInfo.repositoryURL {
            items.append(link("\(appName) en GitHub", repository))
        }
        if let releases = AppInfo.releasesURL {
            items.append(link("Novedades de cada versión", releases))
        }
        if let issue = AppInfo.newIssueURL {
            items.append(link("Reportar un problema…", issue))
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(link("Documentación de Paperclip", AppInfo.paperclipDocsURL))
        items.append(link("Sitio de Paperclip", AppInfo.paperclipURL))
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
