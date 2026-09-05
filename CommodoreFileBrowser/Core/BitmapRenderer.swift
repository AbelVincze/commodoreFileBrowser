import Foundation
import CoreGraphics
import AppKit

/// How binary data is laid out as a 1 bit per pixel image.
///
/// Data is tiled as blocks of `blockWidth` x `blockHeight` pixels. Inside a
/// block the bytes run in raster order, each byte painting 8 horizontal pixels
/// with the most significant bit on the left. Blocks tile left to right across
/// the display width, then wrap down.
///
/// The shape falls out of the numbers: 8x8 blocks 320 wide is exactly a C64
/// hires screen, 24x21 is exactly a sprite.
struct BitmapLayout: Codable, Hashable {
    var blockWidth: Int = 8
    var blockHeight: Int = 8
    var displayWidth: Int = 320
    var magnification: Int = 2
    var invert: Bool = false

    /// Block width is rounded up to a whole number of bytes, and the display
    /// width down to a whole number of blocks, so the grid always divides.
    var normalized: BitmapLayout {
        var l = self
        l.blockWidth = max(8, ((blockWidth + 7) / 8) * 8)
        l.blockHeight = max(1, blockHeight)
        l.magnification = min(16, max(1, magnification))
        let blocks = max(1, displayWidth / l.blockWidth)
        l.displayWidth = blocks * l.blockWidth
        return l
    }

    var bytesPerBlockRow: Int { max(1, blockWidth / 8) }
    var bytesPerBlock: Int { bytesPerBlockRow * max(1, blockHeight) }
    var blocksPerRow: Int { max(1, displayWidth / max(8, blockWidth)) }

    /// Pixel position of the left-hand edge of a byte.
    func position(ofByte index: Int) -> (x: Int, y: Int) {
        let block = index / bytesPerBlock
        let within = index % bytesPerBlock
        return (x: (block % blocksPerRow) * blockWidth + (within % bytesPerBlockRow) * 8,
                y: (block / blocksPerRow) * blockHeight + (within / bytesPerBlockRow))
    }

    /// The byte drawn at a pixel, inverting `position(ofByte:)`. Returns nil
    /// outside the image.
    func byteIndex(atX x: Int, y: Int) -> Int? {
        guard x >= 0, y >= 0, x < displayWidth else { return nil }
        let blockX = x / blockWidth
        let blockY = y / blockHeight
        let byteCol = (x % blockWidth) / 8
        let byteRow = y % blockHeight
        return (blockY * blocksPerRow + blockX) * bytesPerBlock
            + byteRow * bytesPerBlockRow + byteCol
    }

    /// The block a byte belongs to, in pixels, for the hover highlight.
    func blockRect(forByte index: Int) -> CGRect {
        let block = index / bytesPerBlock
        return CGRect(x: (block % blocksPerRow) * blockWidth,
                      y: (block / blocksPerRow) * blockHeight,
                      width: blockWidth, height: blockHeight)
    }

    /// Rows needed to draw `count` bytes.
    func pixelHeight(forByteCount count: Int) -> Int {
        let blocks = (count + bytesPerBlock - 1) / bytesPerBlock
        let rows = (blocks + blocksPerRow - 1) / blocksPerRow
        return max(1, rows) * blockHeight
    }
}

enum BitmapPreset: String, CaseIterable, Identifiable {
    case hires, charset, sprites, linear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hires: return "Hires"
        case .charset: return "Charset"
        case .sprites: return "Sprites"
        case .linear: return "Linear"
        }
    }

    var detail: String {
        switch self {
        case .hires: return "8x8 cells, 320 wide — a C64 bitmap screen"
        case .charset: return "8x8 cells, 16 per row"
        case .sprites: return "24x21, 8 per row"
        case .linear: return "one byte row after another"
        }
    }

    func layout(basedOn current: BitmapLayout) -> BitmapLayout {
        var l = current
        switch self {
        case .hires:   l.blockWidth = 8;  l.blockHeight = 8;  l.displayWidth = 320
        case .charset: l.blockWidth = 8;  l.blockHeight = 8;  l.displayWidth = 128
        case .sprites: l.blockWidth = 24; l.blockHeight = 21; l.displayWidth = 192
        case .linear:  l.blockWidth = current.displayWidth; l.blockHeight = 1
        }
        return l.normalized
    }

    /// A sensible starting point for a file of this size.
    static func suggested(forByteCount count: Int) -> BitmapPreset {
        if (7000...9000).contains(count) { return .hires }        // a hires screen
        if count <= 4096, count % 8 == 0 { return .charset }      // a character set
        if count % 64 == 0, count <= 64 * 128 { return .sprites } // a sprite bank
        return .linear
    }
}

/// Rasterises bytes into a template image the view tints with the palette,
/// the same way `PETSCIIRenderer` does for character ROM glyphs.
final class BitmapRenderer {

    static let shared = BitmapRenderer()

    /// Above this the image gets unreasonable; the viewer says so in its footer.
    static let byteLimit = 1_048_576

    private struct Key: Hashable {
        let bytes: [UInt8]
        let layout: BitmapLayout
    }

    private var cache: [Key: NSImage] = [:]
    private let lock = NSLock()

    /// One image pixel per bit. Magnification is applied by the view's frame so
    /// the buffer stays small and the scaling stays nearest-neighbour.
    func image(bytes: [UInt8], layout raw: BitmapLayout) -> NSImage? {
        let layout = raw.normalized
        let data = Array(bytes.prefix(Self.byteLimit))
        guard !data.isEmpty else { return nil }

        let key = Key(bytes: data, layout: layout)
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }

        guard let made = render(data, layout) else { return nil }
        lock.lock()
        // Only a couple of these are ever live; they are large.
        if cache.count > 4 { cache.removeAll(keepingCapacity: true) }
        cache[key] = made
        lock.unlock()
        return made
    }

    private func render(_ data: [UInt8], _ layout: BitmapLayout) -> NSImage? {
        let w = layout.displayWidth
        let h = layout.pixelHeight(forByteCount: data.count)
        guard w > 0, h > 0, w * h <= 64_000_000 else { return nil }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let mask: UInt8 = layout.invert ? 0xFF : 0x00

        for (index, raw) in data.enumerated() {
            let byte = raw ^ mask
            guard byte != 0 else { continue }
            let p = layout.position(ofByte: index)
            guard p.y < h else { break }
            let rowBase = (p.y * w + p.x) * 4
            for bit in 0..<8 where (byte & (0x80 >> UInt8(bit))) != 0 {
                guard p.x + bit < w else { break }
                let o = rowBase + bit * 4
                pixels[o] = 255; pixels[o + 1] = 255; pixels[o + 2] = 255; pixels[o + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return nil }

        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: w, height: h)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// A standalone opaque PNG for export, drawn in the given colours rather
    /// than as a tintable template.
    func pngData(bytes: [UInt8], layout: BitmapLayout,
                 foreground: NSColor, background: NSColor) -> Data? {
        guard let template = image(bytes: bytes, layout: layout) else { return nil }
        let size = template.size
        let out = NSImage(size: size)
        out.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        foreground.set()
        template.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
