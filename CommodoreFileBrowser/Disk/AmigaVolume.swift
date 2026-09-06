import Foundation

/// An AmigaDOS volume: OFS or FFS, plain, international or with a directory
/// cache, on a floppy image or inside a partition of a hard disk image.
///
/// Everything is big-endian 32 bit longs in blocks of `blockSize`, which is 512
/// on a floppy but need not be on a hard disk, so every table size here is
/// derived from the block size rather than written down.
final class AmigaVolume {

    // MARK: - What kind of volume this is

    struct Variant {
        var isFFS: Bool
        var isInternational: Bool
        var hasDirCache: Bool

        /// The flags byte of the `DOS` signature, 0 to 5.
        init?(dosFlags: UInt8) {
            guard dosFlags <= 5 else { return nil }
            isFFS = dosFlags & 1 != 0
            isInternational = dosFlags == 2 || dosFlags == 3 || dosFlags >= 4
            hasDirCache = dosFlags >= 4
        }

        var dosFlags: UInt8 {
            if hasDirCache { return isFFS ? 5 : 4 }
            if isInternational { return isFFS ? 3 : 2 }
            return isFFS ? 1 : 0
        }

        var name: String {
            var parts = [isFFS ? "FFS" : "OFS"]
            if hasDirCache { parts.append("dir cache") }
            else if isInternational { parts.append("international") }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Block types

    private enum BlockType {
        static let header = 2        // T_HEADER: root, directory and file header
        static let data = 8          // T_DATA: an OFS data block
        static let list = 16         // T_LIST: a file extension block
        static let dirCache = 33     // T_DIRCACHE
    }

    private enum SecType {
        static let root = 1
        static let userDir = 2
        static let softLink = 3
        static let linkDir = 4
        static let file = -3
        static let linkFile = -4
    }

    // MARK: - State

    let store: BlockStore
    let variant: Variant
    let rootBlock: Int
    private var blockSize: Int { store.blockSize }
    /// Entries in a hash table, and in a file header's data block table.
    private var tableSize: Int { blockSize / 4 - 56 }
    /// Payload bytes in a data block. OFS spends 24 of them on a header.
    var dataBytesPerBlock: Int { variant.isFFS ? blockSize : blockSize - 24 }

    init(store: BlockStore) throws {
        self.store = store
        guard store.blockCount >= 4 else { throw DiskImageError.unsupportedFormat }

        let boot = try store.block(0)
        guard boot[0] == 0x44, boot[1] == 0x4F, boot[2] == 0x53,
              let variant = Variant(dosFlags: boot[3])
        else {
            // A great many Amiga floppies carry a loader rather than a file
            // system: the boot block is code, and there is no directory to
            // show. Saying so is more use than showing an empty disk.
            throw DiskImageError.corrupt("no AmigaDOS file system on this disk")
        }
        self.variant = variant

        // The boot block names the root, but almost nothing fills it in, and a
        // wrong one is common. The middle of the volume is where it belongs.
        let stated = Int(Self.long(boot, 8))
        let middle = store.blockCount / 2
        if store.holds(stated), stated > 1, (try? Self.isRoot(store.block(stated), blockSize: store.blockSize)) == true {
            rootBlock = stated
        } else {
            rootBlock = middle
        }
        guard try Self.isRoot(store.block(rootBlock), blockSize: store.blockSize) else {
            // Some loader disks stamp a DOS signature on the boot block and
            // then use the rest of the disk as they please. There is no volume
            // here either, whatever the first four bytes claim.
            throw DiskImageError.corrupt("no AmigaDOS file system on this disk")
        }
    }

    private static func isRoot(_ block: [UInt8], blockSize: Int) -> Bool {
        Int(Int32(bitPattern: long(block, 0))) == BlockType.header
            && Int(Int32(bitPattern: long(block, blockSize - 4))) == SecType.root
    }

    // MARK: - Reading longs and words

    static func long(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func signed(_ b: [UInt8], _ o: Int) -> Int { Int(Int32(bitPattern: long(b, o))) }

    static func setLong(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        guard o >= 0, o + 4 <= b.count else { return }
        b[o] = UInt8(truncatingIfNeeded: v >> 24)
        b[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
        b[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
        b[o + 3] = UInt8(truncatingIfNeeded: v)
    }

    static func setLong(_ b: inout [UInt8], _ o: Int, _ v: Int) {
        setLong(&b, o, UInt32(bitPattern: Int32(truncatingIfNeeded: v)))
    }

    // MARK: - Checksums

    /// Every header block sums to zero over its longs, with the checksum field
    /// holding whatever makes that true.
    static func headerChecksum(_ b: [UInt8], at field: Int) -> UInt32 {
        var sum: UInt32 = 0
        for o in stride(from: 0, to: b.count - 3, by: 4) where o != field {
            sum = sum &+ long(b, o)
        }
        return ~sum &+ 1
    }

    static func applyHeaderChecksum(_ b: inout [UInt8], at field: Int = 20) {
        setLong(&b, field, headerChecksum(b, at: field))
    }

    // MARK: - Names

    /// Upper case as the volume's own hash function means it. The plain file
    /// systems fold only a-z; the international ones fold the Latin-1 letters
    /// too, and a name hashed by the wrong rule is a name that cannot be found.
    private func upper(_ c: UInt8) -> UInt8 {
        if c >= 0x61 && c <= 0x7A { return c - 0x20 }
        if variant.isInternational, c >= 0xE0, c <= 0xFE, c != 0xF7 { return c - 0x20 }
        return c
    }

    func hash(_ name: [UInt8]) -> Int {
        var h = UInt32(name.count)
        for c in name {
            h = (h &* 13 &+ UInt32(upper(c))) & 0x7FF
        }
        return Int(h) % tableSize
    }

    /// Names are compared case-insensitively, by the same rule that hashes them.
    private func sameName(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { upper($0) == upper($1) }
    }

    private func name(in block: [UInt8]) -> [UInt8] {
        let lengthOffset = blockSize - 80
        let count = min(Int(block[lengthOffset]), 30)
        guard count > 0 else { return [] }
        return Array(block[(lengthOffset + 1)..<(lengthOffset + 1 + count)])
    }

    // MARK: - Field offsets
    //
    // Counted back from the end of the block, which is where AmigaDOS puts them
    // so that the table at the front can grow with the block size.

    private var secTypeOffset: Int { blockSize - 4 }
    private var extensionOffset: Int { blockSize - 8 }
    private var parentOffset: Int { blockSize - 12 }
    private var nextHashOffset: Int { blockSize - 16 }
    private var nameLengthOffset: Int { blockSize - 80 }
    private var daysOffset: Int { blockSize - 92 }
    /// Protection sits at the same place on a file header and a directory; the
    /// long after it is a file's length in bytes, and unused on a directory.
    private var protectionOffset: Int { blockSize - 192 }
    private var fileSizeOffset: Int { blockSize - 188 }
    private let hashTableOffset = 24
    private let dataTableOffset = 24

    // MARK: - Dates

    /// AmigaDOS counts days from the start of 1978, minutes into the day and
    /// fiftieths of a second into the minute.
    static let epoch: Date = {
        var c = DateComponents()
        c.year = 1978; c.month = 1; c.day = 1
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: c) ?? Date(timeIntervalSince1970: 252_460_800)
    }()

    private func date(in block: [UInt8], at offset: Int) -> Date? {
        let days = Self.signed(block, offset)
        let mins = Self.signed(block, offset + 4)
        let ticks = Self.signed(block, offset + 8)
        guard days >= 0, days < 50_000, mins >= 0, mins < 1440, ticks >= 0, ticks < 3000 else { return nil }
        if days == 0 && mins == 0 && ticks == 0 { return nil }
        return Self.epoch.addingTimeInterval(Double(days) * 86_400 + Double(mins) * 60 + Double(ticks) / 50)
    }

    static func dateFields(_ date: Date) -> (days: Int, mins: Int, ticks: Int) {
        let total = date.timeIntervalSince(epoch)
        guard total > 0 else { return (0, 0, 0) }
        let days = Int(total / 86_400)
        let rest = total - Double(days) * 86_400
        let mins = Int(rest / 60)
        let ticks = Int((rest - Double(mins) * 60) * 50)
        return (days, mins, min(ticks, 2999))
    }

    // MARK: - Protection bits

    /// `hsparwed`, the order AmigaDOS lists them in. The low four are stored
    /// inverted: a clear bit is a permission granted, which is why an ordinary
    /// file reads `----rwed`.
    static func protectionText(_ bits: UInt32) -> String {
        let set: [(Bool, Character)] = [
            (bits & 0x80 != 0, "h"), (bits & 0x40 != 0, "s"),
            (bits & 0x20 != 0, "p"), (bits & 0x10 != 0, "a"),
            (bits & 0x08 == 0, "r"), (bits & 0x04 == 0, "w"),
            (bits & 0x02 == 0, "e"), (bits & 0x01 == 0, "d"),
        ]
        return String(set.map { $0.0 ? $0.1 : "-" })
    }

    // MARK: - The volume itself

    var volumeName: [UInt8] {
        (try? name(in: store.block(rootBlock))) ?? []
    }

    var created: Date? {
        guard let root = try? store.block(rootBlock) else { return nil }
        return date(in: root, at: blockSize - 92)
    }

    // MARK: - Directories

    /// The block holding the directory at `path`, starting from the root.
    func directoryBlock(at path: [String]) throws -> Int {
        var current = rootBlock
        for component in path {
            let wanted = NameEncoding.latin1.bytes(component)
            guard let found = try lookup(wanted, in: current) else {
                throw DiskImageError.fileNotFound
            }
            let block = try store.block(found)
            let sec = Self.signed(block, secTypeOffset)
            guard sec == SecType.userDir || sec == SecType.linkDir else {
                throw DiskImageError.corrupt("\(component) is not a directory")
            }
            current = found
        }
        return current
    }

    /// Walk one hash chain looking for a name.
    private func lookup(_ wanted: [UInt8], in directory: Int) throws -> Int? {
        let dir = try store.block(directory)
        var next = Self.signed(dir, hashTableOffset + hash(wanted) * 4)
        var seen = Set<Int>()
        while store.holds(next), next > 0, !seen.contains(next) {
            seen.insert(next)
            let block = try store.block(next)
            if sameName(name(in: block), wanted) { return next }
            next = Self.signed(block, nextHashOffset)
        }
        return nil
    }

    /// Every entry of a directory, in name order — the hash table gives them in
    /// an order that means nothing to a reader.
    func entries(at path: [String]) throws -> [ImageEntry] {
        let directory = try directoryBlock(at: path)
        let dir = try store.block(directory)
        var found: [Int] = []
        var seen = Set<Int>()

        for slot in 0..<tableSize {
            var next = Self.signed(dir, hashTableOffset + slot * 4)
            while store.holds(next), next > 0, !seen.contains(next) {
                seen.insert(next)
                found.append(next)
                next = Self.signed(try store.block(next), nextHashOffset)
            }
        }

        var out: [ImageEntry] = []
        for block in found {
            if let entry = try? entry(at: block) { out.append(entry) }
        }
        // Directories first, then by name, matching the file system panel.
        return out.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// One directory entry, read from its own header block.
    func entry(at blockNumber: Int) throws -> ImageEntry {
        let block = try store.block(blockNumber)
        let sec = Self.signed(block, secTypeOffset)
        let isDirectory = sec == SecType.userDir || sec == SecType.linkDir
        let isLink = sec == SecType.softLink || sec == SecType.linkFile || sec == SecType.linkDir

        let protection = Self.long(block, protectionOffset)
        let size = isDirectory ? 0 : Int(Self.long(block, fileSizeOffset))
        let used = isDirectory ? 1 : max(1, (size + dataBytesPerBlock - 1) / dataBytesPerBlock + 1)

        return ImageEntry(slot: blockNumber,
                          name: name(in: block),
                          type: isDirectory ? .dir : .prg,
                          isSplat: false,
                          isLocked: protection & 0x04 != 0,   // write protected
                          blocks: used,
                          startTrack: 0,
                          startSector: 0,
                          entryOffset: blockNumber,
                          encoding: .latin1,
                          byteSize: isDirectory ? nil : size,
                          isDirectory: isDirectory,
                          flags: isLink ? "link" : Self.protectionText(protection),
                          modified: date(in: block, at: daysOffset))
    }

    // MARK: - Reading a file

    /// The data blocks of a file, in order, following the header's table and
    /// then any extension blocks after it.
    func dataBlocks(of header: Int) throws -> [Int] {
        var out: [Int] = []
        var current = header
        var seenBlocks = Set<Int>()

        while store.holds(current), !seenBlocks.contains(current) {
            seenBlocks.insert(current)
            let block = try store.block(current)
            let count = Self.signed(block, 8)                 // high_seq
            guard count >= 0, count <= tableSize else { break }
            // The table is filled from its far end backwards, so the first data
            // block of the file is the last entry of the table.
            for i in 0..<count {
                let pointer = Self.signed(block, dataTableOffset + (tableSize - 1 - i) * 4)
                if store.holds(pointer), pointer > 0 { out.append(pointer) }
            }
            let next = Self.signed(block, extensionOffset)
            guard store.holds(next), next > 0 else { break }
            current = next
        }
        return out
    }

    func read(_ entry: ImageEntry) throws -> Data {
        let header = try store.block(entry.slot)
        guard Self.signed(header, secTypeOffset) == SecType.file else {
            throw DiskImageError.corrupt("\(entry.displayName) is not a plain file")
        }
        var remaining = Int(Self.long(header, fileSizeOffset))
        var out = Data(capacity: remaining)

        for pointer in try dataBlocks(of: entry.slot) {
            guard remaining > 0 else { break }
            let block = try store.block(pointer)
            // OFS keeps a header on every data block and says how much of it is
            // in use; FFS gives the whole block over to the file.
            let start = variant.isFFS ? 0 : 24
            let available = variant.isFFS ? blockSize : min(Self.signed(block, 12), blockSize - 24)
            let take = min(remaining, max(0, available))
            out.append(contentsOf: block[start..<(start + take)])
            remaining -= take
        }
        return out
    }

    // MARK: - Free space

    /// The bitmap block holding a block's bit, and the bit's place in it.
    /// Block 2 is the first one the bitmap covers: the two boot blocks are not
    /// in it, being always in use.
    private func bitmapPosition(of block: Int) throws -> (block: Int, long: Int, bit: Int)? {
        guard block >= 2, block < store.blockCount else { return nil }
        let index = block - 2
        let longsPerBitmap = blockSize / 4 - 1
        let page = index / (longsPerBitmap * 32)
        guard let pages = try? bitmapPages(), page < pages.count else { return nil }
        let within = index % (longsPerBitmap * 32)
        return (pages[page], within / 32, within % 32)
    }

    /// The bitmap blocks, from the root block and then any extension blocks.
    func bitmapPages() throws -> [Int] {
        let root = try store.block(rootBlock)
        var pages: [Int] = []
        let firstPage = hashTableOffset + tableSize * 4 + 4      // past the table and bm_flag
        for i in 0..<25 {
            let p = Self.signed(root, firstPage + i * 4)
            if store.holds(p), p > 0 { pages.append(p) }
        }
        // Anything past the first 25 lives in a chain of extension blocks.
        var next = Self.signed(root, blockSize - 96)
        var seen = Set<Int>()
        while store.holds(next), next > 0, !seen.contains(next) {
            seen.insert(next)
            let block = try store.block(next)
            for i in 0..<(blockSize / 4 - 1) {
                let p = Self.signed(block, i * 4)
                if store.holds(p), p > 0 { pages.append(p) }
            }
            next = Self.signed(block, blockSize - 4)
        }
        return pages
    }

    func isFree(_ block: Int) throws -> Bool {
        guard let at = try bitmapPosition(of: block) else { return false }
        let bitmap = try store.block(at.block)
        return Self.long(bitmap, 4 + at.long * 4) & (1 << UInt32(at.bit)) != 0
    }

    var freeBlocks: Int {
        guard let pages = try? bitmapPages() else { return 0 }
        let longsPerPage = blockSize / 4 - 1
        let mappable = store.blockCount - 2
        var count = 0
        var index = 0
        for page in pages {
            guard let bitmap = try? store.block(page) else { break }
            for l in 0..<longsPerPage {
                guard index < mappable else { break }
                var word = Self.long(bitmap, 4 + l * 4)
                // The tail of the last page runs past the end of the volume,
                // and whatever is in those bits is not free space.
                let remaining = mappable - index
                if remaining < 32 { word &= (1 << UInt32(remaining)) - 1 }
                count += word.nonzeroBitCount
                index += 32
            }
        }
        return count
    }
}
