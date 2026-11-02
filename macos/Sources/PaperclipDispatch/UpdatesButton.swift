import AppKit
import Observation
import SwiftUI

/// El botón de arriba a la derecha: uno solo para todo lo que se actualiza, esta app (Dispatch), Paperclip
/// (el servidor) y sus plugins. Al día muestra las versiones de la app y de Paperclip; con una versión nueva
/// de una de las dos se pinta del color de acento y dice de quién es. Los plugins sacan versiones seguido y
/// no apuran: con uno nuevo el botón no cambia de color ni de texto, solo la palomita pasa a una pieza gris.
/// Un clic abre el panel, que los separa y dice qué hace cada uno.
@MainActor
final class UpdatesButton: NSObject, NSPopoverDelegate {
    private let button = NSButton()
    private let popover = NSPopover()
    private let app: AppUpdater
    private let status: AppStatus
    private let plugins: PluginUpdates
    private unowned let host: MainWindowController
    private let checkPaperclip: () -> Void
    /// Las novedades se dan por vistas al cerrar el panel en que se mostraron.
    private var showedWhatsNew = false
    /// Con el panel abierto el botón no se angosta (al pasar a «Revisando…», por ejemplo): el panel cuelga
    /// de él y se correría hacia un lado.
    private var openWidth: NSLayoutConstraint?

    /// `checkPaperclip` y `updatePaperclip`: lo de Paperclip lo hace `UpdateController` (en los ensayos,
    /// nada).
    init(
        app: AppUpdater,
        status: AppStatus,
        plugins: PluginUpdates,
        host: MainWindowController,
        checkPaperclip: @escaping () -> Void,
        updatePaperclip: @escaping () -> Void
    ) {
        self.app = app
        self.status = status
        self.plugins = plugins
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
            plugins: plugins,
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

    /// Desde el menú «Buscar actualizaciones…»: abre el panel y revisa todo.
    func showPanelAndCheck() {
        showPanel()
        checkAll()
    }

    func showPanel() {
        guard !popover.isShown else { return }
        if button.window != nil, !button.isHidden {
            let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: button.frame.width)
            width.isActive = true
            openWidth = width
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = host.window?.contentView {
            // Sin botón a la vista (la vista angosta de Paperclip): desde la esquina de arriba a la derecha.
            let inset = Self.cornerInset
            let corner = NSRect(x: content.bounds.maxX - inset, y: content.bounds.maxY - inset, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
        showedWhatsNew = app.whatsNew != nil && app.phase.release == nil
    }

    private func checkAll() {
        checkPaperclip()
        app.checkNow()
        plugins.checkNow()
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        openWidth?.isActive = false
        openWidth = nil
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
        let pending = (appRelease == nil ? 0 : 1) + (paperclipLatest == nil ? 0 : 1)
        button.tintProminence = .none

        if let progress = status.updateProgress {
            show(progress, symbol: "arrow.down.circle.fill")
            button.tintProminence = .primary
            button.toolTip = String(localized: "Updating Paperclip. Don’t quit the app until it finishes.")
        } else if let plugin = plugins.updating {
            show(String(localized: "Updating \(plugin.name)…"), symbol: "arrow.down.circle")
            button.toolTip = String(localized: "Paperclip is updating the \(plugin.name) plugin. Your agents keep working.")
        } else if case .installing = app.phase {
            show(String(localized: "Restarting…"), symbol: "arrow.clockwise")
            button.toolTip = nil
        } else if case .downloading(_, let progress) = app.phase {
            let percent = progress.map { " " + String(localized: "\(Int(($0 * 100).rounded()))%") } ?? ""
            show(String(localized: "Downloading Dispatch…\(percent)"), symbol: "arrow.down.circle")
            button.toolTip = String(localized: "Downloading the new version of this app. It restarts on its own when it’s done, as you asked.")
        } else if pending > 1 {
            show(String(localized: "\(pending) Updates"), symbol: "arrow.down.circle.fill")
            button.tintProminence = .primary
            var lines = [String(localized: "New versions are available:")]
            if let appRelease { lines.append(String(localized: "• Dispatch \(appRelease.version), this app")) }
            if let paperclipLatest { lines.append(String(localized: "• Paperclip \(paperclipLatest), the server")) }
            lines.append(String(localized: "Click to see what each one does."))
            button.toolTip = lines.joined(separator: "\n")
        } else if let appRelease {
            show(String(localized: "Update Dispatch"), image: AppIcon.image(size: Self.iconSize))
            button.tintProminence = .primary
            // Descargada, se instala sola al cerrar la app; sin descargar (descargas automáticas apagadas), no.
            let when = if case .ready = app.phase {
                String(localized: "It installs when you restart or quit the app")
            } else {
                String(localized: "From there you can download and install it whenever you like")
            }
            button.toolTip = String(localized: """
                A new version of this app is available: Dispatch \(appRelease.version) (you have \(dispatch)).
                Click to see what’s new. \(when); Paperclip and your agents keep working.
                """)
        } else if let paperclipLatest {
            show(String(localized: "Update Paperclip"), symbol: "paperclip")
            button.tintProminence = .primary
            button.toolTip = String(localized: """
                A new version of Paperclip, the server where your agents work, is available: \(paperclipLatest)\
                \(status.paperclipVersion.map { String(localized: " (you have \($0))") } ?? "").
                Updating it pauses your agents while it restarts, so you choose when.
                """)
        } else if status.checkingUpdate || app.phase == .checking || plugins.checking {
            show(String(localized: "Checking…"), symbol: "arrow.clockwise")
            button.toolTip = nil
        } else if let news = app.whatsNew {
            show(String(localized: "What’s New in Dispatch \(news.version)"), symbol: "sparkles", tint: .controlAccentColor)
            button.toolTip = String(localized: "This app was updated to \(news.version). Click to see what’s new.")
        } else if status.updateCheckError != nil, status.paperclipVersion == nil, status.updatesUnavailable == nil {
            show(String(localized: "Couldn’t Check Paperclip"), symbol: "exclamationmark.triangle.fill", color: .systemOrange)
            button.toolTip = String(localized: "\(status.updateCheckError ?? "")\n\nClick for details and to try again.")
        } else {
            let versions = [status.paperclipVersion.map { "Paperclip \($0)" }, "Dispatch \(dispatch)"]
            let title = versions.compactMap(\.self).joined(separator: " · ")
            if plugins.available.isEmpty {
                show(title, symbol: "checkmark.circle.fill", color: .systemGreen)
            } else {
                show(title, symbol: "puzzlepiece.extension.fill", tint: .secondaryLabelColor)
            }
            button.toolTip = upToDateTip(dispatch: dispatch)
        }
        host.setUpdateButton(button)
    }

    private func upToDateTip(dispatch: String) -> String {
        var lines = [plugins.available.isEmpty
            ? String(localized: "Everything is up to date.")
            : String(localized: "This app and Paperclip are up to date.")]
        if let version = status.paperclipVersion {
            lines.append(String(localized: "Paperclip \(version): the server, where your agents work."))
        } else if let unavailable = status.updatesUnavailable {
            lines.append("Paperclip: \(unavailable)")
        }
        lines.append(String(localized: "Dispatch \(dispatch): this app, the window you use Paperclip from."))
        let available = plugins.available
        if !available.isEmpty {
            let list = available.map { "\($0.name) \($0.latest ?? "")" }.formatted(.list(type: .and))
            lines.append(available.count == 1
                ? String(localized: "A plugin has a new version: \(list). Update it from here whenever you like.")
                : String(localized: "Some plugins have new versions: \(list). Update them from here whenever you like."))
        } else if !plugins.plugins.isEmpty {
            let list = plugins.plugins.map { "\($0.name) \($0.version)" }.formatted(.list(type: .and))
            lines.append(String(localized: "Plugins: \(list)."))
        }
        if let checked = [app.lastCheckedAt, status.lastCheckedAt, plugins.lastCheckedAt].compactMap(\.self).max() {
            lines.append(String(localized: "Last checked: \(checked.formatted(date: .omitted, time: .shortened))"))
        }
        lines.append(String(localized: "Click to see more or check again."))
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
    /// Sin botón a la vista, el panel cuelga de este punto, cerca de la esquina de arriba a la derecha.
    private static let cornerInset: CGFloat = 40
}
