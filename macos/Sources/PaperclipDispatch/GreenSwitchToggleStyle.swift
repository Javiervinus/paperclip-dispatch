import SwiftUI

/// El interruptor de macOS, encendido en verde como en el iPhone. Con el acento de la app (la tinta de
/// Paperclip), en modo oscuro la pista queda casi blanca bajo la perilla blanca y parece bloqueado; el
/// verde además es el color de «encendido» y de «permitido» en el resto de la app.
struct GreenSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .tint(.green)
    }
}

extension ToggleStyle where Self == GreenSwitchToggleStyle {
    static var greenSwitch: GreenSwitchToggleStyle { GreenSwitchToggleStyle() }
}
