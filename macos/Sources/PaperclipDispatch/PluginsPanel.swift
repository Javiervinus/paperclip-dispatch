import SwiftUI

/// Medidas del panel de plugins.
enum PluginsDesign {
    static let width: CGFloat = 360
    /// Desde cuántos plugins la lista se desplaza en vez de crecer.
    static let maxVisible = 7
    static let lineHeight: CGFloat = 22
    static let lineSpacing: CGFloat = 6
}

/// El panel que abre el botón de los plugins (`PluginsButton`): todos los plugins de Paperclip, primero los que
/// tienen versión nueva, cada uno en una línea. Con muchos, la lista se desplaza: el panel no crece. Los de npm
/// se actualizan aquí; los que salen de una carpeta, en esa carpeta.
struct PluginsPanel: View {
    let plugins: PluginUpdates

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Plugins")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: 24)
            .padding(.horizontal, UpdatesDesign.rowPadding)
            .padding(.top, 8)
            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                list
                notes
            }
            .padding(UpdatesDesign.rowPadding)
            Divider().padding(.horizontal, UpdatesDesign.rowPadding)
            footer
        }
        .padding(6)
        .frame(width: PluginsDesign.width)
    }

    /// Los que tienen versión nueva arriba; el resto, en el orden de Paperclip.
    private var sorted: [PluginUpdates.Plugin] {
        plugins.available + plugins.plugins.filter { $0.latest == nil }
    }

    @ViewBuilder private var list: some View {
        let lines = VStack(alignment: .leading, spacing: PluginsDesign.lineSpacing) {
            ForEach(sorted) { plugin in
                PluginLine(plugin: plugin, plugins: plugins)
            }
        }
        if plugins.plugins.count > PluginsDesign.maxVisible {
            let visible = CGFloat(PluginsDesign.maxVisible)
            ScrollView {
                lines.padding(.trailing, 4)
            }
            // Asoma media línea más: así se nota que la lista sigue.
            .frame(height: visible * (PluginsDesign.lineHeight + PluginsDesign.lineSpacing) + PluginsDesign.lineHeight / 2)
        } else {
            lines
        }
    }

    @ViewBuilder private var notes: some View {
        if !plugins.available.isEmpty {
            Group {
                if plugins.canUpdate {
                    Text("Your agents keep working: Paperclip swaps only the plugin, and the page reloads.")
                } else {
                    Text("Only whoever runs this Paperclip can update its plugins.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(plugins.plugins.filter { plugins.updateErrors[$0.id] != nil }) { plugin in
            WarningRow(text: String(localized: "Couldn’t update \(plugin.name): \(plugins.updateErrors[plugin.id] ?? "")"))
                .font(.caption)
        }
        if let error = plugins.checkError {
            WarningRow(text: String(localized: "Couldn’t check the plugins: \(error)")).font(.caption)
        }
    }

    private var subtitle: String {
        let count = plugins.plugins.count
        if let updating = plugins.updating { return String(localized: "Updating \(updating.name)…") }
        if plugins.checking { return String(localized: "\(count) in Paperclip · checking…") }
        let available = plugins.available.count
        if available > 0 { return String(localized: "\(count) in Paperclip · \(available) with a new version") }
        return String(localized: "\(count) in Paperclip · up to date")
    }

    @ViewBuilder private var trailing: some View {
        if plugins.checking {
            ProgressView().controlSize(.small)
        } else if plugins.available.isEmpty, plugins.lastCheckedAt != nil {
            UpToDateBadge()
        } else if plugins.available.count > 1, plugins.canUpdate, plugins.updatingID == nil {
            Button("Update All", action: plugins.updateAll)
                .buttonStyle(.glass)
        }
    }

    private var footer: some View {
        HStack {
            Text(checkedLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Check Now", action: plugins.checkNow)
                .buttonStyle(.glass)
                .disabled(plugins.checking || plugins.updatingID != nil)
        }
        .padding(.horizontal, UpdatesDesign.rowPadding)
        .padding(.vertical, 8)
    }

    private var checkedLine: String {
        guard let last = plugins.lastCheckedAt else { return String(localized: "Checks automatically every few hours") }
        return String(localized: "Last checked: \(last.formatted(date: .omitted, time: .shortened))")
    }
}

/// Un plugin en una línea: nombre, versión (con la nueva, si hay) y su botón. Los que salen de una carpeta
/// llevan el ícono de carpeta, sin botón.
private struct PluginLine: View {
    let plugin: PluginUpdates.Plugin
    let plugins: PluginUpdates

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: plugin.name)
                .lineLimit(1)
            if plugin.source == .folder {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .help("From a folder: it updates there")
            }
            Spacer(minLength: 8)
            Text(verbatim: plugin.latest.map { "\(plugin.version) → \($0)" } ?? plugin.version)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let link = plugin.packageURL, plugin.latest != nil {
                Link(destination: link) { Image(systemName: "arrow.up.right.square") }
                    .foregroundStyle(.secondary)
                    .help("See It on npm")
            }
            if plugins.updatingID == plugin.id {
                ProgressView().controlSize(.mini)
            } else if plugin.latest != nil, plugins.canUpdate {
                Button("Update") { plugins.update(plugin) }
                    .controlSize(.small)
                    .disabled(plugins.updatingID != nil)
            }
        }
        .font(.callout)
        .frame(minHeight: PluginsDesign.lineHeight)
    }
}
