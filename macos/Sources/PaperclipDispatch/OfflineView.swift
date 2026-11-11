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
    /// Si Paperclip arranca al iniciar sesión: si no, se sugiere.
    let startup = PaperclipStartup()
    /// El diagnóstico de Paperclip, que se corre solo si no arranca.
    let doctor = DoctorModel()

    /// Lo que se espera a que Paperclip responda antes de correr el diagnóstico.
    private static let startTimeout: Duration = .seconds(60)
    @ObservationIgnored private var startWatch: Task<Void, Never>?

    @ObservationIgnored var onRetry: (() -> Void)?
    @ObservationIgnored var onChangeServer: (() -> Void)?

    /// Por qué no cargó, en español: el texto del error lo arma el proceso de red de WebKit, que no usa el
    /// idioma de la app.
    static func reason(for error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorCannotConnectToHost:
            return String(localized: "It isn’t accepting connections: Paperclip may not be running.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return String(localized: "That name can’t be found on the network. Check the address.")
        case NSURLErrorTimedOut:
            return String(localized: "It didn’t respond in time.")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return String(localized: "This Mac isn’t connected to the network.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            return String(localized: "The secure connection failed: the certificate isn’t valid.")
        default:
            return String(localized: "Couldn’t connect (error \(error.code)).")
        }
    }

    func start() {
        guard let local else { return }
        begin {
            await PaperclipLocator.start(local)
        }
    }

    /// Lo deja arrancando al iniciar sesión y lo enciende ya, en segundo plano (sin Terminal).
    func startAtLogin() {
        begin { [startup] in
            await startup.enableAndStart()
        }
    }

    /// Paperclip volvió: lo de este intento ya no sirve.
    func reset() {
        startWatch?.cancel()
        starting = false
        startError = nil
        doctor.reset()
    }

    /// Enciende con `action` (que devuelve un error, o nil) y, si falla o no responde en un minuto, corre el
    /// diagnóstico de Paperclip para mostrar por qué.
    private func begin(_ action: @escaping @MainActor () async -> String?) {
        startWatch?.cancel()
        starting = true
        startError = nil
        doctor.reset()
        startWatch = Task {
            if let error = await action() {
                startError = error
                starting = false
                doctor.run()
                return
            }
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, starting else { return }
            starting = false
            doctor.run()
        }
    }
}

struct OfflineView: View {
    let model: OfflineModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Can’t open Paperclip")
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
                Text(model.starting ? "Starting… this may take a minute." : "Trying again every few seconds.")
            } icon: {
                ProgressView().controlSize(.mini)
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            if let error = model.startError {
                WarningRow(text: error)
            }
            HStack(spacing: 10) {
                Button("Change Address…") { model.onChangeServer?() }
                    .buttonStyle(.glass)
                if model.local != nil {
                    Button("Start Paperclip", action: model.start)
                        .buttonStyle(.glass)
                        .disabled(model.starting)
                }
                Button("Try Again") { model.onRetry?() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 6)
            if model.local != nil {
                extras
            }
        }
        .frame(maxWidth: 440)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    /// Bajo los botones: la sugerencia de encenderlo al iniciar sesión y el diagnóstico.
    @ViewBuilder private var extras: some View {
        if model.startup.state == .off, !model.starting {
            VStack(spacing: 8) {
                Text("So you don’t have to start it by hand, Paperclip can start on its own when you log in, in the background.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start It at Login", action: model.startAtLogin)
                    .buttonStyle(.glass)
                    .disabled(model.startup.busy)
            }
            .padding(.top, 14)
        }
        if model.doctor.state == .idle {
            if !model.starting {
                Button("Check Paperclip’s Setup…") { model.doctor.run() }
                    .buttonStyle(.link)
                    .padding(.top, 6)
            }
        } else {
            DoctorReportView(doctor: model.doctor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        }
    }

    private var detail: String {
        if model.local != nil { return String(localized: "Paperclip isn’t running on this Mac.") }
        guard let url = model.serverURL, let host = url.host() else { return String(localized: "Paperclip isn’t responding.") }
        return String(localized: "\(url.port.map { "\(host):\($0)" } ?? host) isn’t responding.")
    }
}
