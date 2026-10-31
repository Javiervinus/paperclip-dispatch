import SwiftUI

/// Lo que muestra la ventana cuando Paperclip no responde, en vez de la página en blanco de WebKit.
@MainActor
@Observable
final class OfflineModel {
    var serverURL: URL?
    var reason = ""
    /// El Paperclip de esta Mac, si la dirección es suya: se puede encender desde aquí.
    var local: LocalPaperclip?
    var starting = false
    var startError: String?

    @ObservationIgnored var onRetry: (() -> Void)?
    @ObservationIgnored var onChangeServer: (() -> Void)?

    /// Por qué no cargó, en español: el texto del error lo arma el proceso de red de WebKit, que no usa el
    /// idioma de la app.
    static func reason(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorCannotConnectToHost:
            return "No acepta conexiones: Paperclip puede estar apagado."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No se encuentra ese nombre en la red. Revisa la dirección."
        case NSURLErrorTimedOut:
            return "No contestó a tiempo."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Esta Mac no tiene conexión a la red."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return "La conexión segura falló: el certificado no es válido."
        default:
            return "No se pudo conectar (error \(error.code))."
        }
    }

    func start() {
        guard let local else { return }
        starting = true
        startError = nil
        Task {
            startError = await PaperclipLocator.start(local)
            if startError != nil { starting = false }
        }
    }
}

struct OfflineView: View {
    let model: OfflineModel

    var body: some View {
        VStack(spacing: 14) {
            Text("No se puede abrir Paperclip")
                .font(.title2)
                .bold()
            VStack(spacing: 4) {
                Text(detail)
                if model.local == nil, !model.reason.isEmpty {
                    Text(model.reason).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Label {
                Text(model.starting ? "Encendiendo… puede tardar un minuto." : "Se vuelve a intentar cada pocos segundos.")
            } icon: {
                ProgressView().controlSize(.mini)
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            if let error = model.startError {
                WarningRow(text: error)
            }
            HStack(spacing: 10) {
                Button("Cambiar dirección…") { model.onChangeServer?() }
                    .buttonStyle(.glass)
                if model.local != nil {
                    Button("Encender Paperclip", action: model.start)
                        .buttonStyle(.glass)
                        .disabled(model.starting)
                }
                Button("Reintentar") { model.onRetry?() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: 440)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var detail: String {
        if model.local != nil { return "Paperclip está apagado en esta Mac." }
        guard let url = model.serverURL, let host = url.host() else { return "Paperclip no responde." }
        return "\(url.port.map { "\(host):\($0)" } ?? host) no responde."
    }
}
