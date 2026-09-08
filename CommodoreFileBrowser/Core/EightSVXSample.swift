import Foundation

/// A sampled sound off an Amiga: eight bit, signed, one channel, at whatever
/// rate the machine happened to be clocking the DMA at when it was recorded.
struct SampledSound {
    var name: String?
    var annotation: String?
    /// Frames per second. 16726 is the commonest here, being what a Paula
    /// channel runs at on a PAL machine at period 124.
    var sampleRate: Double
    /// Widened to sixteen bits, which is what the rest of the audio here moves
    /// in — the sample itself has eight bits of resolution either way.
    var frames: [Int16]
    /// Where the sound repeats from, when it is a looping instrument rather
    /// than a one-shot effect. A third of them are.
    var loop: Range<Int>?
    /// How many octaves the file holds. Only the first is played.
    var octaves: Int

    var duration: Double { sampleRate > 0 ? Double(frames.count) / sampleRate : 0 }
}

enum EightSVXDecoder {

    enum Failure: LocalizedError {
        case notASample
        case noHeader
        case noBody
        case empty
        case unsupportedCompression(Int)

        var errorDescription: String? {
            switch self {
            case .notASample: return "Not an IFF 8SVX sample"
            case .noHeader: return "No VHDR chunk — the sample has no header"
            case .noBody: return "No BODY chunk — the sample has no sound in it"
            case .empty: return "The sample is empty"
            case .unsupportedCompression(let n):
                return n == 1 ? "Fibonacci-delta compressed, which this does not unpack"
                              : "Compression \(n) is not one this reads"
            }
        }
    }

    static func decode(_ bytes: [UInt8]) throws -> SampledSound {
        guard let form = IFF.form(bytes), form.type == "8SVX" else { throw Failure.notASample }
        guard let vhdr = IFF.chunk("VHDR", in: form.chunks) else { throw Failure.noHeader }
        guard let body = IFF.chunk("BODY", in: form.chunks) else { throw Failure.noBody }

        let o = vhdr.range.lowerBound
        let oneShot = Int(AmigaVolume.long(bytes, o))
        let repeatLength = Int(AmigaVolume.long(bytes, o + 4))
        let rate = o + 13 < bytes.count ? Int(bytes[o + 12]) << 8 | Int(bytes[o + 13]) : 0
        let octaves = o + 14 < bytes.count ? Int(bytes[o + 14]) : 1
        let compression = o + 15 < bytes.count ? Int(bytes[o + 15]) : 0

        guard compression == 0 else { throw Failure.unsupportedCompression(compression) }

        // A multi-octave file holds the octaves one after another, each twice
        // the length of the one before. The first is the one the header's two
        // lengths describe, and the only one worth playing here: the rest are
        // the same sound resampled for an instrument's keyboard range.
        let stated = oneShot + repeatLength
        let available = body.range.count
        let count = stated > 0 && stated <= available ? stated : available
        guard count > 0 else { throw Failure.empty }

        var frames = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            frames[i] = Int16(Int8(bitPattern: bytes[body.range.lowerBound + i])) << 8
        }

        return SampledSound(
            name: IFF.string(bytes, IFF.chunk("NAME", in: form.chunks)),
            annotation: IFF.string(bytes, IFF.chunk("ANNO", in: form.chunks))
                     ?? IFF.string(bytes, IFF.chunk("AUTH", in: form.chunks)),
            // Some writers leave the rate at zero. 8363 is the tracker default
            // and a better guess than silence at no rate at all.
            sampleRate: Double((1000...96000).contains(rate) ? rate : 8363),
            frames: frames,
            loop: repeatLength > 0 && oneShot + repeatLength <= count
                ? oneShot..<(oneShot + repeatLength) : nil,
            octaves: max(1, octaves))
    }
}
