import AppKit
import Observation
import SwiftUI

/// El botón de arriba a la derecha: uno solo para las dos cosas que se actualizan, esta app (Dispatch) y
/// Paperclip (el servidor). Al día muestra las dos versiones; con algo nuevo se pinta del color de acento
/// y dice de quién es. Un clic abre el panel, que separa las dos y dice qué hace cada una.
@MainActor
final class UpdatesButton: NSObject, NSPopoverDelegate {
    private let button = NSButton()
    private let popover = NSPopover()
    private let app: AppUpdater
    private let status: AppStatus
    private unowned let host: MainWindowController
    private let checkPaperclip: () -> Void
    /// Las novedades se dan por vistas al cerrar el panel en que se mostraron.
    private var showedWhatsNew = false

    /// `checkPaperclip` y `updatePaperclip`: lo de Paperclip lo hace `UpdateController` (en los ensayos,
    /// nada).
    init(
        app: AppUpdater,
        status: AppStatus,
        host: MainWindowController,
        checkPaperclip: @escaping () -> Void,
        updatePaperclip: @escaping () -> Void
    ) {
        self.app = app
        self.status = status
        self.host = host
        self.checkPaperclip = checkPaperclip
        super.init()
        button.bezelStyle = .glass
        button.controlSize = .large
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let panel = NSHostingController(rootView: UpdatesPanel(
            app: app,
            status: status,
            actions: UpdatesPanelActions(
                checkAll: { [weak self] in self?.checkAll() },
                updatePaperclip: { [weak self] in
                    self?.popover.performClose(nil)
                    updatePaperclip()
                }
            )
        ))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        observe()
    }

    /// Desde el menú «Buscar actualizaciones…»: abre el panel y revisa las dos.
    func showPanelAndCheck() {
        showPanel()
        checkAll()
    }

    func showPanel() {
        guard !popover.isShown else { return }
        if button.window != nil, !button.isHidden {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = host.window?.contentView {
            // Sin botón a la vista (la vista angosta de Paperclip): desde la esquina de arriba a la derecha.
            let corner = NSRect(x: content.bounds.maxX - 40, y: content.bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
        showedWhatsNew = app.whatsNew != nil && app.phase.release == nil
    }

    private func checkAll() {
        checkPaperclip()
        app.checkNow()
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if showedWhatsNew { app.dismissWhatsNew() }
        showedWhatsNew = false
    }

    // MARK: - Lo que dice el botón

    /// Vuelve a pintar el botón cada vez que cambia algo que muestra.
    private func observe() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func refresh() {
        let dispatch = AppUpdater.currentVersion
        let paperclipLatest = status.latestVersion
        let appRelease: AppUpdater.Release? = switch app.phase {
        case .available(let release), .ready(let release): release
        default: nil
        }
        button.isEnabled = true
        button.tintProminence = .none

        if let progress = status.updateProgress {
            show(progress, symbol: "arrow.down.circle.fill")
            button.tintProminence = .primary
            button.toolTip = "Actualizando Paperclip. No cierres la app hasta que termine."
        } else if case .installing = app.phase {
            show("Reiniciando…", symbol: "arrow.clockwise")
            button.toolTip = nil
        } else if case .downloading(_, let progress) = app.phase {
            let percent = progress.map { " \(Int(($0 * 100).rounded())) %" } ?? ""
            show("Descargando Dispatch…\(percent)", symbol: "arrow.down.circle")
            button.toolTip = "Descargando la versión nueva de esta app. Al terminar se reinicia sola, como pediste."
        } else if let appRelease, let paperclipLatest {
            show("2 actualizaciones", symbol: "arrow.down.circle.fill")
            button.tintProminence = .primary
            button.toolTip = """
                Hay versiones nuevas de esta app (Dispatch \(appRelease.version)) y de Paperclip, el servidor \
                (\(paperclipLatest)). Clic para ver qué hace cada una.
                """
        } else if let appRelease {
            show("Actualizar Dispatch", image: AppIcon.adaptive(size: Self.iconSize))
            button.tintProminence = .primary
            // Descargada, se instala sola al cerrar la app; sin descargar (descargas automáticas apagadas), no.
            let when = if case .ready = app.phase {
                "Se instala cuando reinicias o cierras la app"
            } else {
                "Desde ahí la descargas e instalas cuando quieras"
            }
            button.toolTip = """
                Hay una versión nueva de esta app: Dispatch \(appRelease.version) (tienes la \(dispatch)).
                Clic para ver qué trae. \(when); Paperclip y tus agentes siguen trabajando.
                """
        } else if let paperclipLatest {
            show("Actualizar Paperclip", symbol: "paperclip")
            button.tintProminence = .primary
            button.toolTip = """
                Hay una versión nueva de Paperclip, el servidor donde trabajan tus agentes: la \(paperclipLatest)\
                \(status.paperclipVersion.map { " (tienes la \($0))" } ?? "").
                Actualizarlo pausa a los agentes mientras se reinicia: tú eliges cuándo.
                """
        } else if status.checkingUpdate || app.phase == .checking {
            show("Revisando…", symbol: "arrow.clockwise")
            button.toolTip = nil
        } else if let news = app.whatsNew {
            show("Novedades de Dispatch \(news.version)", symbol: "sparkles", tint: .controlAccentColor)
            button.toolTip = "Esta app se actualizó a la \(news.version). Clic para ver qué trae."
        } else if status.updateCheckError != nil, status.paperclipVersion == nil, status.updatesUnavailable == nil {
            show("No pude revisar Paperclip", symbol: "exclamationmark.triangle.fill", color: .systemOrange)
            button.toolTip = "\(status.updateCheckError ?? "")\n\nClic para ver detalles y reintentar."
        } else {
            let versions = [status.paperclipVersion.map { "Paperclip \($0)" }, "Dispatch \(dispatch)"]
            show(versions.compactMap(\.self).joined(separator: " · "), symbol: "checkmark.circle.fill", color: .systemGreen)
            button.toolTip = upToDateTip(dispatch: dispatch)
        }
        host.setUpdateButton(button, visible: true)
    }

    private func upToDateTip(dispatch: String) -> String {
        var lines = ["Todo al día."]
        if let version = status.paperclipVersion {
            lines.append("Paperclip \(version): el servidor, donde trabajan tus agentes.")
        } else if let unavailable = status.updatesUnavailable {
            lines.append("Paperclip: \(unavailable)")
        }
        lines.append("Dispatch \(dispatch): esta app, la ventana desde la que usas Paperclip.")
        if let checked = [app.lastCheckedAt, status.lastCheckedAt].compactMap(\.self).max() {
            lines.append("Última revisión: \(checked.formatted(date: .omitted, time: .shortened))")
        }
        lines.append("Clic para ver más o buscar de nuevo.")
        return lines.joined(separator: "\n")
    }

    /// `color` pinta el fondo del símbolo y deja blanco el dibujo de adentro (la palomita, el signo);
    /// `tint`, el símbolo entero (los de una sola capa, como las chispas).
    private func show(_ title: String, symbol: String, color: NSColor? = nil, tint: NSColor? = nil) {
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let color { image = image?.withSymbolConfiguration(.init(paletteColors: [.white, color])) }
        if let tint { image = image?.withSymbolConfiguration(.init(paletteColors: [tint])) }
        show(title, image: image)
    }

    private func show(_ title: String, image: NSImage?) {
        button.title = title
        button.image = image
    }

    /// El ícono de la app en «Actualizar Dispatch», del alto de la letra del botón.
    private static let iconSize: CGFloat = 17
}
