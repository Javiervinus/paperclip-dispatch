import AppKit

MainActor.assumeIsolated {
    // NSApplication guarda el delegado como referencia débil: esta variable lo mantiene vivo mientras
    // corre la app, porque run() no vuelve hasta que la app se cierra.
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
