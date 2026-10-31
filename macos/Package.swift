// swift-tools-version: 6.2
// Paperclip Swift: la app nativa de macOS para Paperclip (Liquid Glass, avisos y actualización).
// build.sh la compila con `swift build` y arma el .app; no hace falta un proyecto de Xcode.
import PackageDescription

let package = Package(
    name: "PaperclipApp",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "PaperclipApp",
            path: "Sources/PaperclipApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
