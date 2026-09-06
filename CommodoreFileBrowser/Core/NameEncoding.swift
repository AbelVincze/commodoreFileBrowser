import Foundation

/// How a directory entry's raw name bytes read as text.
///
/// The Commodore formats store PETSCII, where the case in the bytes and the
/// case on screen are two different things — `PETSCII` explains the care that
/// takes. The Amiga formats store ISO Latin-1, which is ordinary text: a byte
/// is the Unicode scalar of the same value, and nothing has to be decided.
enum NameEncoding: Hashable {
    case petscii
    case latin1

    func text(_ bytes: [UInt8]) -> String {
        switch self {
        case .petscii: return PETSCII.ascii(bytes)
        case .latin1:
            // Control codes are not legal in an AmigaDOS name, so a byte below
            // a space means a damaged directory rather than a character worth
            // rendering. Showing it as _ keeps a corrupt name from putting a
            // newline or a tab through the listing.
            return String(bytes.map { $0 < 0x20 ? "_" : Character(UnicodeScalar($0)) })
        }
    }

    func bytes(_ text: String) -> [UInt8] {
        switch self {
        case .petscii: return PETSCII.petscii(fromASCII: text)
        case .latin1:
            return text.unicodeScalars.map { $0.value < 0x100 && $0.value >= 0x20 ? UInt8($0.value) : 0x3F }
        }
    }
}

/// How a panel draws the inside of a container: from the character ROM, the way
/// the machine itself listed a disk, or as ordinary text in the system font.
enum ListingStyle {
    case petscii
    case text
}
