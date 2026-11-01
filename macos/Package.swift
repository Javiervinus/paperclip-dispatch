// swift-tools-version: 6.2
// Paperclip Dispatch: la app nativa de macOS para Paperclip (Liquid Glass, avisos y actualización).
// build.sh la compila con `swift build` y arma el .app; no hace falta un proyecto de Xcode.
import PackageDescription

let package = Package(
    name: "PaperclipDispatch",
    // Los textos del código están en inglés; su traducción al español, en los String Catalogs del target
    // (Localizable.xcstrings y, para el Info.plist, InfoPlist.xcstrings). build.sh copia sus .lproj al .app.
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Las actualizaciones de la propia app: descarga, verifica la firma y reemplaza el .app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .executableTarget(
            name: "PaperclipDispatch",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/PaperclipDispatch",
            resources: [
                .process("Localizable.xcstrings"),
                .process("InfoPlist.xcstrings"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Security"),
            ]
        ),
    ]
)
