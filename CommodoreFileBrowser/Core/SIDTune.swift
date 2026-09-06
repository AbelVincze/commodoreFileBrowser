import Foundation

/// A tune ready to hand to the emulator: the bytes, where they live in the C64
/// address space, and the two routines to call.
struct SIDTune {
    enum Source: String {
        case psid = "PSID header"
        case naming = "file name"
        case musicAssembler = "Music Assembler player"
        case raw = "raw binary"
    }

    var source: Source
    var title: String
    var author: String?
    var released: String?

    var loadAddress: Int
    var initAddress: Int
    /// Zero means the tune installs its own IRQ and the play address is taken
    /// from the interrupt vector after init.
    var playAddress: Int
    /// Body to copy into memory at `loadAddress`, load address bytes removed.
    var payload: [UInt8]

    var songCount: Int
    var defaultSong: Int
    /// Value written to A, X and Y before init — how a subtune is chosen.
    var selector: UInt8 = 0
    var sidModel: Int?
    var extraSIDAddresses: [Int] = []

    var hasMultipleSongs: Bool { songCount > 1 }
}

enum SIDTuneLoader {

    // MARK: - PSID / RSID

    static func isPSID(_ data: [UInt8]) -> Bool {
        data.count >= 0x76 && (Array(data[0..<4]) == Array("PSID".utf8)
                               || Array(data[0..<4]) == Array("RSID".utf8))
    }

    static func psid(_ data: [UInt8]) -> SIDTune? {
        guard isPSID(data) else { return nil }
        func be(_ i: Int) -> Int { Int(data[i]) << 8 | Int(data[i + 1]) }
        func text(_ at: Int) -> String? {
            guard at + 32 <= data.count else { return nil }
            let raw = Array(data[at..<(at + 32)]).prefix { $0 != 0 }
            let s = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? nil : s
        }

        let version = be(4)
        let offset = be(6)
        guard offset + 2 <= data.count else { return nil }

        // Per the PSID spec: a zero load address in the header means the real
        // one is the first two bytes of the data. csid-light always skips those
        // two bytes, which is wrong for the non-zero case; almost every file in
        // the wild carries zero, so it never shows up there.
        let headerLoad = be(8)
        let load: Int
        let bodyStart: Int
        if headerLoad != 0 {
            load = headerLoad
            bodyStart = offset
        } else {
            load = Int(data[offset]) | Int(data[offset + 1]) << 8
            bodyStart = offset + 2
        }
        guard bodyStart <= data.count else { return nil }

        let initAddress = be(0x0A) != 0 ? be(0x0A) : load
        let songs = max(1, be(0x0E))
        let start = max(1, be(0x10))

        var model: Int?
        var extra: [Int] = []
        if version >= 2, data.count > 0x7B {
            model = (data[0x77] & 0x30) >= 0x20 ? 8580 : 6581
            for byte in [data[0x7A], data[0x7B]] where byte >= 0x42 && (byte < 0x80 || byte >= 0xE0) {
                extra.append(0xD000 + Int(byte) * 16)
            }
        }

        return SIDTune(source: .psid,
                       title: text(0x16) ?? "Untitled",
                       author: text(0x36),
                       released: text(0x56),
                       loadAddress: load,
                       initAddress: initAddress,
                       playAddress: be(0x0C),
                       payload: Array(data[bodyStart...]),
                       songCount: songs,
                       defaultSong: start,
                       selector: UInt8((start - 1) & 0xFF),
                       sidModel: model,
                       extraSIDAddresses: extra)
    }

    // MARK: - The file name convention

    /// `Z10 I1000 P1003` — a name, the init address, the play address. Matched
    /// without regard to case: a disk carries these upper case, but the same
    /// name on the Mac may be written `z900 if000 pf003`. A `!`
    /// takes the place of the `I` (or trails the name) when the tune holds more
    /// than one song. Real disks also carry run-together spellings such as
    /// `Z101 !E006PPE000`, so both halves are matched loosely, and the play
    /// address is only looked for after the init address to stop a `P` in the
    /// name itself from being mistaken for it.
    private static let initPattern = try! NSRegularExpression(
        pattern: "[I!]([0-9A-F]{4})", options: .caseInsensitive)
    private static let playPattern = try! NSRegularExpression(
        pattern: "P+([0-9A-F]{4})", options: .caseInsensitive)

    static func addressesFromName(_ name: String) -> (init_: Int, play: Int, multi: Bool)? {
        let full = NSRange(name.startIndex..., in: name)
        guard let initMatch = initPattern.firstMatch(in: name, range: full),
              let initRange = Range(initMatch.range(at: 1), in: name),
              let initValue = Int(name[initRange], radix: 16)
        else { return nil }

        let after = NSRange(location: initMatch.range.upperBound,
                            length: full.length - initMatch.range.upperBound)
        guard after.length > 0,
              let playMatch = playPattern.firstMatch(in: name, range: after),
              let playRange = Range(playMatch.range(at: 1), in: name),
              let playValue = Int(name[playRange], radix: 16)
        else { return nil }

        return (initValue, playValue, name.contains("!"))
    }

    static func named(_ name: String, prg: [UInt8]) -> SIDTune? {
        guard let found = addressesFromName(name), prg.count > 2 else { return nil }
        return SIDTune(source: .naming,
                       title: name.trimmingCharacters(in: .whitespaces),
                       author: nil,
                       released: nil,
                       loadAddress: Int(prg[0]) | Int(prg[1]) << 8,
                       initAddress: found.init_,
                       playAddress: found.play,
                       payload: Array(prg[2...]),
                       // The name only says "more than one"; how many is up to
                       // the tune, so offer a generous range to step through.
                       songCount: found.multi ? 32 : 1,
                       defaultSong: 1)
    }

    // MARK: - The Music Assembler player

    /// Music Assembler saves a tune with its player in front of it, laid out
    /// the same way every time: init sits $48 past the load address, and the
    /// interrupt handler that drives the music $18 past it. Nothing in the file
    /// says so — the names are free-form and there is no header — so the
    /// player's own code is what identifies it.
    ///
    /// Two places are read, and across the 255 Music Assembler tunes on the
    /// user's disks they never disagree: either both match or neither does.
    static func musicAssembler(_ name: String, prg: [UInt8]) -> SIDTune? {
        guard prg.count > 2 + 0x52 else { return nil }
        let body = Array(prg[2...])
        let high = prg[1]

        // Init: `LDA #$1F / STA $D418 / LDA #$F0 / STA $D417`, the volume and
        // the filter. A few tunes carry a hand patch turning a store into `BIT`
        // to leave what is already there alone, so either opcode is allowed.
        func stores(_ byte: UInt8) -> Bool { byte == 0x8D || byte == 0x2C }
        guard body[0x48] == 0xA9, body[0x49] == 0x1F, stores(body[0x4A]),
              body[0x4B] == 0x18, body[0x4C] == 0xD4,
              body[0x4D] == 0xA9, body[0x4E] == 0xF0, stores(body[0x4F]),
              body[0x50] == 0x17, body[0x51] == 0xD4
        else { return nil }

        // The head of the play routine: `LDX #$00 / DEC $xx90`. The address it
        // touches belongs to the player itself, so matching it against the load
        // address also confirms the code was relocated to where the file says
        // it goes — a tune moved to a new address without being relocated would
        // still carry the init bytes above, and would not play.
        guard body[0x21] == 0xA2, body[0x22] == 0x00, body[0x23] == 0xCE, body[0x25] == high
        else { return nil }

        // Play is $18 on: `INC $D019 / JSR $xx21 / JMP $EA31`, the handler the
        // standalone player hangs off the interrupt vector. Rippers write a
        // banner over the first $21 bytes often enough that a fifth of these
        // files have none of it left, and then the routine that handler calls,
        // $21 on, is the one to call instead. It is the same music either way.
        let handler = body[0x18] == 0xEE && body[0x19] == 0x19 && body[0x1A] == 0xD0
                   && body[0x1B] == 0x20 && body[0x1C] == 0x21 && body[0x1D] == high
        let load = Int(prg[0]) | Int(high) << 8

        return SIDTune(source: .musicAssembler,
                       title: name.trimmingCharacters(in: .whitespaces),
                       author: nil,
                       released: nil,
                       loadAddress: load,
                       initAddress: load + 0x48,
                       playAddress: load + (handler ? 0x18 : 0x21),
                       payload: body,
                       songCount: 1,
                       defaultSong: 1)
    }

    // MARK: - Raw

    /// A PRG: the first two bytes are the load address.
    static func raw(_ prg: [UInt8], name: String, initAddress: Int, playAddress: Int) -> SIDTune? {
        guard prg.count > 2 else { return nil }
        return SIDTune(source: .raw,
                       title: name,
                       author: nil,
                       released: nil,
                       loadAddress: Int(prg[0]) | Int(prg[1]) << 8,
                       initAddress: initAddress,
                       playAddress: playAddress,
                       payload: Array(prg[2...]),
                       songCount: 1,
                       defaultSong: 1)
    }

    /// PSID first, then the name convention, then the players recognised by
    /// their own code. Nil means the addresses have to be entered by hand.
    ///
    /// A name that spells out the addresses is taken at its word before the
    /// code is looked at: it is what the person who saved the file meant, and
    /// on these disks it is a jump table in front of the player rather than the
    /// player's own entry points.
    static func detect(name: String, data: [UInt8]) -> SIDTune? {
        psid(data) ?? named(name, prg: data) ?? musicAssembler(name, prg: data)
    }
}
