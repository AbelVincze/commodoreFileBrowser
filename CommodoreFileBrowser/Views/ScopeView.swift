import SwiftUI
import CoreGraphics

enum ScopeMode: String, CaseIterable, Identifiable {
    case mix, voices
    var id: String { rawValue }
    var label: String { self == .mix ? "Mixed" : "Per voice" }
}

/// Draws the oscilloscope. Shared by the live view and the video export so the
/// file matches what is on screen.
enum ScopeRenderer {

    /// Three rows, one column per SID chip: a column is that chip's voices 1-3.
    static func grid(mode: ScopeMode, sidCount: Int) -> (rows: Int, columns: Int) {
        mode == .mix ? (1, 1) : (3, max(1, sidCount))
    }

    /// Track index for a cell. Track 9 is the mix.
    static func track(mode: ScopeMode, row: Int, column: Int) -> Int {
        mode == .mix ? 9 : column * 3 + row
    }

    static func draw(in ctx: CGContext, size: CGSize, mode: ScopeMode, sidCount: Int,
                     samples: [Int: [Int16]], foreground: CGColor, background: CGColor,
                     grid gridColor: CGColor) {
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: size))

        let (rows, columns) = grid(mode: mode, sidCount: sidCount)
        let gap: CGFloat = 3
        let cellW = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let frame = CGRect(x: CGFloat(column) * (cellW + gap),
                                   y: CGFloat(row) * (cellH + gap),
                                   width: cellW, height: cellH)
                // Zero line.
                ctx.setStrokeColor(gridColor)
                ctx.setLineWidth(1)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: frame.minX, y: frame.midY))
                ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                ctx.strokePath()

                guard let data = samples[track(mode: mode, row: row, column: column)],
                      data.count > 1 else { continue }

                ctx.setStrokeColor(foreground)
                ctx.setLineWidth(mode == .mix ? 1.5 : 1.2)
                ctx.beginPath()
                // One column of pixels per step through the window.
                let steps = max(2, Int(frame.width))
                for step in 0..<steps {
                    let index = data.count * step / steps
                    let value = CGFloat(data[min(index, data.count - 1)]) / 32768.0
                    let point = CGPoint(x: frame.minX + CGFloat(step),
                                        y: frame.midY - value * (frame.height / 2 - 2))
                    if step == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
                }
                ctx.strokePath()
            }
        }
    }
}

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
