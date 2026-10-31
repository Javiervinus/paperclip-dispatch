import AppKit

/// Menús de la app. Las acciones viajan por la cadena de respuesta: la vista de Paperclip (Edición),
/// la ventana y el AppDelegate.
@MainActor
enum MainMenu {
    static func build(appName: String) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appName, [
            item("Acerca de \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Ajustes…", #selector(AppDelegate.showSettings(_:)), ","),
            item("Buscar actualización de Paperclip…", #selector(AppDelegate.checkForPaperclipUpdate(_:))),
            .separator(),
            item("Ocultar \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Ocultar otras", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Mostrar todas", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Salir de \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Archivo", [
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
        let window = submenu("Ventana", [
            item("Minimizar", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Traer todo al frente", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
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
