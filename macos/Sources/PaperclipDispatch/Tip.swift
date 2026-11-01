import Foundation

/// Una sugerencia que sale una sola vez, ya dentro de Paperclip, en un cuadro sobre la ventana. Las que
/// vengan se agregan aquí, con su texto, y en `TipSheetView` con su dibujo.
enum Tip: String, CaseIterable {
    /// Conectar un bot de Telegram: crear el bot toma unos minutos y no va en la bienvenida.
    case telegram

    struct Fact {
        let symbol: String
        let text: String
    }

    var title: String {
        switch self {
        case .telegram: String(localized: "Reply from your phone")
        }
    }

    var message: String {
        switch self {
        case .telegram:
            String(localized: "Connect a Telegram bot and every decision reaches you as a message, with its buttons. Whatever you tap there is applied in Paperclip.")
        }
    }

    /// Datos cortos debajo del texto: cuánto toma, qué no hace falta.
    var facts: [Fact] {
        switch self {
        case .telegram: [
            Fact(symbol: "clock", text: String(localized: "About 2 minutes")),
            Fact(symbol: "iphone", text: String(localized: "No network setup")),
        ]
        }
    }

    var actionTitle: String {
        switch self {
        case .telegram: String(localized: "Set Up Telegram")
        }
    }

    /// Dónde queda, para quien diga «Ahora no».
    var footnote: String {
        switch self {
        case .telegram: String(localized: "It’s always in Settings → Telegram.")
        }
    }
}
