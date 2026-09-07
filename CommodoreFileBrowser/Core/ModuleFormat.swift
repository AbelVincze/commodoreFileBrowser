import Foundation

/// What a tracker module is, worked out from its bytes.
///
/// Amiga modules are not named the way Mac files are. The convention there is a
/// prefix — `mod.crockets`, `med.jazz` — and plenty of files carry nothing at
/// all: of the modules sitting inside the user's own ADF and DMS images, six are
/// called things like `KONMOD`, `LSMmiuzik` and `oliNBP`. So the name is a hint
/// at best and the content has to decide.
///
/// Every format below announces itself with a fixed signature, which is why
/// this is a table rather than a guess. The formats that do not — the
/// 15-sample Soundtracker, and the packed chiptune players such as Hippel and
/// Whittaker — cannot be recognised this way at all; the only honest test for
/// those is to hand the bytes to a player and see whether it validates them.
/// `Module.detect` therefore says "no" rather than guessing, and the player
/// asked to open a file anyway is what settles the remaining cases.
enum ModuleFormat: Equatable {

    // Signature at offset 1080, the four bytes after a 31-sample header.
    case protracker(String)
    // Signature at the front of the file.
    case fastTracker
    case screamTracker
    case impulseTracker
    case med(String)
    case digiBooster
    case oktalyzer
    case multiTracker
    // The Amiga chiptune players, whose "module" is the player plus its data.
    case futureComposer
    case digitalMugician
    case soundMon
    case soundFX
    case deltaMusic(Int)
    case hippelCOSO
    case sidMon2

    /// What to call it on screen.
    var name: String {
        switch self {
        case .protracker(let tag): return "ProTracker (\(tag))"
        case .fastTracker: return "FastTracker II"
        case .screamTracker: return "ScreamTracker 3"
        case .impulseTracker: return "Impulse Tracker"
        case .med(let tag): return "OctaMED (\(tag))"
        case .digiBooster: return "DigiBooster Pro"
        case .oktalyzer: return "Oktalyzer"
        case .multiTracker: return "MultiTracker"
        case .futureComposer: return "Future Composer"
        case .digitalMugician: return "Digital Mugician"
        case .soundMon: return "BP SoundMon"
        case .soundFX: return "SoundFX"
        case .deltaMusic(let v): return "Delta Music \(v)"
        case .hippelCOSO: return "Jochen Hippel (COSO)"
        case .sidMon2: return "SidMon II"
        }
    }
}

/// A module ready to hand to a player: what it is, what it is called, and the
/// bytes as they were read.
struct Module {
    var format: ModuleFormat
    /// The name the module carries inside it, where the format has one. Empty
    /// when the format keeps no title, and never the file name — that is the
    /// caller's to fall back on.
    var title: String
    var data: [UInt8]
}

enum ModuleLoader {

    /// The four-character marks that sit at offset 1080 of a 31-sample module.
    /// Anything not in this table and not matching `channelTag` is not one.
    private static let trailingMagic: [String: String] = [
        "M.K.": "4 channels", "M!K!": "4 channels, long", "M&K!": "His Master's",
        "N.T.": "NoiseTracker", "FLT4": "Startrekker 4", "FLT8": "Startrekker 8",
        "EXO4": "Exolon 4", "EXO8": "Exolon 8", "CD81": "Falcon 8",
        "OCTA": "Oktalyzer", "OKTA": "Oktalyzer",
        "FA04": "Digital Tracker", "FA06": "Digital Tracker", "FA08": "Digital Tracker",
    ]

    /// `6CHN`, `16CH`, `32CN`, `TDZ3` — the marks that spell out a channel
    /// count instead of naming a tracker.
    private static func channelTag(_ tag: String) -> String? {
        let c = Array(tag.utf8)
        guard c.count == 4 else { return nil }
        func digit(_ b: UInt8) -> Int? { (0x30...0x39).contains(b) ? Int(b - 0x30) : nil }

        // `4CHN` … `9CHN`
        if let n = digit(c[0]), n > 0, c[1] == UInt8(ascii: "C"), c[2] == UInt8(ascii: "H"),
           c[3] == UInt8(ascii: "N") { return "\(n) channels" }
        // `10CH` … `32CH`, and the `CN` spelling some trackers use.
        if let hi = digit(c[0]), let lo = digit(c[1]), c[2] == UInt8(ascii: "C"),
           c[3] == UInt8(ascii: "H") || c[3] == UInt8(ascii: "N") {
            let n = hi * 10 + lo
            return n > 0 ? "\(n) channels" : nil
        }
        // `TDZ1` … `TDZ3`, TakeTracker's odd channel counts.
        if tag.hasPrefix("TDZ"), let n = digit(c[3]), (1...3).contains(n) { return "\(n) channels" }
        return nil
    }

    private static func text(_ b: [UInt8], _ at: Int, _ count: Int) -> String {
        guard at >= 0, at + count <= b.count else { return "" }
        return String(decoding: b[at..<(at + count)], as: UTF8.self)
    }

    /// A title stored as fixed-width bytes, cut at the first zero and trimmed.
    private static func title(_ b: [UInt8], _ at: Int, _ count: Int) -> String {
        guard at + count <= b.count else { return "" }
        let raw = Array(b[at..<(at + count)]).prefix { $0 != 0 }
        return String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What this file is, or nil if its bytes do not say.
    static func detect(_ b: [UInt8]) -> Module? {
        guard let format = format(b) else { return nil }
        return Module(format: format, title: title(b, for: format), data: b)
    }

    private static func format(_ b: [UInt8]) -> ModuleFormat? {
        // The PC trackers and the Amiga editors that put their mark up front.
        // Checked before the 31-sample table because a long module can carry
        // four bytes at 1080 that mean nothing.
        if text(b, 0, 17) == "Extended Module: " { return .fastTracker }
        if b.count > 48, text(b, 44, 4) == "SCRM" { return .screamTracker }
        if b.count > 4 {
            switch text(b, 0, 4) {
            case "MMD0", "MMD1", "MMD2", "MMD3": return .med(text(b, 0, 4))
            case "IMPM": return .impulseTracker
            case "DBM0": return .digiBooster
            case "SMOD", "FC14": return .futureComposer
            case "ALL ": return .deltaMusic(1)
            case ".FNL": return .deltaMusic(2)
            case "COSO": return .hippelCOSO
            default: break
            }
        }
        if text(b, 0, 8) == "OKTASONG" { return .oktalyzer }
        if text(b, 0, 3) == "MTM" { return .multiTracker }
        if text(b, 0, 9) == " MUGICIAN" { return .digitalMugician }
        if b.count > 30, ["BPS", "V.2", "V.3"].contains(text(b, 26, 3)) { return .soundMon }
        if b.count > 86, text(b, 58, 28) == "SIDMON II - THE MIDI VERSION" { return .sidMon2 }
        if b.count > 128, text(b, 60, 4) == "SONG" || ["SONG", "SO31"].contains(text(b, 124, 4)) {
            return .soundFX
        }

        // The 31-sample Amiga module: a 1084 byte header, then the mark.
        if b.count > 1084 {
            let tag = text(b, 1080, 4)
            guard let voices = channels(tag), thirtyOneSampleHeader(b, channels: voices) else {
                return nil
            }
            if let known = trailingMagic[tag] { return .protracker(known) }
            if let counted = channelTag(tag) { return .protracker(counted) }
        }
        return nil
    }

    /// How many voices the mark stands for, which sets how big a pattern is.
    private static func channels(_ tag: String) -> Int? {
        switch tag {
        case "M.K.", "M!K!", "M&K!", "N.T.", "FLT4", "EXO4", "FA04": return 4
        case "FLT8", "EXO8", "CD81", "OCTA", "OKTA", "FA08": return 8
        case "FA06": return 6
        default: break
        }
        let c = Array(tag.utf8)
        guard c.count == 4 else { return nil }
        func digit(_ b: UInt8) -> Int? { (0x30...0x39).contains(b) ? Int(b - 0x30) : nil }
        if let n = digit(c[0]), n > 0, tag.hasSuffix("CHN") { return n }
        if let hi = digit(c[0]), let lo = digit(c[1]), c[2] == UInt8(ascii: "C"),
           c[3] == UInt8(ascii: "H") || c[3] == UInt8(ascii: "N"), hi * 10 + lo > 0 {
            return hi * 10 + lo
        }
        if tag.hasPrefix("TDZ"), let n = digit(c[3]), (1...3).contains(n) { return n }
        return nil
    }

    /// Whether the 1080 bytes before the mark read as 31 sample headers and an
    /// order table, rather than as something that merely happens to have four
    /// familiar characters in the right place.
    ///
    /// This is not paranoia. The ProTracker playroutine source carries a line
    /// reading `EQU 1080 ;"M.K." :)` — a comment naming the offset of the mark,
    /// which in that file lands at offset 1080. Without this check the app
    /// offers to play 68000 assembly.
    ///
    /// The test that settles it is arithmetic rather than taste: a module says
    /// how long each of its 31 samples is and which patterns it plays, and a
    /// header, its patterns and its samples account for the file exactly. Every
    /// one of the 98 modules in the user's collection balances to the byte;
    /// the assembly source claims 1.2 MB of samples inside 25 KB of file.
    private static func thirtyOneSampleHeader(_ b: [UInt8], channels: Int) -> Bool {
        // Song length, then the order the patterns play in.
        guard b[950] >= 1, b[950] <= 128 else { return false }
        var highest = 0
        for i in 0..<128 {
            let pattern = Int(b[952 + i])
            if pattern > 127 { return false }
            highest = max(highest, pattern)
        }
        // 20 bytes of title, then 31 headers of 30: name(22), length in words
        // (2), finetune(1), volume(1), repeat(2), repeat length(2).
        var sampleBytes = 0
        for i in 0..<31 {
            let at = 20 + i * 30
            sampleBytes += (Int(b[at + 22]) << 8 | Int(b[at + 23])) * 2
        }
        // 64 rows of `channels` notes, four bytes each.
        let patterns = (highest + 1) * 64 * channels * 4
        guard b.count >= 1084 + patterns else { return false }

        // Sample data runs to the end. Rippers do trim it, so a file shorter
        // than it claims is allowed some room; one claiming far more than it
        // could hold is not a module.
        let room = b.count - 1084 - patterns
        return sampleBytes <= room * 2 + 4096
    }

    private static func title(_ b: [UInt8], for format: ModuleFormat) -> String {
        switch format {
        case .protracker: return title(b, 0, 20)
        case .fastTracker: return title(b, 17, 20)
        case .screamTracker, .impulseTracker: return title(b, 4, 28)
        case .multiTracker: return title(b, 4, 20)
        case .digiBooster: return title(b, 16, 44)
        // MED keeps its title in the song block rather than the header, and the
        // chiptune players keep none at all. The file name is the better answer
        // for those, and the caller has it.
        default: return ""
        }
    }
}
