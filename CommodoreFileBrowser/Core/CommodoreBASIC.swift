import Foundation

/// Turns a tokenised Commodore BASIC program back into a listing.
///
/// A program is a linked list of lines. Each one holds a two byte pointer to
/// the next (zero ends the program), a two byte line number, then the tokenised
/// text terminated by a null. Bytes from $80 up are keywords; everything else
/// is PETSCII, and inside quotes nothing is a keyword at all.
enum CommodoreBASIC {

    /// BASIC V2 keywords, $80 through $CB. The PET, VIC-20 and C64 share these.
    /// Spelled in lower case because that is what the unshifted letters a drive
    /// prints are: a listing reads PRINT in the set the machine boots into.
    /// BASIC 4.0 and 7.0 add more above $CB; those pass through as raw PETSCII.
    static let tokens: [String] = [
        "end", "for", "next", "data", "input#", "input", "dim", "read", "let", "goto",
        "run", "if", "restore", "gosub", "return", "rem", "stop", "on", "wait", "load",
        "save", "verify", "def", "poke", "print#", "print", "cont", "list", "clr", "cmd",
        "sys", "open", "close", "get", "new", "tab(", "to", "fn", "spc(", "then",
        "not", "step", "+", "-", "*", "/", "^", "and", "or", ">",
        "=", "<", "sgn", "int", "abs", "usr", "fre", "pos", "sqr", "rnd",
        "log", "exp", "cos", "sin", "tan", "atn", "peek", "len", "str$", "val",
        "asc", "chr$", "left$", "right$", "mid$", "go",
    ]

    struct Line: Identifiable {
        let id: Int
        let number: Int
        /// The line body in PETSCII, keywords already spelled out.
        let text: [UInt8]

        /// Number, a space, then the body — the way the drive prints it.
        var petscii: [UInt8] {
            PETSCII.petscii(fromASCII: "\(number) ") + text
        }
    }

    /// `skipLoadAddress` consumes the two byte PRG header before the program.
    static func listing(_ data: [UInt8], skipLoadAddress: Bool = true) -> [Line] {
        var i = skipLoadAddress ? 2 : 0
        var out: [Line] = []

        while i + 4 <= data.count {
            let link = Int(data[i]) | (Int(data[i + 1]) << 8)
            if link == 0 { break }                       // end of program
            let number = Int(data[i + 2]) | (Int(data[i + 3]) << 8)
            i += 4

            var text: [UInt8] = []
            var inQuotes = false
            while i < data.count, data[i] != 0 {
                let byte = data[i]
                i += 1
                if byte == 0x22 {                        // a quote flips the mode
                    inQuotes.toggle()
                    text.append(byte)
                } else if !inQuotes, byte >= 0x80, byte <= 0xCB {
                    text.append(contentsOf: PETSCII.petscii(fromASCII: tokens[Int(byte) - 0x80]))
                } else {
                    // PETSCII, or a token from a BASIC we do not know. Inside
                    // quotes this is also how control codes stay visible.
                    text.append(byte)
                }
            }
            if i < data.count { i += 1 }                 // the terminating null

            out.append(Line(id: out.count, number: number, text: text))
            if out.count > 20_000 { break }              // runaway guard
        }
        return out
    }
}
