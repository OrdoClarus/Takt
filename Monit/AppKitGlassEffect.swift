import AppKit
import SwiftUI

struct AppKitGlassEffect<Content: View>: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tintColor: NSColor?
    let isInteractive: Bool
    @ViewBuilder let content: () -> Content

    init(
        cornerRadius: CGFloat,
        tintColor: NSColor? = nil,
        isInteractive: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.isInteractive = isInteractive
        self.content = content
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let glassView = NSGlassEffectView()
        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = tintColor
        if #available(macOS 27.0, *) {
            glassView.effectIsInteractive = isInteractive
        }
        glassView.contentView = NSHostingView(rootView: content())
        return glassView
    }

    func updateNSView(_ glassView: NSGlassEffectView, context: Context) {
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = tintColor
        if #available(macOS 27.0, *) {
            glassView.effectIsInteractive = isInteractive
        }

        if let hostingView = glassView.contentView as? NSHostingView<Content> {
            hostingView.rootView = content()
        } else {
            glassView.contentView = NSHostingView(rootView: content())
        }
    }
}
