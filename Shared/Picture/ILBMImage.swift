import AppKit

/// An Amiga picture: `BMHD` for the shape, `CMAP` for the colours, `CAMG` for
/// the screen mode the machine would have shown it in, and `BODY` for the bits.
///
/// The bits are the part that dates it. An Amiga held a picture as one bitplane
/// per bit of colour depth — every plane a full width by height page of its own
/// — and a pixel's colour index is a bit taken from the same place in each one.
/// Six planes give 64 indices, and then two of the three OCS tricks reinterpret
/// them: Extra Half-Brite makes the upper 32 a halved copy of the lower 32, and
/// hold-and-modify makes most pixels a change to one channel of the pixel to
/// its left. Both exist to get more colours out of a palette than the palette
/// has room for, and neither can be decoded without knowing which is meant,
/// which is what CAMG is for.
struct ILBMImage {
    var width: Int
    var height: Int
    /// How much taller than wide a pixel of this picture is, from the aspect
    /// the file records. 1 for a square pixel, 2.2 for a hires one.
    var heightScale: CGFloat
    /// For the viewer's subtitle: "6 planes · EHB · 64 colours".
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

enum ILBMDecoder {

    /// Refused rather than guessed at, and said out loud: a picture that comes
    /// out wrong looks like a bug in the viewer, and a picture that says why it
    /// cannot be shown does not.
    enum Failure: LocalizedError {
        case notAPicture
        case noHeader
        case noBody
        case unsupportedCompression(Int)
        case unreasonable(Int, Int, Int)

        var errorDescription: String? {
            switch self {
            case .notAPicture: return "Not an IFF picture"
            case .noHeader: return "No BMHD chunk — the picture has no header"
            case .noBody: return "No BODY chunk — the picture has no pixels"
            case .unsupportedCompression(let n): return "Compression \(n) is not one this reads"
            case .unreasonable(let w, let h, let planes):
                return "\(w)×\(h) in \(planes) planes is not a picture this can draw"
            }
        }
    }

    private struct Header {
        var width = 0, height = 0
        var planes = 0, masking = 0, compression = 0
        var transparent = 0
        var xAspect = 0, yAspect = 0
    }

    private static let hamFlag: UInt32 = 0x0800
    private static let ehbFlag: UInt32 = 0x0080

    // MARK: - Entry point

    /// Decodes the picture in `bytes`, which may be an ILBM or an ANIM whose
    /// first frame is one.
    static func decode(_ bytes: [UInt8]) throws -> ILBMImage {
        guard let form = IFFLoader.pictureForm(bytes) else { throw Failure.notAPicture }
        guard let bmhd = IFF.chunk("BMHD", in: form.chunks) else { throw Failure.noHeader }
        guard let body = IFF.chunk("BODY", in: form.chunks) else { throw Failure.noBody }

        var head = header(bytes, bmhd)
        // A DPaint stencil is saved as a picture with no colour planes at all
        // and a mask plane where they would be. The mask is the shape, so read
        // it as the single plane it already is rather than refusing the file
        // for having none.
        if head.planes == 0, head.masking == 1 { head.planes = 1; head.masking = 0 }
        guard head.width > 0, head.height > 0, head.width <= 8192, head.height <= 8192,
              (1...8).contains(head.planes),
              head.width * head.height <= PixelImage.pixelLimit
        else { throw Failure.unreasonable(head.width, head.height, head.planes) }
        guard head.compression == 0 || head.compression == 1 else {
            throw Failure.unsupportedCompression(head.compression)
        }

        var palette = colours(bytes, IFF.chunk("CMAP", in: form.chunks), planes: head.planes)
        let camg = IFF.chunk("CAMG", in: form.chunks)
            .map { IFF.long(bytes, $0.range.lowerBound) } ?? 0

        // An Extra Half-Brite file with no CAMG in it is common enough to be
        // worth recognising by shape: six planes needs 64 entries, and a
        // palette that stops at 32 is saying the other half is the halved one.
        let isHAM = camg & hamFlag != 0 && (head.planes == 6 || head.planes == 8)
        let isEHB = !isHAM && head.planes == 6
            && (camg & ehbFlag != 0 || palette.count == 32)
        if isEHB { palette = halfBrite(palette) }

        let planes = try bitplanes(bytes, body: body, head: head)
        let rgba = isHAM ? hamPixels(planes, head: head, palette: palette)
                         : indexedPixels(planes, head: head, palette: palette)

        guard let image = PixelImage.make(rgba: rgba, width: head.width, height: head.height) else {
            throw Failure.unreasonable(head.width, head.height, head.planes)
        }
        return ILBMImage(width: head.width, height: head.height,
                         heightScale: aspect(head),
                         mode: modeText(head, isHAM: isHAM, isEHB: isEHB, colours: palette.count),
                         image: image)
    }

    // MARK: - The header chunks

    private static func header(_ b: [UInt8], _ chunk: IFF.Chunk) -> Header {
        let o = chunk.range.lowerBound
        func word(_ i: Int) -> Int {
            guard o + i + 2 <= b.count else { return 0 }
            return Int(b[o + i]) << 8 | Int(b[o + i + 1])
        }
        func byte(_ i: Int) -> Int { o + i < b.count ? Int(b[o + i]) : 0 }
        var h = Header()
        h.width = word(0);      h.height = word(2)
        h.planes = byte(8);     h.masking = byte(9)
        h.compression = byte(10)
        h.transparent = word(12)
        h.xAspect = byte(14);   h.yAspect = byte(15)
        return h
    }

    /// The palette, three bytes an entry.
    ///
    /// An OCS machine had four bits a gun, and the writers of the day stored
    /// them in the high nibble with the low one left at zero. Taken at face
    /// value every colour comes out at half brightness, so a palette that is
    /// entirely high nibbles gets each one copied down — `$F0` is white, not
    /// mid grey. Only below eight planes: an AGA picture has a real 8 bit
    /// palette and a dark one is meant to be dark.
    private static func colours(_ b: [UInt8], _ chunk: IFF.Chunk?, planes: Int) -> [(UInt8, UInt8, UInt8)] {
        guard let chunk else {
            // No CMAP at all. One plane is a stencil, so black and white; more
            // than that has nothing to say and greys are better than nothing.
            let n = 1 << planes
            return (0..<n).map { i in
                let v = UInt8(n == 1 ? 0 : i * 255 / (n - 1))
                return (v, v, v)
            }
        }
        var out: [(UInt8, UInt8, UInt8)] = []
        var at = chunk.range.lowerBound
        while at + 3 <= chunk.range.upperBound {
            out.append((b[at], b[at + 1], b[at + 2]))
            at += 3
        }
        let allHighNibbles = out.allSatisfy { $0.0 & 0x0F == 0 && $0.1 & 0x0F == 0 && $0.2 & 0x0F == 0 }
        let anyColour = out.contains { $0.0 != 0 || $0.1 != 0 || $0.2 != 0 }
        if planes < 8, allHighNibbles, anyColour {
            out = out.map { ($0.0 | $0.0 >> 4, $0.1 | $0.1 >> 4, $0.2 | $0.2 >> 4) }
        }
        return out
    }

    /// Extra Half-Brite: the palette again, every gun halved.
    private static func halfBrite(_ palette: [(UInt8, UInt8, UInt8)]) -> [(UInt8, UInt8, UInt8)] {
        let base = Array(palette.prefix(32))
        return base + base.map { ($0.0 >> 1, $0.1 >> 1, $0.2 >> 1) }
    }

    // MARK: - The body

    /// The BODY unpacked into one flat buffer: row by row, and within a row
    /// one plane after another, each `rowBytes` long. A mask plane is stored
    /// among them and is kept, since dropping it would mean two strides to
    /// reason about instead of one.
    private static func bitplanes(_ b: [UInt8], body: IFF.Chunk, head: Header) throws -> [UInt8] {
        let rowBytes = ((head.width + 15) / 16) * 2
        let perRow = head.planes + (head.masking == 1 ? 1 : 0)
        let wanted = rowBytes * perRow * head.height

        if head.compression == 0 {
            var out = [UInt8](repeating: 0, count: wanted)
            let have = min(wanted, body.range.count)
            if have > 0 {
                out.replaceSubrange(0..<have, with: b[body.range.lowerBound..<(body.range.lowerBound + have)])
            }
            return out
        }

        // ByteRun1: a signed count byte. 0...127 means take the next n+1 bytes
        // as they are, -1...-127 means repeat the next byte 1-n times, and -128
        // is a no-op nobody emits but everybody has to skip.
        var out = [UInt8](repeating: 0, count: wanted)
        var at = body.range.lowerBound
        var put = 0
        while at < body.range.upperBound, put < wanted {
            let control = Int(Int8(bitPattern: b[at]))
            at += 1
            if control >= 0 {
                let count = min(control + 1, wanted - put)
                guard at + count <= body.range.upperBound else { break }
                out.replaceSubrange(put..<(put + count), with: b[at..<(at + count)])
                at += control + 1
                put += count
            } else if control != -128 {
                guard at < body.range.upperBound else { break }
                let count = min(1 - control, wanted - put)
                let value = b[at]
                at += 1
                for i in 0..<count { out[put + i] = value }
                put += count
            }
        }
        return out
    }

    // MARK: - Planes to pixels

    /// The colour index of every pixel in a row, gathered a bit at a time out
    /// of each plane in turn.
    private static func indices(_ planes: [UInt8], row: Int, head: Header,
                                rowBytes: Int, perRow: Int, into out: inout [Int]) {
        for i in 0..<head.width { out[i] = 0 }
        let rowBase = row * perRow * rowBytes
        for plane in 0..<head.planes {
            let base = rowBase + plane * rowBytes
            guard base + rowBytes <= planes.count else { return }
            let bit = 1 << plane
            for x in 0..<head.width {
                if planes[base + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0 { out[x] |= bit }
            }
        }
    }

    private static func indexedPixels(_ planes: [UInt8], head: Header,
                                      palette: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        let rowBytes = ((head.width + 15) / 16) * 2
        let perRow = head.planes + (head.masking == 1 ? 1 : 0)
        var rgba = [UInt8](repeating: 255, count: head.width * head.height * 4)
        var row = [Int](repeating: 0, count: head.width)

        for y in 0..<head.height {
            indices(planes, row: y, head: head, rowBytes: rowBytes, perRow: perRow, into: &row)
            var o = y * head.width * 4
            for x in 0..<head.width {
                let c = palette.isEmpty ? (UInt8(0), UInt8(0), UInt8(0))
                                        : palette[min(row[x], palette.count - 1)]
                rgba[o] = c.0; rgba[o + 1] = c.1; rgba[o + 2] = c.2; rgba[o + 3] = 255
                o += 4
            }
        }
        return rgba
    }

    /// Hold-and-modify. The top two bits say what to do with the rest: 00 is an
    /// ordinary palette index, and the other three hold the pixel to the left
    /// and replace one channel of it. A row starts from the border colour
    /// rather than from whatever the row above ended on, which is what keeps a
    /// mistake on one line from smearing down the whole picture.
    private static func hamPixels(_ planes: [UInt8], head: Header,
                                  palette: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        let rowBytes = ((head.width + 15) / 16) * 2
        let perRow = head.planes + (head.masking == 1 ? 1 : 0)
        let dataBits = head.planes - 2
        let dataMask = (1 << dataBits) - 1
        var rgba = [UInt8](repeating: 255, count: head.width * head.height * 4)
        var row = [Int](repeating: 0, count: head.width)
        let border = palette.first ?? (0, 0, 0)

        // HAM6 carries four bits a channel and HAM8 six, both widened to eight
        // by repeating the top bits rather than by shifting in zeros, so full
        // scale stays full scale.
        func widen(_ v: Int) -> UInt8 {
            dataBits == 4 ? UInt8((v << 4) | v) : UInt8((v << 2) | (v >> 4))
        }

        for y in 0..<head.height {
            indices(planes, row: y, head: head, rowBytes: rowBytes, perRow: perRow, into: &row)
            var r = border.0, g = border.1, b = border.2
            var o = y * head.width * 4
            for x in 0..<head.width {
                let value = row[x]
                let data = value & dataMask
                switch value >> dataBits {
                case 0:
                    let c = palette.isEmpty ? (UInt8(0), UInt8(0), UInt8(0))
                                            : palette[min(data, palette.count - 1)]
                    r = c.0; g = c.1; b = c.2
                case 1: b = widen(data)
                case 2: r = widen(data)
                default: g = widen(data)
                }
                rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = 255
                o += 4
            }
        }
        return rgba
    }

    // MARK: - Describing it

    /// How much taller than wide a pixel is. A lores picture says 10:11 and a
    /// hires one 5:11, so a 640 wide screen and a 320 wide one end up the same
    /// shape on screen, which is the point of recording it at all.
    private static func aspect(_ head: Header) -> CGFloat {
        guard head.xAspect > 0, head.yAspect > 0 else { return 1 }
        let ratio = CGFloat(head.yAspect) / CGFloat(head.xAspect)
        return min(max(ratio, 0.25), 4)
    }

    private static func modeText(_ head: Header, isHAM: Bool, isEHB: Bool, colours: Int) -> String {
        var parts = ["\(head.planes) plane\(head.planes == 1 ? "" : "s")"]
        if isHAM { parts.append(head.planes == 8 ? "HAM8" : "HAM6") }
        if isEHB { parts.append("EHB") }
        parts.append(isHAM ? "\(head.planes == 8 ? "262,144" : "4,096") colours"
                           : "\(min(colours, 1 << head.planes)) colours")
        if head.compression == 1 { parts.append("packed") }
        return parts.joined(separator: " · ")
    }
}
