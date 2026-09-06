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

    /// Samples drawn in one frame. The window is half the captured buffer so
    /// there is room to slide it either side of the trigger point.
    static let displayWindow = 1024

    /// Index of a rising crossing of zero, the point every frame is lined up
    /// on so the trace stands still rather than sliding. This is what an
    /// oscilloscope's trigger does.
    ///
    /// The search leaves half a window of samples on either side, since the
    /// crossing is drawn in the middle of the cell and the wave before it has
    /// to come from somewhere.
    ///
    /// Hysteresis: the signal has to fall below the threshold before a rise
    /// back through it counts, otherwise a wave dithering around zero triggers
    /// many times per cycle. A crossing that falls short of the search window
    /// still re-arms the trigger, so the one that is returned is always a rise
    /// through the threshold and never the top of a plateau. Noise never
    /// settles, which is correct — there is no phase to lock to.
    static func triggerIndex(_ samples: [Int16], window: Int = displayWindow) -> Int? {
        let lead = window / 2
        let searchLimit = samples.count - (window - lead)
        guard searchLimit > lead else { return nil }
        let threshold: Int16 = 400
        var armed = false
        for i in 0..<searchLimit {
            let value = samples[i]
            if value < -threshold { armed = true }
            else if armed, value >= threshold {
                if i >= lead { return i }
                armed = false
            }
        }
        return nil
    }

    /// First sample of the window to draw: the trigger crossing placed at the
    /// centre of the cell, which reads better than pinning it to the left edge.
    /// Untriggered, the middle of the buffer is drawn.
    static func windowStart(_ samples: [Int16], window: Int = displayWindow) -> Int {
        guard let index = triggerIndex(samples, window: window) else {
            return max(0, (samples.count - window) / 2)
        }
        return index - window / 2
    }

    static func draw(in ctx: CGContext, size: CGSize, mode: ScopeMode, sidCount: Int,
                     samples: [Int: [Int16]], foreground: CGColor, background: CGColor,
                     grid gridColor: CGColor) {
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: size))

        // Everything below is drawn against a 540 tall reference and scaled up
        // from there: a 1.2 point trace on a 4K canvas is a hairline, and the
        // gaps between cells vanish. Anything smaller than the reference — the
        // live view — is left alone.
        let scale = max(1, size.height / 540)
        let (rows, columns) = grid(mode: mode, sidCount: sidCount)
        let gap = 3 * scale
        let cellW = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let frame = CGRect(x: CGFloat(column) * (cellW + gap),
                                   y: CGFloat(row) * (cellH + gap),
                                   width: cellW, height: cellH)
                // Zero line.
                ctx.setStrokeColor(gridColor)
                ctx.setLineWidth(scale)
                ctx.beginPath()
                ctx.move(to: CGPoint(x: frame.minX, y: frame.midY))
                ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                ctx.strokePath()

                guard let data = samples[track(mode: mode, row: row, column: column)],
                      data.count > 1 else { continue }
                let window = min(data.count, displayWindow)
                let start = windowStart(data, window: window)

                ctx.setStrokeColor(foreground)
                ctx.setLineWidth((mode == .mix ? 1.5 : 1.2) * scale)
                ctx.beginPath()
                // A column of pixels per step, but never more steps than there
                // are samples to draw: past that the trace is a staircase of
                // repeated values rather than a finer curve.
                let steps = max(2, min(Int(frame.width), window))
                for step in 0..<steps {
                    let index = start + window * step / steps
                    let value = CGFloat(data[min(index, data.count - 1)]) / 32768.0
                    let point = CGPoint(x: frame.minX + frame.width * CGFloat(step) / CGFloat(steps),
                                        y: frame.midY - value * (frame.height / 2 - 2 * scale))
                    if step == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
                }
                ctx.strokePath()
            }
        }
    }
}

