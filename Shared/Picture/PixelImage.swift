import AppKit

/// A buffer of RGBA pixels turned into an image the views can draw.
///
/// `BitmapRenderer` and `PETSCIIRenderer` each build their own, but both mark
/// the result `isTemplate` — an alpha mask the view tints with a palette
/// colour, which is what makes every picture in this browser two colours. An
/// ILBM brings its own palette and cannot go through that, so this is the same
/// block without the template flag.
enum PixelImage {

    /// The same ceiling the bitmap renderer uses: past this the buffer is
    /// larger than anything worth showing, and allocating it is the problem
    /// rather than drawing it.
    static let pixelLimit = 64_000_000

    /// `rgba` is `width * height * 4` bytes, premultiplied, row major from the
    /// top left. Nearest neighbour, since these are pictures drawn a pixel at a
    /// time and smoothing them is a lie about how much detail is there.
    static func make(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width * height <= pixelLimit,
              rgba.count >= width * height * 4 else { return nil }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// The same wrapped for AppKit. A `CGImage` is what the thumbnail extension
    /// draws with and an `NSImage` is what a SwiftUI `Image` takes, so the
    /// picture is built once as the former and dressed as the latter here.
    static func image(_ cg: CGImage) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// An opaque PNG of an image built here, for the viewer's Save button.
    /// Unlike the bitmap viewer's, this needs no foreground and background:
    /// the colours are already in the pixels.
    static func pngData(_ cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
