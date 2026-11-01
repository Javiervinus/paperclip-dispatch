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
        case .telegram: "Responde desde el teléfono"
        }
    }

    var message: String {
        switch self {
        case .telegram:
            "Conecta un bot de Telegram y cada decisión te llega como mensaje, con sus botones. Lo que tocas ahí se aplica en Paperclip."
        }
    }

    /// Datos cortos debajo del texto: cuánto toma, qué no hace falta.
    var facts: [Fact] {
        switch self {
        case .telegram: [
            Fact(symbol: "clock", text: "Unos 2 minutos"),
            Fact(symbol: "iphone", text: "Sin configurar tu red"),
        ]
        }
    }

    var actionTitle: String {
        switch self {
        case .telegram: "Configurar Telegram"
        }
    }

    /// Dónde queda, para quien diga «Ahora no».
    var footnote: String {
        switch self {
        case .telegram: "Siempre está en Ajustes → Telegram."
        }
    }
}
