import AppKit

/// A picture the browser can draw, whatever kind of file it came out of.
///
/// An Amiga ILBM and a C64 Koala have nothing in common as bytes — one is a
/// chunked container with its own palette, the other is a fixed dump of VIC-II
/// registers — but by the time either is decoded the difference is gone. What
/// is left is a pixel buffer, the shape a pixel of it was meant to be, and
/// enough words to say what was read. The viewer, the Quick Look preview and
/// the thumbnail extension all take this and nothing else.
struct DecodedPicture {
    var width: Int
    var height: Int
    /// How much taller than wide a pixel of this picture is. 1 for a square
    /// pixel, 2.2 for an Amiga hires one, 1.07 for a C64 PAL one.
    var heightScale: CGFloat
    /// What the file is: "IFF ILBM", "Koala Painter".
    var format: String
    /// The rest of what is worth saying, in " · " separated parts the viewer
    /// puts on lines of their own: "6 planes · EHB · 64 colours".
    var mode: String
    /// Kept as a `CGImage`: the viewer wraps it for SwiftUI, the thumbnail
    /// extension draws it into the context Quick Look hands over, and neither
    /// wants the other's wrapper.
    var image: CGImage

    /// How large to draw the picture inside `box`, aspect corrected.
    ///
    /// Shrinking is free, but growing goes in whole steps: a picture drawn a
    /// pixel at a time looks wrong at 1.37 times, where some rows are two
    /// screen pixels tall and their neighbours three. A 320x200 lores picture
    /// comes out at 2x or 3x rather than at whatever happened to fit.
    func displaySize(within box: CGSize) -> CGSize {
        Self.displaySize(width: width, height: height, heightScale: heightScale, within: box)
    }

    static func displaySize(width: Int, height: Int,
                            heightScale: CGFloat, within box: CGSize) -> CGSize {
        let wide = CGFloat(width)
        let tall = CGFloat(height) * heightScale
        guard wide > 0, tall > 0 else { return box }
        let fit = min(box.width / wide, box.height / tall)
        let scale = fit >= 1 ? floor(fit) : fit
        return CGSize(width: max(1, (wide * scale).rounded()),
                      height: max(1, (tall * scale).rounded()))
    }
}
