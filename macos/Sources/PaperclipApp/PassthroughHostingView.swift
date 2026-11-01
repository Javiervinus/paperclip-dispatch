import SwiftUI

/// Una vista de SwiftUI encima de otra que no recibe clics ni el puntero: todo pasa a lo de abajo.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
