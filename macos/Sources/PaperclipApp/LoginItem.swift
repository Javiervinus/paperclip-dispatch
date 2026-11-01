import Foundation
import ServiceManagement

/// Abrir la app al iniciar sesión, con `SMAppService`.
///
/// macOS guarda el ítem de inicio con la ruta que tenía la app al activarlo. Si después se mueve o se
/// reemplaza por una copia con otro nombre, el ítem sigue apuntando a la ruta vieja y al iniciar sesión no
/// abre nada, aunque Ajustes lo muestre activado. Por eso se recuerda la ruta y se vuelve a registrar si
/// cambió.
@MainActor
enum LoginItem {
    private static let registeredPathKey = "loginItemRegisteredPath"

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
        } else {
            try SMAppService.mainApp.unregister()
            UserDefaults.standard.removeObject(forKey: registeredPathKey)
        }
    }

    /// Al abrir: si el ítem está activado pero se registró desde otra ruta, lo apunta a esta.
    static func followMove() {
        guard status == .enabled,
              UserDefaults.standard.string(forKey: registeredPathKey) != Bundle.main.bundlePath
        else { return }
        try? SMAppService.mainApp.unregister()
        try? setEnabled(true)
    }
}
