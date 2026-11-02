import AppKit
import Observation
import SwiftUI

/// El botón chico de los plugins, a la izquierda del de actualizaciones: solo la pieza y, si alguno tiene versión
/// nueva, un punto. Los plugins sacan versiones seguido: así no apuran ni agrandan el panel de actualizaciones,
/// por muchos que haya. Un clic abre su panel (`PluginsPanel`). Sin plugins (o sin sesión), no se ve.
@MainActor
final class PluginsButton: NSObject, NSPopoverDelegate {
    let button = NSButton()
    /// Un símbolo y no una capa pintada: así sigue el color de acento y la apariencia (activa o no, claro u oscuro).
    private let dot = NSImageView()
    private let popover = NSPopover()
    private let plugins: PluginUpdates
    private unowned let host: MainWindowController

    /// Al abrir el panel: ahí se ven las versiones nuevas que se avisaron (`UpdateNotices`).
    var onPanelShown: (() -> Void)?
    /// Cambió lo que se ve (aparece o se esconde): quien lo puso lo vuelve a acomodar.
    var onChange: (() -> Void)?

    private static let dotSize: CGFloat = 8
    /// Del borde del botón al punto: sobre el borde del círculo de vidrio, arriba a la derecha.
    private static let dotInset: CGFloat = 4

    init(plugins: PluginUpdates, host: MainWindowController) {
        self.plugins = plugins
        self.host = host
        super.init()
        button.bezelStyle = .glass
        button.controlSize = .large
        button.borderShape = .circle
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(String(localized: "Plugins"))
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalTo: button.heightAnchor).isActive = true
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.dotSize, weight: .regular))
        dot.contentTintColor = .controlAccentColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotSize),
            dot.heightAnchor.constraint(equalToConstant: Self.dotSize),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: Self.dotInset),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.dotInset),
        ])
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let panel = NSHostingController(rootView: PluginsPanel(plugins: plugins))
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel
        observe()
    }

    var isPanelShown: Bool { popover.isShown }

    func showPanel() {
        guard !popover.isShown else { return }
        if button.window != nil, !button.isHiddenOrHasHiddenAncestor {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let content = host.window?.contentView {
            // Sin botón a la vista (otra página, la vista angosta): desde la esquina de arriba a la derecha.
            let inset = UpdatesButton.cornerInset
            let corner = NSRect(x: content.bounds.maxX - inset, y: content.bounds.maxY - inset, width: 1, height: 1)
            popover.show(relativeTo: corner, of: content, preferredEdge: .minY)
        }
        onPanelShown?()
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    // MARK: - Lo que dice el botón

    private func observe() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func refresh() {
        let wasHidden = button.isHidden
        let available = plugins.canUpdate ? plugins.available : []
        let symbol = plugins.updating == nil ? "puzzlepiece.extension" : "arrow.down.circle"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isHidden = plugins.plugins.isEmpty
        dot.isHidden = available.isEmpty || plugins.updating != nil
        button.toolTip = tooltip
        if button.isHidden != wasHidden { onChange?() }
    }

    private var tooltip: String {
        if let updating = plugins.updating {
            return String(localized: "Paperclip is updating the \(updating.name) plugin. Your agents keep working.")
        }
        let available = plugins.available
        guard !available.isEmpty else {
            let list = plugins.plugins.map { "\($0.name) \($0.version)" }.formatted(.list(type: .and))
            return String(localized: "Plugins: \(list).")
        }
        let list = available.map { "\($0.name) \($0.latest ?? "")" }.formatted(.list(type: .and))
        return available.count == 1
            ? String(localized: "A plugin has a new version: \(list). Update it from here whenever you like.")
            : String(localized: "Some plugins have new versions: \(list). Update them from here whenever you like.")
    }
}
