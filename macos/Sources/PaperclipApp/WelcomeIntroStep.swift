import SwiftUI

/// El primer paso de la bienvenida: cómo se llama la app y qué gana quien la usa, antes de pedir nada.
struct WelcomeIntroStep: View {
    let appName: String

    var body: some View {
        VStack(spacing: 0) {
            AppIconImage(size: WelcomeDesign.iconSize)
                .padding(.top, WelcomeDesign.iconTop)
            Text(appName)
                .font(.largeTitle)
                .bold()
                .padding(.top, 18)
            Text("Tus agentes de Paperclip, en una app de Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(
                    symbol: "bell.badge.fill",
                    title: "Te avisa cuando te necesitan",
                    detail: "Las decisiones de tus agentes llegan como avisos y con el número en el Dock, aunque cierres la ventana."
                )
                FeatureRow(
                    symbol: "paperplane.fill",
                    title: "Respondes desde donde estés",
                    detail: "En la Mac o, si quieres, en Telegram desde el teléfono."
                )
                FeatureRow(
                    symbol: "arrow.triangle.2.circlepath",
                    title: "Siempre al día",
                    detail: "Actualiza Paperclip y esta app con un clic, cuando tú decidas."
                )
            }
            .frame(width: WelcomeDesign.featuresWidth)
            .padding(.top, 30)
        }
        .padding(.horizontal, WelcomeDesign.contentInset)
    }
}

/// Una ventaja con su símbolo en el color de acento, como en las bienvenidas de las apps de Apple.
private struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
