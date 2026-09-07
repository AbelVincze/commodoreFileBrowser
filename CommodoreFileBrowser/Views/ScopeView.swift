import SwiftUI
import AppKit

/// The live oscilloscope, for whichever player is behind it.
///
/// It asks for traces rather than reaching into a player, because the two
/// players have nothing in common at this level: the SID engine keeps a ring
/// per voice inside its own C, and a module has only its output to tap. What
/// they agree on is a list of traces and how many columns to lay them out in.
///
/// The samples are held in state and refreshed on a timer rather than read
/// inside a TimelineView's drawing closure. With TimelineView the closure
/// ignored the tick, so every redraw produced an identical Canvas and SwiftUI
/// skipped it: the scope drew one frame and then sat still until some other
/// property of the player happened to change. Assigning to @State always
/// invalidates.
struct ScopeView: View {
    let palette: Palette
    /// Redrawn only while this is true; a stopped player has nothing new.
    let isRunning: Bool
    let columns: Int
    let lineWidth: CGFloat
    /// Called on the main thread, 50 times a second.
    let traces: () -> [[Int16]]
    /// Changing this re-reads immediately rather than waiting for the tick, so
    /// switching modes does not leave the old arrangement on screen.
    let mode: String

    @State private var captured: [[Int16]] = []
    /// .common so the trace keeps moving while a menu or a drag is up.
    @State private var tick = Timer.publish(every: 1.0 / 50.0, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                ScopeRenderer.draw(in: cg, size: size, traces: captured, columns: columns,
                                   lineWidth: lineWidth,
                                   foreground: NSColor(palette.color(.text)).cgColor,
                                   background: NSColor(palette.color(.panel)).cgColor,
                                   grid: NSColor(palette.color(.border)).cgColor)
            }
        }
        .onAppear { captured = traces() }
        .onChange(of: mode) { _, _ in captured = traces() }
        .onReceive(tick) { _ in if isRunning { captured = traces() } }
    }
}

extension ScopeView {
    /// The SID player's: one cell for the mix, or three rows of voices with a
    /// column per chip.
    init(player: SIDPlayer, mode: ScopeMode, palette: Palette) {
        let (rows, columns) = ScopeRenderer.grid(mode: mode, sidCount: player.sidCount)
        self.init(palette: palette,
                  isRunning: player.isPlaying,
                  columns: columns,
                  lineWidth: mode == .mix ? 1.5 : 1.2,
                  traces: {
                      let samples = player.scopeSnapshot(mode: mode)
                      return (0..<rows).flatMap { row in
                          (0..<columns).map { column in
                              samples[ScopeRenderer.track(mode: mode, row: row, column: column)] ?? []
                          }
                      }
                  },
                  mode: mode.rawValue)
    }

    /// The module player's: the output, mixed or as left over right.
    init(player: ModulePlayer, mode: ModuleScopeMode, palette: Palette) {
        self.init(palette: palette,
                  isRunning: player.isPlaying,
                  columns: 1,
                  lineWidth: mode == .mix ? 1.5 : 1.2,
                  traces: { player.scopeSnapshot(mode: mode) },
                  mode: mode.rawValue)
    }
}
