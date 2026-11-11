import SwiftUI

/// Lo que encontró el diagnóstico de Paperclip, con «Reparar» y «Revisar de nuevo». Va en Ajustes →
/// Paperclip y en la ventana cuando Paperclip no arranca; con el diagnóstico sin correr no muestra nada.
struct DoctorReportView: View {
    let doctor: DoctorModel

    var body: some View {
        switch doctor.state {
        case .idle:
            EmptyView()
        case let .running(repairing):
            Label {
                Text(repairing ? "Repairing what Paperclip can fix on its own…" : "Checking Paperclip’s setup…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        case let .done(problems) where problems.isEmpty:
            Label("Paperclip’s setup looks fine.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        case let .done(problems):
            VStack(alignment: .leading, spacing: 12) {
                Text("Paperclip’s doctor found:").font(.headline)
                ForEach(problems) { DoctorProblemRow(check: $0) }
                HStack(spacing: 8) {
                    Button("Repair") { doctor.run(repair: true) }
                        .buttonStyle(.glass)
                        .help("Runs paperclipai doctor --repair, which fixes what Paperclip knows how to fix.")
                    Button("Check Again") { doctor.run() }
                        .buttonStyle(.glass)
                }
            }
        case .unavailable:
            WarningRow(text: String(localized: "This needs the Paperclip command. Install it with \(UpdateController.installCLICommand) and try again."))
        case let .unreadable(tail):
            VStack(alignment: .leading, spacing: 6) {
                WarningRow(text: String(localized: "Couldn’t read what Paperclip’s doctor answered:"))
                Text(tail)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Un problema, como lo dice Paperclip (en inglés: es su texto), con lo que sugiere hacer.
private struct DoctorProblemRow: View {
    let check: DoctorCheck

    private static let messageLines = 3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: check.status == .failed ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.status == .failed ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).bold()
                // Hasta unas líneas, para que varios quepan en la ventana; entero al pasar el puntero.
                Text(check.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(Self.messageLines)
                    .help(check.message)
                if let hint = check.hint {
                    Text(hint)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
