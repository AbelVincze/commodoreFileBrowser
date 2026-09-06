import Foundation

/// The DiskMasher decompressors.
///
/// One of these lives for the length of an archive: the sliding window, the
/// Huffman trees and the last distance used all carry from one track to the
/// next, unless a track says otherwise.
///
/// Written against the format as xDMS documents it (public domain, by Andre
/// Rodrigues de la Rocha, after the LZH decoders in UNIX LHA by Masaru Oki).
final class Decruncher {

    // MARK: - State carried between tracks

    /// One window, shared by every mode, each using as much of it as it needs.
    private var text = [UInt8](repeating: 0, count: 0x4000)
    private var quickLocation = 0
    private var mediumLocation = 0
    private var deepLocation = 0
    private var heavyLocation = 0
    /// The distance a Heavy track last copied from. One of the distance codes
    /// means "the same as before", so this has to outlive the match that set it.
    private var heavyLastDistance = 0
    private var codeTree = HuffmanTree()
    private var pointerTree = HuffmanTree()
    private var deepTablesNeedInit = true

    init() { reset() }

    /// Back to the state a fresh archive starts in. The window positions do not
    /// start at zero: each mode begins part way into it.
    private func reset() {
        for i in text.indices { text[i] = 0 }
        quickLocation = 251
        mediumLocation = 0x3FBE
        deepLocation = 0x3FC4
        heavyLocation = 0
        heavyLastDistance = 0
        deepTablesNeedInit = true
    }

    // MARK: - Bit reader
    //
    // Bits come out most significant first. `buffer` holds `count` live bits in
    // its low end, topped up a byte at a time so sixteen are always available.

    private var input: [UInt8] = []
    private var position = 0
    private var buffer: UInt32 = 0
    private var count = 0

    private func startBits(_ data: [UInt8]) {
        input = data
        position = 0
        buffer = 0
        count = 0
        drop(0)
    }

    private func peek(_ n: Int) -> Int {
        n <= 0 ? 0 : Int((buffer >> UInt32(count - n)) & ((1 << UInt32(n)) - 1))
    }

    private func drop(_ n: Int) {
        guard n >= 0 else { return }
        count -= n
        if count < 0 { count = 0 }
        buffer &= (1 << UInt32(count)) - 1
        while count < 16 {
            buffer = (buffer << 8) | UInt32(position < input.count ? input[position] : 0)
            position += 1
            count += 8
        }
    }

    private func take(_ n: Int) -> Int {
        let value = peek(n)
        drop(n)
        return value
    }

    // MARK: - Huffman
    //
    // The codes are canonical: shortest first, and in symbol order within a
    // length. Sixteen bits are enough to hold any of them, so a symbol is found
    // by reading that many and asking which length it falls in.

    private struct HuffmanTree {
        /// A code length is stored in five bits, so it can name more bits than
        /// a code would usually need — and some archives really do go past
        /// sixteen.
        static let maximumLength = 31

        /// Set when the whole tree is one symbol and no bits are read for it.
        var constant: Int?
        var counts = [Int](repeating: 0, count: maximumLength + 1)
        var firstCode = [Int](repeating: 0, count: maximumLength + 1)
        var firstIndex = [Int](repeating: 0, count: maximumLength + 1)
        var symbols: [Int] = []

        init() { constant = 0 }

        init(lengths: [UInt8]) throws {
            constant = nil
            for length in lengths {
                guard length <= Self.maximumLength else {
                    throw DiskImageError.corrupt("a Huffman code claims to be \(length) bits long")
                }
                if length > 0 { counts[Int(length)] += 1 }
            }
            var code = 0, index = 0
            for length in 1...Self.maximumLength {
                firstCode[length] = code
                firstIndex[length] = index
                code = (code + counts[length]) << 1
                index += counts[length]
            }
            symbols.reserveCapacity(index)
            for length in 1...Self.maximumLength {
                for (symbol, l) in lengths.enumerated() where Int(l) == length { symbols.append(symbol) }
            }
        }

        init(constant value: Int) { self.constant = value }
    }

    /// Canonical decoding: take a bit at a time and ask, at each length,
    /// whether the code so far is one of the codes of that length.
    private func decode(_ tree: HuffmanTree) throws -> Int {
        if let constant = tree.constant { return constant }
        var code = 0
        for length in 1...HuffmanTree.maximumLength {
            code = (code << 1) | take(1)
            let offset = code - tree.firstCode[length]
            if tree.counts[length] > 0, offset >= 0, offset < tree.counts[length] {
                return tree.symbols[tree.firstIndex[length] + offset]
            }
        }
        throw DiskImageError.corrupt("a Huffman code is not in its tree")
    }

    // MARK: - Heavy

    private func readHeavyTrees(distanceCodes: Int) throws {
        var n = take(9)
        if n > 0 {
            guard n <= 510 else { throw DiskImageError.corrupt("too many Huffman codes") }
            var lengths = [UInt8](repeating: 0, count: 510)
            for i in 0..<n { lengths[i] = UInt8(take(5)) }
            codeTree = try HuffmanTree(lengths: lengths)
        } else {
            n = take(9)
            codeTree = HuffmanTree(constant: n)
        }

        n = take(5)
        if n > 0 {
            guard n <= 20 else { throw DiskImageError.corrupt("too many distance codes") }
            var lengths = [UInt8](repeating: 0, count: max(n, distanceCodes))
            for i in 0..<n { lengths[i] = UInt8(take(4)) }
            pointerTree = try HuffmanTree(lengths: lengths)
        } else {
            n = take(5)
            pointerTree = HuffmanTree(constant: n)
        }
    }

    /// The distance to copy from. One code — the last one — means "the same
    /// distance as the match before", which is why it is remembered.
    private func decodeDistance(distanceCodes: Int) throws -> Int {
        let symbol = try decode(pointerTree)
        if symbol != distanceCodes - 1 {
            heavyLastDistance = symbol > 0 ? (1 << (symbol - 1)) | take(symbol - 1) : 0
        }
        return heavyLastDistance
    }

    private func unpackHeavy(_ data: [UInt8], flags: UInt8, size: Int) throws -> [UInt8] {
        // Heavy 1 slides over 4K with fourteen distance codes, Heavy 2 over 8K
        // with fifteen.
        let wide = flags & 8 != 0
        let distanceCodes = wide ? 15 : 14
        let mask = wide ? 0x1FFF : 0x0FFF

        startBits(data)
        // The trees are rewritten only when the packer says they changed; the
        // rest of the time a track goes on using the ones before it.
        if flags & 2 != 0 { try readHeavyTrees(distanceCodes: distanceCodes) }

        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            let symbol = try decode(codeTree)
            if symbol < 256 {
                let c = UInt8(symbol)
                text[heavyLocation & mask] = c
                heavyLocation = (heavyLocation + 1) & 0xFFFF
                out.append(c)
            } else {
                var length = symbol - 253
                var from = (heavyLocation - (try decodeDistance(distanceCodes: distanceCodes)) - 1) & 0xFFFF
                while length > 0 {
                    let c = text[from & mask]
                    text[heavyLocation & mask] = c
                    heavyLocation = (heavyLocation + 1) & 0xFFFF
                    from = (from + 1) & 0xFFFF
                    out.append(c)
                    length -= 1
                    if out.count >= size { break }
                }
            }
        }
        return out
    }

    // MARK: - Quick

    private func unpackQuick(_ data: [UInt8], _ size: Int) throws -> [UInt8] {
        startBits(data)
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            if take(1) != 0 {
                let c = UInt8(take(8))
                text[quickLocation & 0xFF] = c
                quickLocation = (quickLocation + 1) & 0xFFFF
                out.append(c)
            } else {
                var length = take(2) + 2
                var from = (quickLocation - take(8) - 1) & 0xFFFF
                while length > 0 {
                    let c = text[from & 0xFF]
                    text[quickLocation & 0xFF] = c
                    quickLocation = (quickLocation + 1) & 0xFFFF
                    from = (from + 1) & 0xFFFF
                    out.append(c)
                    length -= 1
                    if out.count >= size { break }
                }
            }
        }
        quickLocation = (quickLocation + 5) & 0xFF
        return out
    }

    // MARK: - Medium

    private func unpackMedium(_ data: [UInt8], _ size: Int) throws -> [UInt8] {
        startBits(data)
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            if take(1) != 0 {
                let c = UInt8(take(8))
                text[mediumLocation & 0x3FFF] = c
                mediumLocation = (mediumLocation + 1) & 0xFFFF
                out.append(c)
            } else {
                // The distance is spread over three reads through a pair of
                // tables that say how many bits each part takes.
                var c = take(8)
                var length = Int(Self.distanceCode[c]) + 3
                var bits = Int(Self.distanceLength[c])
                c = ((c << bits) | take(bits)) & 0xFF
                bits = Int(Self.distanceLength[c])
                let distance = (Int(Self.distanceCode[c]) << 8) | (((c << bits) | take(bits)) & 0xFF)
                var from = (mediumLocation - distance - 1) & 0xFFFF
                while length > 0 {
                    let byte = text[from & 0x3FFF]
                    text[mediumLocation & 0x3FFF] = byte
                    mediumLocation = (mediumLocation + 1) & 0xFFFF
                    from = (from + 1) & 0xFFFF
                    out.append(byte)
                    length -= 1
                    if out.count >= size { break }
                }
            }
        }
        mediumLocation = (mediumLocation + 66) & 0x3FFF
        return out
    }

    // MARK: - Deep
    //
    // An adaptive Huffman tree that reshapes itself as it goes: every symbol
    // decoded makes itself cheaper for next time.

    private static let lookahead = 60
    private static let threshold = 2
    private static let characters = 256 - threshold + lookahead
    private static let treeSize = characters * 2 - 1
    private static let rootNode = treeSize - 1
    private static let maximumFrequency = 0x8000

    private var frequency = [Int](repeating: 0, count: treeSize + 1)
    private var parent = [Int](repeating: 0, count: treeSize + characters)
    private var child = [Int](repeating: 0, count: treeSize)

    private func initialiseDeepTables() {
        for i in 0..<Self.characters {
            frequency[i] = 1
            child[i] = i + Self.treeSize
            parent[i + Self.treeSize] = i
        }
        var i = 0, j = Self.characters
        while j <= Self.rootNode {
            frequency[j] = frequency[i] + frequency[i + 1]
            child[j] = i
            parent[i] = j
            parent[i + 1] = j
            i += 2; j += 1
        }
        frequency[Self.treeSize] = 0xFFFF
        parent[Self.rootNode] = 0
        deepTablesNeedInit = false
    }

    /// Rebuild the tree with every frequency halved, so that counting can go on
    /// without the numbers running away.
    private func rebuildDeepTree() {
        var j = 0
        for i in 0..<Self.treeSize where child[i] >= Self.treeSize {
            frequency[j] = (frequency[i] + 1) / 2
            child[j] = child[i]
            j += 1
        }
        var i = 0
        j = Self.characters
        while j < Self.treeSize {
            let f = frequency[i] + frequency[i + 1]
            frequency[j] = f
            var k = j - 1
            while f < frequency[k] { k -= 1 }
            k += 1
            var m = j
            while m > k { frequency[m] = frequency[m - 1]; child[m] = child[m - 1]; m -= 1 }
            frequency[k] = f
            child[k] = i
            i += 2; j += 1
        }
        for i in 0..<Self.treeSize {
            let k = child[i]
            if k >= Self.treeSize { parent[k] = i }
            else { parent[k] = i; parent[k + 1] = i }
        }
    }

    private func updateDeepTree(_ symbol: Int) {
        if frequency[Self.rootNode] == Self.maximumFrequency { rebuildDeepTree() }
        var c = parent[symbol + Self.treeSize]
        repeat {
            frequency[c] += 1
            let k = frequency[c]
            // Keep the table in frequency order, swapping this node up past any
            // it has overtaken.
            var l = c + 1
            if k > frequency[l] {
                while k > frequency[l + 1] { l += 1 }
                frequency[c] = frequency[l]
                frequency[l] = k

                let i = child[c]
                parent[i] = l
                if i < Self.treeSize { parent[i + 1] = l }
                let j = child[l]
                child[l] = i
                parent[j] = c
                if j < Self.treeSize { parent[j + 1] = c }
                child[c] = j
                c = l
            }
            c = parent[c]
        } while c != 0
    }

    private func decodeDeepCharacter() -> Int {
        var c = child[Self.rootNode]
        while c < Self.treeSize { c = child[c + take(1)] }
        c -= Self.treeSize
        updateDeepTree(c)
        return c
    }

    private func decodeDeepPosition() -> Int {
        var i = take(8)
        let high = Int(Self.distanceCode[i]) << 8
        let bits = Int(Self.distanceLength[i])
        i = ((i << bits) | take(bits)) & 0xFF
        return high | i
    }

    private func unpackDeep(_ data: [UInt8], _ size: Int) throws -> [UInt8] {
        startBits(data)
        if deepTablesNeedInit { initialiseDeepTables() }
        var out = [UInt8](); out.reserveCapacity(size)
        while out.count < size {
            let c = decodeDeepCharacter()
            if c < 256 {
                text[deepLocation & 0x3FFF] = UInt8(c)
                deepLocation = (deepLocation + 1) & 0xFFFF
                out.append(UInt8(c))
            } else {
                var length = c - 255 + Self.threshold
                var from = (deepLocation - decodeDeepPosition() - 1) & 0xFFFF
                while length > 0 {
                    let byte = text[from & 0x3FFF]
                    text[deepLocation & 0x3FFF] = byte
                    deepLocation = (deepLocation + 1) & 0xFFFF
                    from = (from + 1) & 0xFFFF
                    out.append(byte)
                    length -= 1
                    if out.count >= size { break }
                }
            }
        }
        deepLocation = (deepLocation + 60) & 0x3FFF
        return out
    }

    // MARK: - Run length

    /// $90 escapes a run: the byte after it is the count, then the byte to
    /// repeat, and a count of $FF means the real count is the two after that.
    /// $90 followed by a zero is a literal $90.
    private func unpackRLE(_ data: [UInt8], _ size: Int) throws -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(size)
        var at = 0
        func next() throws -> UInt8 {
            guard at < data.count else { throw DiskImageError.corrupt("a run ran off the end of a track") }
            defer { at += 1 }
            return data[at]
        }
        while out.count < size {
            let a = try next()
            if a != 0x90 { out.append(a); continue }
            let b = try next()
            if b == 0 { out.append(0x90); continue }
            let value = try next()
            var run = Int(b)
            if b == 0xFF { run = Int(try next()) << 8 | Int(try next()) }
            guard out.count + run <= size else { throw DiskImageError.corrupt("a run is longer than its track") }
            out.append(contentsOf: repeatElement(value, count: run))
        }
        return out
    }

    // MARK: - One track

    func unpack(_ packed: [UInt8], mode: DMSArchive.Mode, flags: UInt8,
                intermediate: Int, unpacked: Int, track: Int) throws -> [UInt8] {
        defer {
            // A track whose low flag is clear puts every decruncher back to
            // where it started, so the next one begins afresh.
            if flags & 1 == 0 { reset() }
        }

        switch mode {
        case .none:
            guard packed.count >= unpacked else {
                throw DiskImageError.corrupt("track \(track) is shorter than it says")
            }
            return Array(packed.prefix(unpacked))

        case .simple:
            return try unpackRLE(packed, unpacked)

        case .quick:
            return try unpackRLE(unpackQuick(packed, intermediate), unpacked)

        case .medium:
            return try unpackRLE(unpackMedium(packed, intermediate), unpacked)

        case .deep:
            return try unpackRLE(unpackDeep(packed, intermediate), unpacked)

        case .heavy1, .heavy2:
            // Heavy 1 is told to use the narrow window, Heavy 2 the wide one.
            let heavyFlags = mode == .heavy2 ? flags | 8 : flags & 7
            let first = try unpackHeavy(packed, flags: heavyFlags, size: intermediate)
            // Only some tracks have a run-length pass over the top.
            return flags & 4 != 0 ? try unpackRLE(first, unpacked) : first
        }
    }
}

// MARK: - Tables

extension Decruncher {
    /// How Medium and Deep split a distance: the high part of it, and how many
    /// more bits of the low part follow.
    static let distanceCode: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09, 0x09,
        0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0A, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B, 0x0B,
        0x0C, 0x0C, 0x0C, 0x0C, 0x0D, 0x0D, 0x0D, 0x0D, 0x0E, 0x0E, 0x0E, 0x0E, 0x0F, 0x0F, 0x0F, 0x0F,
        0x10, 0x10, 0x10, 0x10, 0x11, 0x11, 0x11, 0x11, 0x12, 0x12, 0x12, 0x12, 0x13, 0x13, 0x13, 0x13,
        0x14, 0x14, 0x14, 0x14, 0x15, 0x15, 0x15, 0x15, 0x16, 0x16, 0x16, 0x16, 0x17, 0x17, 0x17, 0x17,
        0x18, 0x18, 0x19, 0x19, 0x1A, 0x1A, 0x1B, 0x1B, 0x1C, 0x1C, 0x1D, 0x1D, 0x1E, 0x1E, 0x1F, 0x1F,
        0x20, 0x20, 0x21, 0x21, 0x22, 0x22, 0x23, 0x23, 0x24, 0x24, 0x25, 0x25, 0x26, 0x26, 0x27, 0x27,
        0x28, 0x28, 0x29, 0x29, 0x2A, 0x2A, 0x2B, 0x2B, 0x2C, 0x2C, 0x2D, 0x2D, 0x2E, 0x2E, 0x2F, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
    ]

    static let distanceLength: [UInt8] = [
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05, 0x05,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06, 0x06,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07, 0x07,
        0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08,
    ]
}
