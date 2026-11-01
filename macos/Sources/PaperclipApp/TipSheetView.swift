import SwiftUI

/// El cuadro de una sugerencia (`Tip`), como hoja de la ventana de Paperclip: un dibujo de lo que se gana,
/// el texto y dos botones. Lo que se cierre no vuelve; queda dicho dónde está.
struct TipSheetView: View {
    static let width: CGFloat = 460

    let tip: Tip
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            illustration
                .padding(.bottom, 18)
            Text("Siguiente paso")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tint)
            Text(tip.title)
                .font(.title2)
                .bold()
                .padding(.top, 4)
            Text(tip.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: 14) {
                ForEach(tip.facts, id: \.text) { fact in
                    Label {
                        Text(fact.text)
                    } icon: {
                        Image(systemName: fact.symbol).foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 12)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Ahora no", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                Button(tip.actionTitle, action: onAction)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .controlSize(.large)
            .padding(.top, 20)
            Text(tip.footnote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 12)
        }
        .padding(.horizontal, 26)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: Self.width)
    }

    @ViewBuilder private var illustration: some View {
        switch tip {
        case .telegram: TelegramPreview()
        }
    }
}

/// Un mensaje del bot como se ve en Telegram (con su tema oscuro), con el formato de verdad: el tipo, el
/// asunto, quién lo pide y sus botones. Es solo un dibujo.
private struct TelegramPreview: View {
    private enum Palette {
        static let background = Color(red: 0.055, green: 0.086, blue: 0.129)
        static let bubble = Color(red: 0.094, green: 0.145, blue: 0.2)
        static let text = Color(red: 0.914, green: 0.929, blue: 0.945)
        static let muted = Color(red: 0.427, green: 0.498, blue: 0.561)
    }

    private static let bubbleShape = UnevenRoundedRectangle(
        topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14, topTrailingRadius: 14
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(nsImage: AppIcon.variant(dark: false))
                    .resizable()
                    .frame(width: 26, height: 26)
                    .background(.white, in: .circle)
                    .clipShape(.circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Tu bot").font(.subheadline.bold()).foregroundStyle(.white)
                    Text("bot").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aprobación").bold().foregroundStyle(.white)
                Text("Contratar a un agente de diseño").bold().foregroundStyle(.white)
                Text("CEO · VIN-214").italic()
            }
            .font(.subheadline)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bubble, in: Self.bubbleShape)
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    key("Aprobar")
                    key("Rechazar")
                }
                GridRow {
                    key("💡 Explícamela").gridCellColumns(2)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Palette.background, in: .rect(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ejemplo de mensaje del bot: una aprobación del CEO en VIN-214, con los botones Aprobar, Rechazar y Explícamela.")
    }

    private func key(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Palette.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Palette.bubble.opacity(0.75), in: .rect(cornerRadius: 9))
    }
}
