import SwiftUI

/// Medidas del panel de actualizaciones.
enum UpdatesDesign {
    static let width: CGFloat = 392
    static let iconSize: CGFloat = 38
    /// Entre el ícono y el texto de cada fila.
    static let iconSpacing: CGFloat = 11
    /// Las novedades que se muestran antes de mandar a GitHub por el resto.
    static let maxNoteItems = 5
    /// Líneas por novedad: las largas se cortan y siguen en GitHub.
    static let noteLineLimit = 3
    static let rowPadding: CGFloat = 12
    /// Lo de debajo de cada fila empieza alineado con su texto, no con el ícono.
    static let textInset: CGFloat = iconSize + iconSpacing
}

/// Lo que el panel puede pedir.
struct UpdatesPanelActions {
    let checkAll: () -> Void
    let updatePaperclip: () -> Void
}

/// El panel que abre el botón de arriba a la derecha: una fila para esta app y otra para Paperclip, cada una
/// con su versión, lo que pasa al actualizarla y sus novedades. Los plugins tienen su propio botón y su panel
/// (`PluginsPanel`).
struct UpdatesPanel: View {
    let app: AppUpdater
    let status: AppStatus
    let actions: UpdatesPanelActions
    /// La campana de abajo: avisar de las versiones nuevas (`Preferences.updateNotifications`).
    @Binding var notifiesOfNewVersions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Updates")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, UpdatesDesign.rowPadding)
                .padding(.top, 8)
                .padding(.bottom, 2)
            DispatchUpdateRow(app: app)
            Divider().padding(.horizontal, UpdatesDesign.rowPadding)
            PaperclipUpdateRow(status: status, update: actions.updatePaperclip)
            Divider().padding(.horizontal, UpdatesDesign.rowPadding)
            footer
        }
        .padding(6)
        .frame(width: UpdatesDesign.width)
    }

    private var footer: some View {
        HStack {
            Text(checkedLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                notifiesOfNewVersions.toggle()
            } label: {
                Label(
                    "Notify me of new versions",
                    systemImage: notifiesOfNewVersions ? "bell" : "bell.slash"
                )
                .labelStyle(.iconOnly)
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(notifiesOfNewVersions
                ? String(localized: "Notifies you of new versions, without sound. Click to stop.")
                : String(localized: "Doesn’t notify you of new versions. Click to turn it on."))
            .accessibilityValue(notifiesOfNewVersions ? Text("On") : Text("Off"))
            Button("Check Now", action: actions.checkAll)
                .buttonStyle(.glass)
                .disabled(busy)
        }
        .padding(.horizontal, UpdatesDesign.rowPadding)
        .padding(.vertical, 8)
    }

    private var busy: Bool {
        status.checkingUpdate || status.updateProgress != nil || app.phase == .checking
    }

    private var checkedLine: String {
        let dates = [app.lastCheckedAt, status.lastCheckedAt].compactMap(\.self)
        guard let last = dates.max() else { return String(localized: "Checks automatically every few hours") }
        // Sin punto final: la hora ya puede terminar en uno («10:37 p. m.»).
        return String(localized: "Last checked: \(last.formatted(date: .omitted, time: .shortened))")
    }
}

// MARK: - Esta app

private struct DispatchUpdateRow: View {
    let app: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: UpdatesDesign.iconSpacing) {
                AppIconImage(size: UpdatesDesign.iconSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dispatch \(app.phase.release?.version ?? AppUpdater.currentVersion)")
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing
            }
            Group {
                if let release = app.phase.release {
                    details(for: release)
                } else if let news = app.whatsNew {
                    whatsNew(news)
                }
                if let error = app.checkError {
                    WarningRow(text: String(localized: "Couldn’t check for app updates: \(error)"))
                }
            }
            .padding(.leading, UpdatesDesign.textInset)
        }
        .padding(UpdatesDesign.rowPadding)
        .background(highlighted ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 16))
    }

    private var highlighted: Bool { app.phase.release != nil || app.whatsNew != nil }

    private var subtitle: String {
        switch app.phase {
        case .idle where !app.isConfigured: String(localized: "This app · this copy doesn’t check for new versions")
        case .idle where app.whatsNew != nil: String(localized: "This app · just updated")
        case .idle: app.lastCheckedAt == nil ? String(localized: "This app") : String(localized: "This app · up to date")
        case .checking: String(localized: "This app · checking…")
        default: String(localized: "This app · you have \(AppUpdater.currentVersion)")
        }
    }

    @ViewBuilder private var trailing: some View {
        switch app.phase {
        case .idle:
            if app.whatsNew != nil {
                Button("Done", action: app.dismissWhatsNew).buttonStyle(.glass)
            } else if app.isConfigured, app.lastCheckedAt != nil {
                UpToDateBadge()
            }
        case .checking:
            ProgressView().controlSize(.small)
        case .available:
            Button("Download and Restart", action: app.install).buttonStyle(.glassProminent)
        case .downloading(_, let progress):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progress.map { String(localized: "\(Int(($0 * 100).rounded()))%") } ?? String(localized: "Preparing…"))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Button("Restart", action: app.install).buttonStyle(.glassProminent)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Restarting…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func details(for release: AppUpdater.Release) -> some View {
        Text("When you restart, this app quits and reopens in a few seconds, on the same page. Paperclip and your agents don’t stop: they run separately.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let notes = release.notes {
            ReleaseNotesView(markdown: notes, link: release.notesURL)
        } else if let link = release.notesURL {
            Link(destination: link) { Label("What’s New on GitHub", systemImage: "arrow.up.right") }
                .font(.callout)
        }
        switch app.phase {
        case .ready:
            Text("If you’d rather wait, it installs automatically the next time you quit the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available:
            Text("Automatic downloads are turned off in Settings → General.")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func whatsNew(_ release: AppUpdater.Release) -> some View {
        if let notes = release.notes {
            ReleaseNotesView(markdown: notes, link: release.notesURL, title: String(localized: "What’s New in \(release.version)"))
        } else if let link = release.notesURL {
            Link(destination: link) { Label("What’s New in \(release.version)", systemImage: "arrow.up.right") }
                .font(.callout)
        }
    }
}

// MARK: - Paperclip

private struct PaperclipUpdateRow: View {
    let status: AppStatus
    let update: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: UpdatesDesign.iconSpacing) {
                PaperclipGlyph(size: UpdatesDesign.iconSize)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing
            }
            Group {
                if let latest = status.latestVersion, status.updateProgress == nil {
                    Text("Updating Paperclip restarts it and pauses your agents in the meantime: best done at a quiet moment.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: UpdateController.releaseNotesURL(for: latest)) {
                        Label("What’s New in Paperclip", systemImage: "arrow.up.right")
                    }
                    .font(.callout)
                }
                if let error = status.updateCheckError, status.updatesUnavailable == nil {
                    WarningRow(text: String(localized: "Couldn’t check Paperclip: \(error)"))
                }
            }
            .padding(.leading, UpdatesDesign.textInset)
        }
        .padding(UpdatesDesign.rowPadding)
    }

    private var title: String {
        guard let version = status.latestVersion ?? status.paperclipVersion else { return "Paperclip" }
        return "Paperclip \(version)"
    }

    private var subtitle: String {
        if let unavailable = status.updatesUnavailable { return String(localized: "The server · \(unavailable)") }
        if let progress = status.updateProgress { return String(localized: "The server · \(progress)") }
        if status.checkingUpdate { return String(localized: "The server · checking…") }
        if status.latestVersion != nil, let current = status.paperclipVersion {
            return String(localized: "The server · you have \(current)")
        }
        return status.paperclipVersion == nil ? String(localized: "The server") : String(localized: "The server · up to date")
    }

    @ViewBuilder private var trailing: some View {
        if status.updateProgress != nil || status.checkingUpdate {
            ProgressView().controlSize(.small)
        } else if status.latestVersion != nil {
            Button("Update…", action: update).buttonStyle(.glass)
        } else if status.paperclipVersion != nil, status.updatesUnavailable == nil {
            UpToDateBadge()
        }
    }
}

// MARK: - Piezas

/// Las novedades de una versión: Markdown sencillo (títulos `###` y listas `-`), recortado a unas pocas
/// para que el panel no se vuelva un muro de texto. Si hay más, manda a GitHub.
struct ReleaseNotesView: View {
    let markdown: String
    let link: URL?
    var title = String(localized: "What’s New")

    var body: some View {
        let notes = ReleaseNotes(markdown: markdown, maxItems: UpdatesDesign.maxNoteItems)
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(notes.shown.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                case .item(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(ReleaseNotes.inline(text)).lineLimit(UpdatesDesign.noteLineLimit)
                    }
                case .paragraph(let text):
                    Text(ReleaseNotes.inline(text)).lineLimit(UpdatesDesign.noteLineLimit)
                }
            }
            if notes.truncated {
                if let link {
                    Link(destination: link) { Label("See All on GitHub", systemImage: "arrow.up.right") }
                        .padding(.top, 2)
                } else {
                    Text("…and more.").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

/// El Markdown de las novedades, en bloques. Solo lo que usa el CHANGELOG: títulos, listas y párrafos.
struct ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case item(String)
        case paragraph(String)
    }

    let shown: [Block]
    let truncated: Bool

    init(markdown: String, maxItems: Int) {
        var blocks: [Block] = []
        var current: Block?
        func flush() {
            if let current { blocks.append(current) }
            current = nil
        }
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                blocks.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                current = .item(String(line.dropFirst(2)))
            } else {
                switch current {
                case .item(let text): current = .item(text + " " + line)
                case .paragraph(let text): current = .paragraph(text + " " + line)
                default: current = .paragraph(line)
                }
            }
        }
        flush()

        var shown: [Block] = []
        var count = 0
        var truncated = false
        for block in blocks {
            if case .heading = block {
                shown.append(block)
                continue
            }
            guard count < maxItems else {
                truncated = true
                break
            }
            shown.append(block)
            count += 1
        }
        // Un título sin nada debajo (lo de abajo quedó fuera) no se muestra.
        while case .heading = shown.last { shown.removeLast() }
        self.shown = shown
        self.truncated = truncated
    }

    /// Negritas, cursivas, código y enlaces dentro de una línea.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// El ícono de la app a un tamaño dado, el mismo que muestran el Dock y los avisos. Se vuelve a pedir a macOS
/// cuando cambia la apariencia (con el estilo «Automático» cambia el ícono) y al volver a la app, que es
/// cuando se pudo cambiar el estilo de íconos en Ajustes del Sistema.
struct AppIconImage: View {
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @State private var icon = AppIcon.image()

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .onChange(of: colorScheme) { icon = AppIcon.image() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                icon = AppIcon.image()
            }
    }
}

/// El clip de Paperclip (el servidor), para distinguirlo del ícono de esta app. Con otro símbolo, lo que vive
/// dentro de Paperclip (sus plugins).
struct PaperclipGlyph: View {
    let size: CGFloat
    var symbol = "paperclip"

    var body: some View {
        RoundedRectangle(cornerRadius: size * SettingsDesign.iconCornerRatio, style: .continuous)
            .fill(.fill.secondary)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .accessibilityHidden(true)
    }
}

struct UpToDateBadge: View {
    var body: some View {
        Label {
            Text("Up to date").foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
        }
        .font(.callout)
    }
}
