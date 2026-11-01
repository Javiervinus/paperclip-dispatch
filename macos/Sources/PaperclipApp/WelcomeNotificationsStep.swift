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
            Text("Que no se te pase ninguna decisión")
                .font(.title)
                .bold()
                .padding(.top, 22)
            Text("Dispatch te avisa solo cuando un agente espera por ti.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
            WelcomeCard(spacing: 0) {
                permissionRow
                Divider().padding(.vertical, 12)
                HStack(spacing: 14) {
                    RowText(title: "Abrir al iniciar sesión", detail: "Así los avisos llegan desde que prendes la Mac.")
                    Spacer(minLength: 0)
                    Toggle("Abrir al iniciar sesión", isOn: $model.launchAtLogin)
                        .toggleStyle(.switch)
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
            RowText(title: "Avisos de macOS", detail: permissionDetail)
            Spacer(minLength: 0)
            permissionControl
        }
    }

    @ViewBuilder private var permissionControl: some View {
        switch model.notificationAccess {
        case let access? where access.isComplete:
            StatusBadge(text: "Permitidos", symbol: "checkmark.circle.fill", tint: .green)
        case let access? where access.permission == .granted:
            Button("Ajustar", action: NotificationAccess.openSystemSettings)
                .buttonStyle(.glass)
        case let access? where access.permission == .denied:
            Button("Abrir Ajustes del Sistema", action: NotificationAccess.openSystemSettings)
                .buttonStyle(.glass)
        case _ where model.notificationRequestFailed:
            Button("Abrir Ajustes del Sistema", action: NotificationAccess.openSystemSettings)
                .buttonStyle(.glass)
        default:
            Button("Permitir avisos") { Task { await model.requestNotifications() } }
                .buttonStyle(.glassProminent)
                .disabled(model.notificationAccess == nil || model.requestingNotifications)
        }
    }

    private var permissionDetail: String {
        guard let access = model.notificationAccess else { return "Banners, sonido y el número en el Dock." }
        switch access.permission {
        case .notDetermined where model.notificationRequestFailed:
            return "macOS no dejó pedir el permiso desde aquí. Actívalos en Ajustes del Sistema → Notificaciones."
        case .notDetermined:
            return "Banners, sonido y el número en el Dock."
        case .denied:
            return "Apagados. Puedes activarlos cuando quieras; la app te lo recordará."
        case .granted:
            switch (access.banners, access.badge) {
            case (true, true): return "Banners, sonido y el número en el Dock: todo encendido."
            case (false, true): return "Permitidos, pero sin banner: solo los verías en el Centro de notificaciones."
            case (true, false): return "Permitidos, pero sin el número en el Dock."
            case (false, false): return "Permitidos, pero sin banner ni número en el Dock."
            }
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
        .accessibilityLabel("Ejemplo de aviso: el CEO pide tu decisión en VIN-214, y el ícono del Dock con 2 pendientes.")
        .task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.spring(duration: 0.7, bounce: 0.3)) { shown = true }
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: 11) {
            AppIconImage(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("CEO · VIN-214").font(.subheadline).bold()
                Text("¿Contratamos a un agente de diseño para la página nueva?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text("ahora")
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
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}
