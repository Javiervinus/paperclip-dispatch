import Foundation

/// Quién hace la app y dónde está su código, para «Acerca de» y el menú Ayuda. Salen de release.env:
/// build.sh los deja en el Info.plist. Sin repositorio configurado, los enlaces a GitHub no se muestran.
enum AppInfo {
    /// El sitio y la documentación de Paperclip, el proyecto para el que es esta app.
    static let paperclipURL = URL(string: "https://paperclip.ing")!
    static let paperclipDocsURL = URL(string: "https://docs.paperclip.ing")!

    static var author: String? { string("DispatchAuthor") }
    static var authorURL: URL? { string("DispatchAuthorURL").flatMap(URL.init(string:)) }
    static var repositoryURL: URL? { string("DispatchRepositoryURL").flatMap(URL.init(string:)) }
    /// Las versiones publicadas, con sus novedades.
    static var releasesURL: URL? { repositoryURL?.appending(path: "releases") }
    static var newIssueURL: URL? { repositoryURL?.appending(path: "issues/new") }

    private static func string(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
