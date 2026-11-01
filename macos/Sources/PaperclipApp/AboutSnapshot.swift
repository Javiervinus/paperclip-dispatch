import AppKit

/// El panel «Acerca de» fuera de la pantalla (`macos/snapshot.zsh about`), con la apariencia de la Mac.
@MainActor
enum AboutSnapshot {
    /// Lo que tarda el panel en dibujarse.
    private static let drawTime: Duration = .seconds(1)

    static func run(to directory: URL) async {
        let before = Set(NSApp.windows.map(\.windowNumber))
        AboutPanel.show()
        // Es una ventana de AppKit: se la reconoce por ser la única nueva.
        guard let panel = NSApp.windows.first(where: { !before.contains($0.windowNumber) }) else { return }
        Snapshot.hide(panel)
        try? await Task.sleep(for: drawTime)
        await Snapshot.capture([Snapshot.Window(window: panel, file: "acerca-de.png")], in: directory)
    }
}
