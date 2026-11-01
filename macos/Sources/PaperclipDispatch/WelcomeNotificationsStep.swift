import AppKit
import SwiftUI

/// El último paso de la primera vez: primero muestra cómo se ve un aviso y el número en el Dock, y recién
/// después pide el permiso. No obliga: «Abrir Paperclip» funciona aunque diga que no, y la app lo recuerda.
struct WelcomeNotificationsStep: View {
    @Bindable var model: WelcomeModel

    var body: some View {
        VStack(spacing: 0) {
            NotificationPreview()
                .padding(.top, 54)
            Text("Never miss a decision")
                .font(.title)
                .bold()
                .padding(.top, 22)
            Text("Dispatch notifies you only when an agent is waiting for you.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            WelcomeCard(spacing: 0) {
                permissionRow
                Divider().padding(.vertical, 12)
                HStack(spacing: 14) {
                    RowText(title: String(localized: "Open at Login"), detail: String(localized: "So notifications arrive as soon as you turn on your Mac."))
                    Spacer(minLength: 0)
                    Toggle("Open at Login", isOn: $model.launchAtLogin)
                        .toggleStyle(.greenSwitch)
                        .labelsHidden()
                }
            }
            .frame(maxWidth: WelcomeDesign.cardWidth)
            .padding(.top, 24)
        }
        .padding(.horizontal, WelcomeDesign.contentInset)
        .animation(WelcomeDesign.animation, value: model.notificationAccess)
        .task { await model.refreshNotifications() }
        // Al volver de Ajustes del Sistema, el permiso puede haber cambiado.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshNotifications() }
        }
    }

    private var permissionRow: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("macOS notifications").font(.headline)
                if waitingForAnswer {
                    PermissionPromptHint()
                        .font(.callout)
                        .transition(.opacity)
                } else {
                    Text(permissionDetail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 0)
            permissionControl
        }
        .animation(WelcomeDesign.animation, value: waitingForAnswer)
    }

    /// El aviso de permiso de macOS está a la vista, esperando la respuesta.
    private var waitingForAnswer: Bool {
        model.requestingNotifications && model.notificationAccess?.permission == .notDetermined
    }

    @ViewBuilder private var permissionControl: some View {
        switch model.notificationAccess {
        case let access? where access.isComplete:
            AllowedBadge()
        case let access? where access.permission == .granted:
            Button("Adjust", action: NotificationAccess.openSystemSettings)
                .buttonStyle(.glass)
        case let access? where access.permission == .denied:
            Button("Open System Settings", action: NotificationAccess.openSystemSettings)
                .buttonStyle(.glass)
        case _ where model.notificationRequestFailed:
            Button("Open System Settings", action: NotificationAccess.openSystemSettings)
                .buttonStyle(.glass)
        default:
            // Sigue activo mientras espera: si se cierra el aviso de macOS con la ×, se puede volver a pedir.
            Button("Allow Notifications") { Task { await model.requestNotifications() } }
                .buttonStyle(.glassProminent)
                .disabled(model.notificationAccess == nil)
        }
    }

    private var permissionDetail: String {
        guard let access = model.notificationAccess else { return String(localized: "Banners, sound, and the badge on the Dock icon.") }
        switch access.permission {
        case .notDetermined where model.notificationRequestFailed:
            return String(localized: "macOS didn’t allow asking for permission from here. Turn them on in System Settings → Notifications.")
        case .notDetermined:
            return String(localized: "Banners, sound, and the badge on the Dock icon.")
        case .denied:
            return String(localized: "Off. You can turn them on anytime; the app will remind you.")
        case .granted:
            switch (access.banners, access.badge) {
            case (true, true): return String(localized: "Banners, sound, and the badge on the Dock icon: all on.")
            case (false, true): return String(localized: "Allowed, but without banners: you’d only see them in Notification Center.")
            case (true, false): return String(localized: "Allowed, but without the badge on the Dock icon.")
            case (false, false): return String(localized: "Allowed, but without banners or the badge on the Dock icon.")
            }
        }
    }
}

/// «Permitidos», con el check que rebota al aparecer: se nota que la app ya lo detectó, sin mirar dos veces.
private struct AllowedBadge: View {
    /// Lo que espera para rebotar, para que se vea después de aparecer.
    private static let bounceDelay: Duration = .milliseconds(250)

    @State private var bounce = 0

    var body: some View {
        StatusBadge(text: String(localized: "Allowed"), symbol: "checkmark.circle.fill", tint: .green, bounce: bounce)
            .task {
                try? await Task.sleep(for: Self.bounceDelay)
                bounce += 1
            }
    }
}

/// El título y la explicación de una fila del recuadro.
private struct RowText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }
}

/// Un aviso de ejemplo como los de macOS y el ícono del Dock con su número. Es solo un dibujo.
private struct NotificationPreview: View {
    private static let size = CGSize(width: 470, height: 132)
    private static let bannerWidth: CGFloat = 360
    private static let dockTile: CGFloat = 92
    /// Lo que espera el banner para bajar, para que se vea entrar después de que aparece el paso.
    private static let appearDelay: Duration = .milliseconds(250)
    private static let appearAnimation: Animation = .spring(duration: 0.7, bounce: 0.3)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            banner
                .padding(.top, 10)
                .offset(y: shown || reduceMotion ? 0 : -14)
                .opacity(shown ? 1 : 0)
            dockTile
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 6)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample notification: the CEO asks for your decision on ACME-42, and the Dock icon shows 2 pending.")
        .task {
            try? await Task.sleep(for: Self.appearDelay)
            withAnimation(Self.appearAnimation) { shown = true }
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 11) {
            AppIconImage(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("CEO · ACME-42").font(.subheadline).bold()
                Text("Should we hire a design agent for the new page?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("now")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.bannerWidth, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 10)
    }

    private var dockTile: some View {
        AppIconImage(size: 64)
            .overlay(alignment: .topTrailing) {
                Text("2")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(.red, in: .capsule)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                    .offset(x: 8, y: -6)
            }
            .frame(width: Self.dockTile, height: Self.dockTile)
            // El vidrio va detrás: con el ícono y el número adentro, el vidrio los vuelve translúcidos.
            .background { Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 26)) }
    }
}
