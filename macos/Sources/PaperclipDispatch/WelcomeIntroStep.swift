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
            Text("Your Paperclip agents, in a Mac app.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(
                    symbol: "bell.badge.fill",
                    title: String(localized: "Notifies you when you’re needed"),
                    detail: String(localized: "Your agents’ decisions arrive as notifications and as a badge on the Dock icon, even if you close the window.")
                )
                FeatureRow(
                    symbol: "paperplane.fill",
                    title: String(localized: "Reply from wherever you are"),
                    detail: String(localized: "On your Mac or, if you like, in Telegram from your phone.")
                )
                FeatureRow(
                    symbol: "arrow.triangle.2.circlepath",
                    title: String(localized: "Always up to date"),
                    detail: String(localized: "Update Paperclip and this app with one click, whenever you choose.")
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
