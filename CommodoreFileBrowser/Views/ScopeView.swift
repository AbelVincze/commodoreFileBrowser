import SwiftUI
import AppKit

/// The live oscilloscope.
///
/// The samples are held in state and refreshed on a timer rather than read
/// inside a TimelineView's drawing closure. With TimelineView the closure
/// ignored the tick, so every redraw produced an identical Canvas and SwiftUI
/// skipped it: the scope drew one frame and then sat still until some other
/// property of the player happened to change. Assigning to @State always
/// invalidates.
struct ScopeView: View {
    @ObservedObject var player: SIDPlayer
    let mode: ScopeMode
    let palette: Palette

    @State private var samples: [Int: [Int16]] = [:]
    /// .common so the trace keeps moving while a menu or a drag is up.
    @State private var tick = Timer.publish(every: 1.0 / 50.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                ScopeRenderer.draw(in: cg, size: size, mode: mode,
                                   sidCount: player.sidCount, samples: samples,
                                   foreground: NSColor(palette.color(.text)).cgColor,
                                   background: NSColor(palette.color(.panel)).cgColor,
                                   grid: NSColor(palette.color(.border)).cgColor)
            }
        }
        .onAppear { refresh() }
        .onChange(of: mode) { _, _ in refresh() }
        .onReceive(tick) { _ in if player.isPlaying { refresh() } }
    }

    private func refresh() { samples = player.scopeSnapshot(mode: mode) }
}
