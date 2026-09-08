import Foundation

/// Conversions between PETSCII (as stored in CBM directory entries), C64 screen
/// codes (indices into the character ROM) and host-side ASCII.
enum PETSCII {

    /// Padding byte used by CBM DOS to fill unused filename bytes.
    static let shiftedSpace: UInt8 = 0xA0

    /// PETSCII byte -> screen code (character ROM glyph index).
    static func screenCode(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x00...0x1F: return c &+ 0x80
        case 0x20...0x3F: return c
        case 0x40...0x5F: return c &- 0x40
        case 0x60...0x7F: return c &- 0x20
        case 0x80...0x9F: return c &+ 0x40
        case 0xA0...0xBF: return c &- 0x40
        case 0xC0...0xDF: return c &- 0x80
        case 0xE0...0xFE: return c &- 0x80
        default: return 0x5E
        }
    }

    static func screenCodes(_ bytes: [UInt8]) -> [UInt8] { bytes.map(screenCode) }

    /// Screen codes for a plain ASCII string (used for the chrome we draw in
    /// PETSCII: block counts, file types, "blocks free" and so on — spelled in
    /// lower case, since those are the letters the drive itself prints).
    static func screenCodes(ascii: String) -> [UInt8] {
        petscii(fromASCII: ascii).map(screenCode)
    }

    /// ASCII -> PETSCII, keeping the case as a Commodore means it.
    ///
    /// Letters come in two forms. Unshifted, $41-$5A, are the ones a machine
    /// types by default: capitals in the upper case / graphics set, lower case
    /// in the other. Shifted, $C1-$DA, are graphics in the first set and
    /// capitals in the second.
    ///
    /// So lower case here is the ordinary letter — write "new disk" and it
    /// reads NEW DISK in the set the machine boots into, and "new disk" once
    /// the character set is switched. Upper case here asks for the shifted
    /// form, which is what makes "NewFile" come out as written in the lower
    /// case set, at the price of the N and the F being graphics in the other.
    static func petscii(fromASCII s: String) -> [UInt8] {
        s.unicodeScalars.map { u -> UInt8 in
            switch u {
            case "a"..."z": return UInt8(u.value - 0x20)   // unshifted, $41-$5A
            case "A"..."Z": return UInt8(u.value + 0x80)   // shifted, $C1-$DA
            default: return u.value < 0x80 ? UInt8(u.value) : 0x3F // '?'
            }
        }
    }

    /// PETSCII -> a readable ASCII rendering, for host file names and dialogs.
    ///
    /// The inverse of the above, so a name read out of a directory and written
    /// straight back is the same bytes: unshifted letters come back lower case,
    /// shifted ones upper case. That is why a name typed on a Commodore reads
    /// lower case here — those really are the unshifted letters, and spelling
    /// them back in capitals would store the graphics forms instead.
    static func ascii(_ bytes: [UInt8]) -> String {
        var out = ""
        for c in bytes {
            switch c {
            case 0x20...0x3F: out.append(Character(UnicodeScalar(c)))
            case 0x41...0x5A: out.append(Character(UnicodeScalar(c &+ 0x20)))
            case 0x61...0x7A: out.append(Character(UnicodeScalar(c &- 0x20)))
            case 0xC1...0xDA: out.append(Character(UnicodeScalar(c &- 0x80)))
            case 0x5B...0x5E: out.append(Character(UnicodeScalar(c)))
            default: out.append("_")
            }
        }
        return out
    }

    /// Characters CBM DOS treats specially inside a file name.
    private static let illegal: Set<UInt8> = [0x22, 0x2A, 0x3F, 0x2C, 0x3A, 0x3D, 0x24, 0xA0, 0x00]

    /// Build a legal 1-16 byte CBM file name from arbitrary text.
    static func cbmName(fromASCII s: String) -> [UInt8] {
        var bytes = petscii(fromASCII: s).map { illegal.contains($0) ? UInt8(0x2E) : $0 }
        if bytes.count > 16 { bytes = Array(bytes.prefix(16)) }
        if bytes.isEmpty { bytes = [0x2E] }
        return bytes
    }

    /// Strip the $A0 / $00 padding CBM DOS leaves behind a file name.
    static func trimPadding(_ bytes: [UInt8]) -> [UInt8] {
        var b = bytes
        while let last = b.last, last == 0xA0 || last == 0x00 { b.removeLast() }
        return b
    }

    /// Pad a name to 16 bytes with shifted spaces, the way CBM DOS stores it.
    static func padded16(_ bytes: [UInt8]) -> [UInt8] {
        var b = Array(bytes.prefix(16))
        while b.count < 16 { b.append(shiftedSpace) }
        return b
    }

    /// A file-system safe name for a CBM file, e.g. `my file` -> `my file.prg`.
    ///
    /// The extension is the only place a Commodore file type survives on the
    /// Mac, so it is added by default — but it is not part of the name the disk
    /// holds, and copying out is offered without it.
    static func hostFileName(_ bytes: [UInt8], type: CBMFileType,
                             addingExtension: Bool = true) -> String {
        var name = ascii(trimPadding(bytes))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "unnamed" }
        return addingExtension ? "\(name).\(type.fileExtension)" : name
    }
}
