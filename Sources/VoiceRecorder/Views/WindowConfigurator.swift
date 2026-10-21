import AppKit
import SwiftUI

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.backgroundColor = .white
            window.isOpaque = true
            window.toolbarStyle = .unifiedCompact
            window.appearance = NSAppearance(named: .aqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}
