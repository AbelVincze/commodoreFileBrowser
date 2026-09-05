import SwiftUI
import AppKit

/// Applies the window chrome as soon as the view is actually attached to a
/// window. Doing this from `makeNSView` is unreliable: SwiftUI has not put the
/// view into a window yet, so `view.window` is still nil and the styling is
/// silently skipped.
private final class WindowConfiguringView: NSView {
    var configure: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { configure?(window) }
    }
}

/// Blends the title bar into the window background: the browser draws all of
/// its own chrome and should be one solid colour edge to edge.
struct WindowStyler: NSViewRepresentable {
    let background: Color
    /// The scheme the browser is actually drawing in, which may differ from
    /// the system one when the theme is forced to Light or Dark.
    let scheme: ColorScheme

    func makeNSView(context: Context) -> NSView {
        let view = WindowConfiguringView()
        view.configure = apply
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowConfiguringView)?.configure = apply
        if let window = view.window { apply(to: window) }
    }

    private func apply(to window: NSWindow) {
        // Content runs under the title bar, so nothing but our own background
        // is ever painted there.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = NSColor(background)
        window.isOpaque = true
        // Without pinning the appearance the title bar keeps the system's and
        // its material reads lighter than the window background.
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }
}

extension Font {
    /// DIN Condensed for the panel type markers, with a condensed system face
    /// as the fallback if the font is not installed.
    static func typeMarker(_ size: CGFloat) -> Font {
        NSFont(name: "DINCondensed-Bold", size: size) != nil
            ? .custom("DINCondensed-Bold", size: size)
            : .system(size: size, weight: .bold).width(.condensed)
    }
}
