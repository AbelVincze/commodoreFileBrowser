import AppKit

/// The VIC-II's sixteen colours.
///
/// The chip had no palette to read: the colours were fixed in silicon, and
/// every attempt to write them down as RGB is a measurement of a real machine
/// on a real television rather than a lookup table anyone shipped. These are
/// Colodore's, the set most emulators and most modern C64 art tools agree on.
enum VICII {
    static let colours: [(UInt8, UInt8, UInt8)] = [
        (0x00, 0x00, 0x00),  //  0 black
        (0xFF, 0xFF, 0xFF),  //  1 white
        (0x81, 0x33, 0x38),  //  2 red
        (0x75, 0xCE, 0xC8),  //  3 cyan
        (0x8E, 0x3C, 0x97),  //  4 purple
        (0x56, 0xAC, 0x4D),  //  5 green
        (0x2E, 0x2C, 0x9B),  //  6 blue
        (0xED, 0xF1, 0x71),  //  7 yellow
        (0x8E, 0x50, 0x29),  //  8 orange
        (0x55, 0x38, 0x00),  //  9 brown
        (0xC4, 0x6C, 0x71),  // 10 light red
        (0x4A, 0x4A, 0x4A),  // 11 dark grey
        (0x7B, 0x7B, 0x7B),  // 12 medium grey
        (0xA9, 0xFF, 0x9F),  // 13 light green
        (0x70, 0x6D, 0xEB),  // 14 light blue
        (0xB2, 0xB2, 0xB2),  // 15 light grey
    ]

    /// How much taller than wide a C64 pixel is on a PAL machine.
    ///
    /// Nothing in any of these files records it — the pixel ratio was a
    /// property of the television, not of the picture — so it is a constant
    /// here rather than something read. The 0.9365 is the PAL pixel's width
    /// against its height, the figure emulators use; NTSC's 0.75 is a
    /// different machine, and PAL is where nearly all C64 art was drawn.
    static let pixelHeightScale: CGFloat = 1 / 0.93650794
}

/// One C64 picture format: where in the file each of the VIC-II's four pieces
/// of a picture lives.
///
/// Almost every painter of the era saved the same thing — an 8000 byte bitmap,
/// a 1000 byte video matrix, sometimes 1000 bytes of colour RAM and a byte of
/// background colour — and differed only in what order it wrote them, what it
/// loaded them at, and how much padding it left between. So the formats are a
/// table rather than a decoder each.
struct C64PictureFormat {
    enum Kind {
        /// 320x200, one bit a pixel, two colours a cell.
        case hires
        /// 160x200 double width pixels, two bits a pixel, four colours a cell.
        case multicolour
        /// Multicolour with a fresh video matrix on every raster line, so
        /// eight of them and up to eight colours a cell.
        case fli
    }

    let name: String
    /// Only ever a hint. A picture pulled off a D64 is as likely to be called
    /// `PIC A` as `sunset.koa`, so nothing here is decided by the extension.
    let extensions: [String]
    /// The load address the two leading bytes must hold, or nil for a format
    /// saved without one.
    let load: Int?
    /// The whole file, load address included.
    let size: Int
    let kind: Kind
    /// Offsets into the file past the load address.
    let bitmap: Int
    let screen: Int
    /// nil for hires, which takes both its colours from the video matrix.
    let colour: Int?
    /// nil where the format does not store one, which means black.
    let background: Int?
    /// True for a format whose bytes are packed and have to be expanded before
    /// any of the offsets above mean anything.
    var packed = false

    var dataStart: Int { load == nil ? 0 : 2 }
}

enum C64Picture {

    /// The formats this reads, in the order they are tried.
    ///
    /// Every entry is pinned by an exact file size and, where it has one, an
    /// exact load address; no two entries share both. That is a narrow enough
    /// net that a program which is not a picture almost never falls into it,
    /// and it is the only honest test available — these files carry no magic
    /// number, no header and no name of their own.
    static let formats: [C64PictureFormat] = [
        // 8000 bitmap, 1000 screen, 1000 colour, 1 background. The format
        // everything else is a rearrangement of, and the one most C64 art in
        // circulation is still kept in.
        C64PictureFormat(name: "Koala Painter", extensions: ["koa", "kla", "gg"],
                         load: 0x6000, size: 10003, kind: .multicolour,
                         bitmap: 0, screen: 8000, colour: 9000, background: 10000),
        // Koala's layout at Interpaint's address.
        C64PictureFormat(name: "Interpaint", extensions: ["ipt", "ip64"],
                         load: 0x4000, size: 10003, kind: .multicolour,
                         bitmap: 0, screen: 8000, colour: 9000, background: 10000),
        C64PictureFormat(name: "Face Painter", extensions: ["fcp"],
                         load: 0x4000, size: 10004, kind: .multicolour,
                         bitmap: 0, screen: 8000, colour: 9000, background: 10000),
        C64PictureFormat(name: "Run Paint", extensions: ["rpm", "rp"],
                         load: 0x6000, size: 10006, kind: .multicolour,
                         bitmap: 0, screen: 8000, colour: 9000, background: 10000),
        // The odd one out: a single colour byte and fifteen unused ones sit
        // between the video matrix and colour RAM.
        C64PictureFormat(name: "Advanced Art Studio", extensions: ["ocp", "art"],
                         load: 0x2000, size: 10018, kind: .multicolour,
                         bitmap: 0, screen: 8000, colour: 9016, background: 9000),
        C64PictureFormat(name: "Art Studio", extensions: ["aas", "hpi"],
                         load: 0x2000, size: 9009, kind: .hires,
                         bitmap: 0, screen: 8000, colour: nil, background: nil),
        C64PictureFormat(name: "Hi-Eddi", extensions: ["hed"],
                         load: 0xA000, size: 9002, kind: .hires,
                         bitmap: 0, screen: 8000, colour: nil, background: nil),
        C64PictureFormat(name: "Interpaint", extensions: ["ip", "iph"],
                         load: 0x4000, size: 9002, kind: .hires,
                         bitmap: 0, screen: 8000, colour: nil, background: nil),
        // Paint Magic saves the picture inside the program that shows it: a
        // hundred and fourteen bytes of display code first, which is what puts
        // the bitmap on a $2000 boundary at $4000 and the video matrix at
        // $6000, with the tail end of the VIC's page — sprite pointers and all
        // — still on the end of the file. Worked out from a disk of them
        // rather than from a specification, there being none to find.
        C64PictureFormat(name: "Paint Magic", extensions: ["pmg"],
                         load: 0x3F8E, size: 9332, kind: .hires,
                         bitmap: 114, screen: 8306, colour: nil, background: nil),
        // Screen first, and both pieces padded up to whole pages.
        C64PictureFormat(name: "Doodle", extensions: ["dd", "ddl", "jj"],
                         load: 0x5C00, size: 9218, kind: .hires,
                         bitmap: 1024, screen: 0, colour: nil, background: nil),
        // Eight video matrices, one for each raster line of a character row.
        C64PictureFormat(name: "Blackmail FLI", extensions: ["bml", "fli"],
                         load: 0x3B00, size: 17474, kind: .fli,
                         bitmap: 0x2500, screen: 0x500, colour: 0x100, background: nil),
        // Saved straight out of memory with no load address in front. Rarer
        // than the named formats, but it is what a memory dump of a picture
        // looks like and there is nothing else it could be at these sizes.
        C64PictureFormat(name: "Raw bitmap", extensions: [],
                         load: nil, size: 9000, kind: .hires,
                         bitmap: 0, screen: 8000, colour: nil, background: nil),
        C64PictureFormat(name: "Raw bitmap", extensions: [],
                         load: nil, size: 10001, kind: .multicolour,
                         bitmap: 0, screen: 8000, colour: 9000, background: 10000),
    ]

    /// Amica Paint, which is Koala's layout run through a byte packer. Its
    /// size is whatever the picture compressed to, so it cannot be recognised
    /// from the table and gets unpacked on spec instead.
    private static let amicaLoad = 0x4000
    private static let amicaEscape: UInt8 = 0xC2
    private static let unpackedSize = 10001

    static let amica = C64PictureFormat(name: "Amica Paint", extensions: ["ami"],
                                        load: amicaLoad, size: 0, kind: .multicolour,
                                        bitmap: 0, screen: 8000, colour: 9000,
                                        background: 10000, packed: true)

    enum Failure: LocalizedError {
        case notAPicture
        case truncated(String)

        var errorDescription: String? {
            switch self {
            case .notAPicture: return "Not a picture this reads"
            case .truncated(let name): return "\(name) — the file stops before the picture does"
            }
        }
    }

    // MARK: - Recognising one

    /// The little endian word a PRG starts with.
    private static func loadAddress(_ b: [UInt8]) -> Int? {
        guard b.count >= 2 else { return nil }
        return Int(b[0]) | Int(b[1]) << 8
    }

    /// What this file is, or nil. `name` only breaks ties between formats that
    /// the bytes cannot tell apart, and there are currently none — it is
    /// carried so that adding such a pair later does not mean changing every
    /// caller.
    static func detect(name: String, bytes: [UInt8]) -> C64PictureFormat? {
        let load = loadAddress(bytes)
        let sized = formats.filter {
            $0.size == bytes.count && ($0.load == nil || $0.load == load)
        }
        if sized.count > 1 {
            let ext = (name as NSString).pathExtension.lowercased()
            if let match = sized.first(where: { $0.extensions.contains(ext) }) { return match }
        }
        if let first = sized.first { return first }

        // Nothing fixed fits. A packed picture is the remaining possibility,
        // and the only way to ask is to unpack it.
        if load == amicaLoad, unpackAmica(bytes) != nil { return amica }
        return nil
    }

    // MARK: - Decoding one

    static func decode(name: String, bytes: [UInt8]) throws -> DecodedPicture {
        guard let format = detect(name: name, bytes: bytes) else { throw Failure.notAPicture }
        return try decode(bytes, as: format)
    }

    static func decode(_ bytes: [UInt8], as format: C64PictureFormat) throws -> DecodedPicture {
        let data: [UInt8]
        if format.packed {
            guard let unpacked = unpackAmica(bytes) else { throw Failure.truncated(format.name) }
            data = unpacked
        } else {
            data = [UInt8](bytes.dropFirst(format.dataStart))
        }

        // The leftmost three character columns of an FLI picture are the FLI
        // bug: the raster time that goes into fetching a fresh video matrix
        // every line is taken out of the fetch for those columns, and the chip
        // draws them from whatever was left in it. They are an artefact of how
        // the picture is shown and not part of it, so they are cut.
        let skip = format.kind == .fli ? 24 : 0
        let width = 320 - skip
        let height = 200

        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        // A file cut short reads as zeroes past its end rather than as an
        // error, so half a picture comes out as half a picture with black
        // where the rest of it would have been. The sizes in the table are
        // exact, so this only ever happens to a packed file that stopped early.
        func at(_ offset: Int) -> UInt8 {
            guard offset >= 0, offset < data.count else { return 0 }
            return data[offset]
        }
        let background = Int(format.background.map { at($0) } ?? 0) & 15

        for y in 0..<height {
            let row = y >> 3, line = y & 7
            var out = y * width * 4
            for x in skip..<320 {
                let cell = row * 40 + (x >> 3)
                let bits = at(format.bitmap + cell * 8 + line)
                let index: Int
                switch format.kind {
                case .hires:
                    let screen = Int(at(format.screen + cell))
                    index = bits & (0x80 >> UInt8(x & 7)) != 0 ? screen >> 4 : screen & 15
                case .multicolour, .fli:
                    // An FLI picture holds eight video matrices, each a whole
                    // page apart, and the raster line inside the character row
                    // picks which one this pixel reads.
                    let matrix = format.kind == .fli ? format.screen + line * 1024 : format.screen
                    let screen = Int(at(matrix + cell))
                    let pair = (Int(bits) >> (6 - 2 * ((x & 7) >> 1))) & 3
                    switch pair {
                    case 0: index = background
                    case 1: index = screen >> 4
                    case 2: index = screen & 15
                    default: index = Int(at((format.colour ?? 0) + cell)) & 15
                    }
                }
                let c = VICII.colours[index & 15]
                rgba[out] = c.0; rgba[out + 1] = c.1; rgba[out + 2] = c.2; rgba[out + 3] = 255
                out += 4
            }
        }

        guard let image = PixelImage.make(rgba: rgba, width: width, height: height) else {
            throw Failure.truncated(format.name)
        }
        return DecodedPicture(width: width, height: height,
                              heightScale: VICII.pixelHeightScale,
                              format: format.name,
                              mode: modeText(format),
                              image: image)
    }

    private static func modeText(_ format: C64PictureFormat) -> String {
        var parts: [String] = []
        switch format.kind {
        case .hires: parts.append("hires · 2 colours a cell")
        case .multicolour: parts.append("multicolour · 4 colours a cell")
        case .fli: parts.append("FLI · 8 video matrices")
        }
        if let load = format.load { parts.append(String(format: "load $%04X", load)) }
        if format.packed { parts.append("packed") }
        if format.kind == .fli { parts.append("first 3 columns cut") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Amica Paint

    /// Amica Paint's packer: a run is the escape byte, a count, and the byte to
    /// repeat, and the escape byte followed by a zero count ends the file.
    /// Everything else is itself.
    ///
    /// Returns nil unless the whole of a picture came out and the end marker
    /// was really there, which is what makes this safe to try on any file that
    /// happens to load at $4000.
    static func unpackAmica(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count > 2 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(unpackedSize)
        var at = 2
        var ended = false
        while at < bytes.count {
            let byte = bytes[at]
            at += 1
            guard byte == amicaEscape else {
                out.append(byte)
                if out.count > unpackedSize * 2 { return nil }
                continue
            }
            guard at < bytes.count else { return nil }
            let count = Int(bytes[at])
            at += 1
            if count == 0 { ended = true; break }
            guard at < bytes.count else { return nil }
            let value = bytes[at]
            at += 1
            if out.count + count > unpackedSize * 2 { return nil }
            out.append(contentsOf: repeatElement(value, count: count))
        }
        guard ended, out.count >= unpackedSize else { return nil }
        return out
    }
}
