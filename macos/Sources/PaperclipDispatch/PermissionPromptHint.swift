import SwiftUI

/// Dónde responder el aviso de permiso de macOS mientras espera: sale arriba a la derecha y deja «Permitir»
/// dentro de «Opciones». Ese aviso es de macOS y la app no lo puede cambiar; solo puede decir dónde está.
struct PermissionPromptHint: View {
    /// La pausa entre un meneo de la flecha y el siguiente.
    private static let wiggleDelay: Double = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label {
            Text("Responde arriba a la derecha: **Opciones → Permitir**.")
        } icon: {
            Image(systemName: "arrow.up.right.circle.fill")
                .symbolEffect(.wiggle.up, options: .repeat(.periodic(delay: Self.wiggleDelay)), isActive: !reduceMotion)
        }
        .foregroundStyle(.tint)
        .fixedSize(horizontal: false, vertical: true)
    }
}
