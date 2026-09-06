import Foundation

/// A DiskMasher archive: an Amiga floppy packed a track at a time. Unpacking
/// one gives back the disk image it was made from, which is then read like any
/// other ADF.
///
/// Every track carries a CRC of its packed bytes and a checksum of its
/// unpacked ones, so a decoder that goes wrong anywhere says so rather than
/// handing back plausible rubbish.
enum DMSArchive {

    /// A track of an Amiga floppy: two heads of eleven 512 byte sectors.
    static let trackBytes = 11 * 2 * 512
    /// Tracks numbered past the disk are the archive's own extras — the file
    /// description at 80 and a banner at $FFFF.
    static let diskTracks = 80

    enum Mode: UInt8 {
        case none = 0, simple = 1, quick = 2, medium = 3, deep = 4, heavy1 = 5, heavy2 = 6

        var name: String {
            switch self {
            case .none: return "stored"
            case .simple: return "RLE"
            case .quick: return "Quick"
            case .medium: return "Medium"
            case .deep: return "Deep"
            case .heavy1: return "Heavy 1"
            case .heavy2: return "Heavy 2"
            }
        }
    }

    struct Info {
        var lowTrack: Int
        var highTrack: Int
        var isEncrypted: Bool
        var modes: Set<Mode>

        var modeNames: String {
            modes.map(\.name).sorted().joined(separator: ", ")
        }
    }

    // MARK: - Checks

    /// CRC-16 with the reversed polynomial, over the packed bytes.
    private static let crcTable: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        return c
    }

    static func crc(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var c: UInt16 = 0
        for b in bytes { c = (c >> 8) ^ crcTable[Int((c ^ UInt16(b)) & 0xFF)] }
        return c
    }

    /// The check on an unpacked track is a plain sum of its bytes.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt16 = 0
        for b in bytes { sum = sum &+ UInt16(b) }
        return sum
    }

    // MARK: - Reading the archive

    private static func be16(_ b: [UInt8], _ o: Int) -> Int {
        o + 2 <= b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0
    }

    static func isArchive(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 56 && bytes[0] == 0x44 && bytes[1] == 0x4D && bytes[2] == 0x53 && bytes[3] == 0x21
    }

    /// What the archive says about itself, without unpacking it.
    static func info(_ bytes: [UInt8]) throws -> Info {
        guard isArchive(bytes) else { throw DiskImageError.unsupportedFormat }
        guard crc(bytes[4..<54]) == UInt16(be16(bytes, 54)) else {
            throw DiskImageError.corrupt("the archive header does not check out")
        }
        var modes: Set<Mode> = []
        var at = 56
        while at + 20 <= bytes.count, bytes[at] == 0x54, bytes[at + 1] == 0x52 {
            if let mode = Mode(rawValue: bytes[at + 13]) { modes.insert(mode) }
            at += 20 + be16(bytes, at + 6)
        }
        return Info(lowTrack: be16(bytes, 16), highTrack: be16(bytes, 18),
                    isEncrypted: be16(bytes, 10) & 2 != 0, modes: modes)
    }

    /// Unpack the whole archive into the disk image it was made from.
    static func unpack(_ bytes: [UInt8]) throws -> [UInt8] {
        let details = try info(bytes)
        guard !details.isEncrypted else {
            throw DiskImageError.corrupt("this archive is password protected")
        }

        let tracks = max(details.highTrack + 1, diskTracks)
        var image = [UInt8](repeating: 0, count: tracks * trackBytes)
        let decruncher = Decruncher()
        var at = 56
        var written = 0

        while at + 20 <= bytes.count {
            guard bytes[at] == 0x54, bytes[at + 1] == 0x52 else { break }     // "TR"
            let header = Array(bytes[at..<(at + 20)])
            guard crc(header[0..<18]) == UInt16(be16(header, 18)) else {
                throw DiskImageError.corrupt("a track header does not check out")
            }
            let number = be16(header, 2)
            let packedLength = be16(header, 6)
            let intermediate = be16(header, 8)
            let unpackedLength = be16(header, 10)
            let flags = header[12]
            guard let mode = Mode(rawValue: header[13]) else {
                throw DiskImageError.corrupt("track \(number) uses a compression this does not know")
            }
            let wantedSum = UInt16(be16(header, 14))
            let wantedCRC = UInt16(be16(header, 16))

            let start = at + 20
            guard start + packedLength <= bytes.count else {
                throw DiskImageError.corrupt("the archive ends in the middle of track \(number)")
            }
            let packed = Array(bytes[start..<(start + packedLength)])
            at = start + packedLength

            guard crc(packed[0...]) == wantedCRC else {
                throw DiskImageError.corrupt("track \(number) is damaged")
            }

            // The extras still have to be unpacked, because the decrunchers
            // carry their state from one track to the next and skipping one
            // would leave every track after it decoding from the wrong window.
            let track = try decruncher.unpack(packed, mode: mode, flags: flags,
                                              intermediate: intermediate,
                                              unpacked: unpackedLength, track: number)
            guard checksum(track) == wantedSum else {
                throw DiskImageError.corrupt("track \(number) did not come out as the archive says it should")
            }
            guard number < diskTracks else { continue }

            let offset = number * trackBytes
            let room = min(track.count, image.count - offset)
            if room > 0 { image.replaceSubrange(offset..<(offset + room), with: track.prefix(room)) }
            written += 1
        }

        guard written > 0 else { throw DiskImageError.corrupt("the archive holds no disk tracks") }
        return image
    }
}
