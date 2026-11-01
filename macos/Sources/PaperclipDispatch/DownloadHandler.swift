import Foundation
import WebKit

/// Descargas de Paperclip (adjuntos, exportaciones): van a la carpeta Descargas, sin pisar archivos.
@MainActor
final class DownloadHandler: NSObject, WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        return Self.freeURL(in: folder, for: suggestedFilename)
    }

    /// informe.pdf, informe 2.pdf, informe 3.pdf…, como Safari.
    private static func freeURL(in folder: URL, for filename: String) -> URL {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appending(path: filename)
        var copy = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(name) \(copy)" : "\(name) \(copy).\(ext)"
            candidate = folder.appending(path: numbered)
            copy += 1
        }
        return candidate
    }
}
