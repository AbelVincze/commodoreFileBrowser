import Foundation
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

    /// Samples drawn in one frame. The window is shorter than the captured
    /// buffer so there is room to slide it to the trigger point.
    static let displayWindow = 1024

    /// Offset of a rising crossing of zero, so every frame starts at the same
    /// point in the wave and the trace stands still rather than sliding. This
    /// is what an oscilloscope's trigger does.
    ///
    /// Hysteresis: the signal has to fall below the threshold before a rise
    /// back through it counts, otherwise a wave dithering around zero triggers
    /// many times per cycle. Noise never settles, which is correct — there is
    /// no phase to lock to.
    static func triggerOffset(_ samples: [Int16], window: Int = displayWindow) -> Int {
        let searchLimit = samples.count - window
        guard searchLimit > 1 else { return 0 }
        let threshold: Int16 = 400
        var armed = false
        for i in 0..<searchLimit {
            let value = samples[i]
            if value < -threshold { armed = true }
            else if armed, value >= threshold { return i }
        }
        return 0
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
                let window = min(data.count, displayWindow)
                let start = triggerOffset(data, window: window)

                ctx.setStrokeColor(foreground)
                ctx.setLineWidth(mode == .mix ? 1.5 : 1.2)
                ctx.beginPath()
                // One column of pixels per step through the window.
                let steps = max(2, Int(frame.width))
                for step in 0..<steps {
                    let index = start + window * step / steps
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

