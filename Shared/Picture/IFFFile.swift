import Foundation

/// The IFF container the Amiga wrapped nearly everything in: a `FORM` header, a
/// four character type saying what kind of form it is, and then chunks that are
/// each an id, a big endian length, and that many bytes.
///
/// Nothing here knows what a picture or a sample is. Walking the chunks and
/// deciding what the file claims to be are different questions, and only the
/// outermost form is ever asked the second one.
enum IFF {

    /// One chunk: its id, and where its contents are — the eight byte header
    /// is not part of the range.
    struct Chunk {
        let id: String
        let range: Range<Int>
    }

    /// The chunks laid out inside `range`, which starts past a form's type.
    ///
    /// Two details catch every hand written IFF reader. A chunk with an odd
    /// length is followed by a pad byte that the length does not count; and a
    /// chunk that claims to run past the end has to be handled rather than
    /// trusted, since these come off forty year old floppies and being cut
    /// short is common.
    ///
    /// Cut short, the last chunk is kept and clamped to the bytes that are
    /// really there. Half a sample is half a sample, and dropping it would
    /// leave the file looking as though it held none at all — which is what
    /// this did at first, and what a 26 KB sample claiming 64 KB showed up as.
    /// The walk still stops there: past a bad length there is no telling where
    /// the next header begins.
    static func chunks(in bytes: [UInt8], range: Range<Int>) -> [Chunk] {
        var out: [Chunk] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            let id = text(bytes, at, 4)
            let size = Int(long(bytes, at + 4))
            let start = at + 8
            guard size >= 0 else { break }
            if start + size > range.upperBound {
                if start < range.upperBound { out.append(Chunk(id: id, range: start..<range.upperBound)) }
                break
            }
            out.append(Chunk(id: id, range: start..<(start + size)))
            at = start + size + (size & 1)
        }
        return out
    }

    /// The chunks of the form starting at `at`, and the form's own type.
    static func form(_ bytes: [UInt8], at: Int = 0) -> (type: String, chunks: [Chunk])? {
        guard at + 12 <= bytes.count, text(bytes, at, 4) == "FORM" else { return nil }
        let size = Int(long(bytes, at + 4))
        // The stated size is a claim, not a fact. A file cut short mid-picture
        // still has a readable header and a partial body, and showing what
        // there is beats refusing the lot.
        let end = min(bytes.count, at + 8 + max(4, size))
        return (text(bytes, at + 8, 4), chunks(in: bytes, range: (at + 12)..<end))
    }

    /// The first chunk with this id, or nil.
    static func chunk(_ id: String, in chunks: [Chunk]) -> Chunk? {
        chunks.first { $0.id == id }
    }

    /// A big endian long, which is what an IFF `ckSize` is.
    ///
    /// Its own rather than the Disk layer's `AmigaVolume.long`, which is the
    /// same four lines: reaching for that one would put the whole of `Disk/`
    /// behind this file, and the Quick Look extensions want the picture reader
    /// without eleven files of disk formats behind it. Every layer here reads
    /// its own bytes anyway — `HDFImage` has a local `long`, `SIDTune` a local
    /// `be`, `T64Image` a little endian one.
    static func long(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func text(_ b: [UInt8], _ at: Int, _ count: Int) -> String {
        guard at >= 0, at + count <= b.count else { return "" }
        return String(decoding: b[at..<(at + count)], as: UTF8.self)
    }

    /// A chunk's contents read as text, cut at the first zero. NAME, ANNO and
    /// AUTH are all stored this way.
    static func string(_ b: [UInt8], _ chunk: Chunk?) -> String? {
        guard let chunk, chunk.range.upperBound <= b.count else { return nil }
        let raw = b[chunk.range].prefix { $0 != 0 }
        let s = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// What an IFF file holds, as far as this browser is concerned.
enum IFFForm {
    /// A picture.
    case ilbm
    /// An animation. Only its first frame is shown, which is a whole ILBM.
    case anim(frames: Int)
    /// A sampled sound.
    case eightSVX

    var name: String {
        switch self {
        case .ilbm: return "IFF ILBM"
        case .anim: return "IFF ANIM"
        case .eightSVX: return "IFF 8SVX"
        }
    }

    /// True where the viewer can draw it.
    var isPicture: Bool {
        switch self {
        case .ilbm, .anim: return true
        case .eightSVX: return false
        }
    }
}

enum IFFLoader {

    /// What this file is, or nil if its bytes do not say. Content only — an
    /// Amiga file is as likely to be called `pic.1` as anything else, and a
    /// `.iff` extension is no promise of which form is inside.
    static func detect(_ b: [UInt8]) -> IFFForm? {
        guard let form = IFF.form(b) else { return nil }
        switch form.type {
        case "ILBM":
            // A palette on its own is a FORM ILBM holding a CMAP and nothing
            // else — how DPaint saved its `.col` files, and a fifth of the
            // ILBMs on a Workbench disk. Real, but not a picture, and claiming
            // it would open the viewer on a file with no pixels in it.
            guard let body = IFF.chunk("BODY", in: form.chunks), !body.range.isEmpty else { return nil }
            return .ilbm
        case "8SVX":
            // The same rule as a picture with no pixels: a header describing a
            // sound that is not in the file is not a sound.
            guard let body = IFF.chunk("BODY", in: form.chunks), !body.range.isEmpty else { return nil }
            return .eightSVX
        case "ANIM":
            // An ANIM is a form of forms: the first is a complete ILBM and
            // every one after it a delta against the frame before. Counting
            // them is worth the walk so the viewer can say how much of the
            // file it is not showing.
            let frames = form.chunks.filter { $0.id == "FORM" }.count
            guard frames > 0, let first = pictureForm(b),
                  IFF.chunk("BODY", in: first.chunks) != nil else { return nil }
            return .anim(frames: frames)
        default: return nil
        }
    }

    /// The bytes of the picture inside, which for an ANIM is its first frame.
    /// Returns the range of the whole `FORM ILBM`, ready for `IFF.form`.
    static func pictureForm(_ b: [UInt8]) -> (type: String, chunks: [IFF.Chunk])? {
        guard let form = IFF.form(b) else { return nil }
        if form.type == "ILBM" { return form }
        guard form.type == "ANIM" else { return nil }
        // The nested forms are chunks in their own right, so their contents
        // begin eight bytes before the type an inner FORM starts with.
        for chunk in form.chunks where chunk.id == "FORM" {
            if let inner = IFF.form(b, at: chunk.range.lowerBound - 8), inner.type == "ILBM" {
                return inner
            }
        }
        return nil
    }
}
