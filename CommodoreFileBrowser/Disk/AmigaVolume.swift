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

    // MARK: - Formatting a blank volume

    /// The boot block's checksum adds its longs with the carry folded back in,
    /// which is not the rule the rest of the volume uses.
    static func bootChecksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        for o in stride(from: 0, to: 1024, by: 4) where o != 4 {
            let d = long(bytes, o)
            if UInt32.max - sum < d { sum &+= 1 }
            sum &+= d
        }
        return ~sum
    }

    /// A freshly formatted volume: a boot block that names the file system, a
    /// root block in the middle, and a bitmap next to it with everything free
    /// but those two.
    static func format(blockCount: Int, blockSize: Int = 512,
                       variant: Variant, name rawName: [UInt8],
                       date: Date = Date()) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: blockCount * blockSize)
        let volumeName = legalName(rawName)
        let root = blockCount / 2
        let bitmap = root + 1
        let tableSize = blockSize / 4 - 56

        bytes[0] = 0x44; bytes[1] = 0x4F; bytes[2] = 0x53      // "DOS"
        bytes[3] = variant.dosFlags
        setLong(&bytes, 8, root)
        setLong(&bytes, 4, bootChecksum(bytes))

        // Everything is free except the root block and the bitmap itself. The
        // two boot blocks are not in the bitmap at all: they are never free.
        var map = [UInt8](repeating: 0, count: blockSize)
        let mappable = blockCount - 2
        for index in 0..<mappable {
            let o = 4 + (index / 32) * 4
            var word = long(map, o)
            word |= 1 << UInt32(index % 32)
            setLong(&map, o, word)
        }
        for used in [root, bitmap] {
            let index = used - 2
            let o = 4 + (index / 32) * 4
            setLong(&map, o, long(map, o) & ~(1 << UInt32(index % 32)))
        }
        applyHeaderChecksum(&map, at: 0)
        for (i, b) in map.enumerated() { bytes[bitmap * blockSize + i] = b }

        var rootBytes = [UInt8](repeating: 0, count: blockSize)
        setLong(&rootBytes, 0, BlockType.header)
        setLong(&rootBytes, 12, tableSize)                     // ht_size
        setLong(&rootBytes, 24 + tableSize * 4, -1)            // bm_flag: the map is valid
        setLong(&rootBytes, 24 + tableSize * 4 + 4, bitmap)    // bm_pages[0]
        let fields = dateFields(date)
        for offset in [blockSize - 92, blockSize - 40, blockSize - 28] {
            setLong(&rootBytes, offset, fields.days)
            setLong(&rootBytes, offset + 4, fields.mins)
            setLong(&rootBytes, offset + 8, fields.ticks)
        }
        rootBytes[blockSize - 80] = UInt8(volumeName.count)
        for (i, c) in volumeName.enumerated() { rootBytes[blockSize - 79 + i] = c }
        setLong(&rootBytes, blockSize - 4, SecType.root)
        applyHeaderChecksum(&rootBytes)
        for (i, b) in rootBytes.enumerated() { bytes[root * blockSize + i] = b }

        // A cached file system wants a cache for the root before anything else
        // goes on the disk.
        if variant.hasDirCache {
            let store = MemoryBlockStore(bytes: bytes, blockSize: blockSize, url: nil)
            if let volume = try? AmigaVolume(store: store), (try? volume.refreshDirectory(root)) != nil {
                return store.bytes
            }
        }
        return bytes
    }

    // MARK: - The directory cache
    //
    // DOS\4 and DOS\5 keep a second copy of each directory in blocks of packed
    // records, so that listing a drawer reads a block or two instead of one
    // block per entry. AmigaDOS trusts it over the directory itself, so a
    // volume whose cache is stale reads wrong on a real machine — which is why
    // every change here rebuilds the cache of the directory it touched.

    /// Records are packed one after another, each rounded up to an even length.
    private static func cacheRecordLength(name: [UInt8], comment: [UInt8]) -> Int {
        let raw = 25 + name.count + comment.count
        return raw % 2 == 0 ? raw : raw + 1
    }

    /// Free the cache blocks of a directory and forget them.
    func releaseDirCache(of directory: Int) throws {
        var block = try store.block(directory)
        var next = Self.signed(block, extensionOffset)
        var seen = Set<Int>()
        while store.holds(next), next > 0, !seen.contains(next) {
            seen.insert(next)
            let cache = try store.block(next)
            guard Self.signed(cache, 0) == BlockType.dirCache else { break }
            let following = Self.signed(cache, 16)
            try release(next)
            next = following
        }
        Self.setLong(&block, extensionOffset, 0)
        Self.applyHeaderChecksum(&block)
        try store.write(directory, block)
    }

    /// Rebuild a directory's cache from the directory itself. Nothing to do on
    /// the four file systems that keep no cache.
    func refreshDirectory(_ directory: Int) throws {
        guard variant.hasDirCache else { return }
        try releaseDirCache(of: directory)

        // Every entry, as the records the cache stores them as.
        let dir = try store.block(directory)
        var records: [[UInt8]] = []
        var seen = Set<Int>()
        for slot in 0..<tableSize {
            var next = Self.signed(dir, hashTableOffset + slot * 4)
            while store.holds(next), next > 0, !seen.contains(next) {
                seen.insert(next)
                if let record = try? cacheRecord(for: next) { records.append(record) }
                next = Self.signed(try store.block(next), nextHashOffset)
            }
        }

        // Pack them into as many blocks as it takes. An empty directory still
        // gets one, which is what a real drive leaves behind.
        let room = blockSize - 24
        var pages: [[[UInt8]]] = [[]]
        var used = 0
        for record in records {
            if used + record.count > room, !pages[pages.count - 1].isEmpty {
                pages.append([]); used = 0
            }
            pages[pages.count - 1].append(record)
            used += record.count
        }

        var blocks: [Int] = []
        for _ in pages { blocks.append(try allocate()) }
        for (index, page) in pages.enumerated() {
            var bytes = [UInt8](repeating: 0, count: blockSize)
            Self.setLong(&bytes, 0, BlockType.dirCache)
            Self.setLong(&bytes, 4, blocks[index])
            Self.setLong(&bytes, 8, directory)
            Self.setLong(&bytes, 12, page.count)
            Self.setLong(&bytes, 16, index + 1 < blocks.count ? blocks[index + 1] : 0)
            var at = 24
            for record in page {
                for (i, b) in record.enumerated() { bytes[at + i] = b }
                at += record.count
            }
            Self.applyHeaderChecksum(&bytes)
            try store.write(blocks[index], bytes)
        }

        var owner = try store.block(directory)
        Self.setLong(&owner, extensionOffset, blocks[0])
        Self.applyHeaderChecksum(&owner)
        try store.write(directory, owner)
    }

    /// One packed cache record. The four bytes after the protection bits are
    /// unused, and leaving them out is the easiest way to write a cache that
    /// AmigaDOS reads as gibberish.
    private func cacheRecord(for entryBlock: Int) throws -> [UInt8] {
        let block = try store.block(entryBlock)
        let sec = Self.signed(block, secTypeOffset)
        let isDirectory = sec == SecType.userDir || sec == SecType.linkDir
        let entryName = name(in: block)
        let comment: [UInt8] = []
        var record = [UInt8](repeating: 0, count: Self.cacheRecordLength(name: entryName, comment: comment))

        Self.setLong(&record, 0, entryBlock)
        Self.setLong(&record, 4, isDirectory ? 0 : Int(Self.long(block, fileSizeOffset)))
        Self.setLong(&record, 8, Int(Self.long(block, protectionOffset)))
        let days = Self.signed(block, daysOffset)
        let mins = Self.signed(block, daysOffset + 4)
        let ticks = Self.signed(block, daysOffset + 8)
        record[16] = UInt8(truncatingIfNeeded: days >> 8);  record[17] = UInt8(truncatingIfNeeded: days)
        record[18] = UInt8(truncatingIfNeeded: mins >> 8);  record[19] = UInt8(truncatingIfNeeded: mins)
        record[20] = UInt8(truncatingIfNeeded: ticks >> 8); record[21] = UInt8(truncatingIfNeeded: ticks)
        record[22] = UInt8(bitPattern: Int8(truncatingIfNeeded: sec))
        record[23] = UInt8(entryName.count)
        record[24] = UInt8(comment.count)
        for (i, c) in entryName.enumerated() { record[25 + i] = c }
        for (i, c) in comment.enumerated() { record[25 + entryName.count + i] = c }
        return record
    }

    /// The entries a directory's cache claims to hold, for checking it against
    /// the directory it is meant to mirror.
    func cachedNames(of directory: Int) throws -> [String] {
        var out: [String] = []
        var next = Self.signed(try store.block(directory), extensionOffset)
        var seen = Set<Int>()
        while store.holds(next), next > 0, !seen.contains(next) {
            seen.insert(next)
            let cache = try store.block(next)
            guard Self.signed(cache, 0) == BlockType.dirCache else { break }
            var at = 24
            for _ in 0..<Self.signed(cache, 12) {
                guard at + 25 <= blockSize else { break }
                let nameLength = Int(cache[at + 23])
                let commentLength = Int(cache[at + 24])
                guard at + 25 + nameLength <= blockSize else { break }
                out.append(NameEncoding.latin1.text(Array(cache[(at + 25)..<(at + 25 + nameLength)])))
                let raw = 25 + nameLength + commentLength
                at += raw % 2 == 0 ? raw : raw + 1
            }
            next = Self.signed(cache, 16)
        }
        return out
    }

    // MARK: - Allocation

    /// Mark a block used or free and keep the bitmap block's checksum right.
    private func setFree(_ block: Int, _ free: Bool) throws {
        guard let at = try bitmapPosition(of: block) else {
            throw DiskImageError.corrupt("block \(block) is outside the bitmap")
        }
        var bitmap = try store.block(at.block)
        let offset = 4 + at.long * 4
        let mask: UInt32 = 1 << UInt32(at.bit)
        var word = Self.long(bitmap, offset)
        if free { word |= mask } else { word &= ~mask }
        Self.setLong(&bitmap, offset, word)
        // A bitmap block keeps its checksum in the first long rather than the
        // sixth, which is the one place the rule differs.
        Self.setLong(&bitmap, 0, 0)
        Self.applyHeaderChecksum(&bitmap, at: 0)
        try store.write(at.block, bitmap)
    }

    /// Take a block for use, searching outwards from the root the way AmigaDOS
    /// does, so that a file lands near the directory holding it.
    func allocate() throws -> Int {
        for distance in 0..<store.blockCount {
            for candidate in [rootBlock + distance, rootBlock - distance] {
                guard candidate >= 2, candidate < store.blockCount else { continue }
                if try isFree(candidate) {
                    try setFree(candidate, false)
                    var empty = [UInt8](repeating: 0, count: blockSize)
                    empty[0] = 0
                    try store.write(candidate, empty)
                    return candidate
                }
            }
        }
        throw DiskImageError.diskFull
    }

    func release(_ block: Int) throws {
        guard block >= 2, block < store.blockCount else { return }
        try setFree(block, true)
    }

    /// Note that the volume changed, which is a date on the root block and the
    /// checksum that goes with it.
    func touchRoot(_ date: Date = Date()) throws {
        var root = try store.block(rootBlock)
        let fields = Self.dateFields(date)
        Self.setLong(&root, blockSize - 92, fields.days)
        Self.setLong(&root, blockSize - 88, fields.mins)
        Self.setLong(&root, blockSize - 84, fields.ticks)
        Self.applyHeaderChecksum(&root)
        try store.write(rootBlock, root)
    }

    // MARK: - Hash chains

    /// Put an entry into the hash chain its name belongs to. AmigaDOS adds to
    /// the end of the chain rather than the front, so a directory listed by
    /// hash order keeps the order things were made in.
    func insert(_ entryBlock: Int, into directory: Int) throws {
        var entry = try store.block(entryBlock)
        let entryName = name(in: entry)
        let slot = hashTableOffset + hash(entryName) * 4

        Self.setLong(&entry, nextHashOffset, 0)
        Self.setLong(&entry, parentOffset, directory)
        Self.applyHeaderChecksum(&entry)
        try store.write(entryBlock, entry)

        var dir = try store.block(directory)
        let first = Self.signed(dir, slot)
        if !store.holds(first) || first <= 0 {
            Self.setLong(&dir, slot, entryBlock)
            Self.applyHeaderChecksum(&dir)
            try store.write(directory, dir)
            return
        }
        var current = first
        var seen = Set<Int>()
        while !seen.contains(current) {
            seen.insert(current)
            var block = try store.block(current)
            let next = Self.signed(block, nextHashOffset)
            if !store.holds(next) || next <= 0 {
                Self.setLong(&block, nextHashOffset, entryBlock)
                Self.applyHeaderChecksum(&block)
                try store.write(current, block)
                return
            }
            current = next
        }
        throw DiskImageError.corrupt("the hash chain loops back on itself")
    }

    /// Take an entry out of its hash chain, leaving the rest of the chain whole.
    func unlink(_ entryBlock: Int, from directory: Int) throws {
        let entry = try store.block(entryBlock)
        let following = Self.signed(entry, nextHashOffset)
        let slot = hashTableOffset + hash(name(in: entry)) * 4

        var dir = try store.block(directory)
        if Self.signed(dir, slot) == entryBlock {
            Self.setLong(&dir, slot, following)
            Self.applyHeaderChecksum(&dir)
            try store.write(directory, dir)
            return
        }
        var current = Self.signed(dir, slot)
        var seen = Set<Int>()
        while store.holds(current), current > 0, !seen.contains(current) {
            seen.insert(current)
            var block = try store.block(current)
            if Self.signed(block, nextHashOffset) == entryBlock {
                Self.setLong(&block, nextHashOffset, following)
                Self.applyHeaderChecksum(&block)
                try store.write(current, block)
                return
            }
            current = Self.signed(block, nextHashOffset)
        }
        throw DiskImageError.fileNotFound
    }

    // MARK: - Making and unmaking entries

    /// Names AmigaDOS will take: thirty bytes, and neither of the two
    /// characters that mean something in a path.
    static func legalName(_ raw: [UInt8]) -> [UInt8] {
        var out = raw.filter { $0 != 0x2F && $0 != 0x3A && $0 >= 0x20 }
        if out.count > 30 { out = Array(out.prefix(30)) }
        return out.isEmpty ? Array("unnamed".utf8) : out
    }

    func existingEntry(named wanted: [UInt8], in directory: Int) throws -> Int? {
        try lookup(wanted, in: directory)
    }

    /// Write the fields every header block carries: its name, its date, and the
    /// checksum over the lot.
    private func stamp(_ block: inout [UInt8], name entryName: [UInt8], date: Date) {
        let fields = Self.dateFields(date)
        Self.setLong(&block, daysOffset, fields.days)
        Self.setLong(&block, daysOffset + 4, fields.mins)
        Self.setLong(&block, daysOffset + 8, fields.ticks)
        block[nameLengthOffset] = UInt8(entryName.count)
        for (i, c) in entryName.enumerated() { block[nameLengthOffset + 1 + i] = c }
        Self.applyHeaderChecksum(&block)
    }

    /// Put a file into a directory: its data blocks, the header that lists
    /// them, and however many extension blocks the list needs.
    @discardableResult
    func createFile(name rawName: [UInt8], data: Data, in directory: Int) throws -> Int {
        let entryName = Self.legalName(rawName)
        if try existingEntry(named: entryName, in: directory) != nil {
            throw DiskImageError.nameExists(NameEncoding.latin1.text(entryName))
        }

        let payload = [UInt8](data)
        let perBlock = dataBytesPerBlock
        let dataCount = (payload.count + perBlock - 1) / perBlock
        // The header holds the first tableful of pointers; every further
        // tableful needs an extension block of its own.
        let extensionCount = dataCount <= tableSize ? 0 : (dataCount - 1) / tableSize
        guard freeBlocks >= dataCount + extensionCount + 1 else { throw DiskImageError.diskFull }

        var taken: [Int] = []
        func undo() { for b in taken { try? release(b) } }

        do {
            let header = try allocate(); taken.append(header)
            var dataBlocks: [Int] = []
            for _ in 0..<dataCount { let b = try allocate(); taken.append(b); dataBlocks.append(b) }
            var extensionBlocks: [Int] = []
            for _ in 0..<extensionCount { let b = try allocate(); taken.append(b); extensionBlocks.append(b) }

            // The data itself. OFS puts a header on every block saying which
            // file it belongs to and where in the file it sits; FFS does not.
            for (i, block) in dataBlocks.enumerated() {
                var bytes = [UInt8](repeating: 0, count: blockSize)
                let start = i * perBlock
                let take = min(perBlock, payload.count - start)
                let offset = variant.isFFS ? 0 : 24
                for j in 0..<take { bytes[offset + j] = payload[start + j] }
                if !variant.isFFS {
                    Self.setLong(&bytes, 0, BlockType.data)
                    Self.setLong(&bytes, 4, header)
                    Self.setLong(&bytes, 8, i + 1)
                    Self.setLong(&bytes, 12, take)
                    Self.setLong(&bytes, 16, i + 1 < dataBlocks.count ? dataBlocks[i + 1] : 0)
                    Self.applyHeaderChecksum(&bytes)
                }
                try store.write(block, bytes)
            }

            // The pointer tables, filled from the far end backwards.
            let tables = [header] + extensionBlocks
            for (index, owner) in tables.enumerated() {
                var bytes = [UInt8](repeating: 0, count: blockSize)
                let slice = Array(dataBlocks.dropFirst(index * tableSize).prefix(tableSize))
                Self.setLong(&bytes, 0, index == 0 ? BlockType.header : BlockType.list)
                Self.setLong(&bytes, 4, owner)
                Self.setLong(&bytes, 8, slice.count)
                Self.setLong(&bytes, 16, slice.first ?? 0)
                for (i, pointer) in slice.enumerated() {
                    Self.setLong(&bytes, dataTableOffset + (tableSize - 1 - i) * 4, pointer)
                }
                let next = index + 1 < tables.count ? tables[index + 1] : 0
                Self.setLong(&bytes, extensionOffset, next)
                Self.setLong(&bytes, secTypeOffset, SecType.file)
                if index == 0 {
                    Self.setLong(&bytes, fileSizeOffset, payload.count)
                    Self.setLong(&bytes, parentOffset, directory)
                    stamp(&bytes, name: entryName, date: Date())
                } else {
                    Self.setLong(&bytes, parentOffset, header)
                    Self.applyHeaderChecksum(&bytes)
                }
                try store.write(owner, bytes)
            }

            try insert(header, into: directory)
            do { try refreshDirectory(directory) } catch {
                try? unlink(header, from: directory)
                throw error
            }
            try touchRoot()
            return header
        } catch {
            undo()
            throw error
        }
    }

    @discardableResult
    func createDirectory(name rawName: [UInt8], in directory: Int) throws -> Int {
        let entryName = Self.legalName(rawName)
        if try existingEntry(named: entryName, in: directory) != nil {
            throw DiskImageError.nameExists(NameEncoding.latin1.text(entryName))
        }
        let block = try allocate()
        var bytes = [UInt8](repeating: 0, count: blockSize)
        Self.setLong(&bytes, 0, BlockType.header)
        Self.setLong(&bytes, 4, block)
        Self.setLong(&bytes, parentOffset, directory)
        Self.setLong(&bytes, secTypeOffset, SecType.userDir)
        stamp(&bytes, name: entryName, date: Date())
        try store.write(block, bytes)

        try insert(block, into: directory)
        // A new directory needs a cache of its own before anything goes in it.
        try refreshDirectory(block)
        try refreshDirectory(directory)
        try touchRoot()
        return block
    }

    /// Free everything a file occupies: its data, its extension blocks and its
    /// header. A directory has to be empty first, the way AmigaDOS insists.
    func delete(_ entryBlock: Int, in directory: Int) throws {
        let block = try store.block(entryBlock)
        let sec = Self.signed(block, secTypeOffset)

        if sec == SecType.userDir {
            let dir = try store.block(entryBlock)
            for slot in 0..<tableSize where Self.signed(dir, hashTableOffset + slot * 4) != 0 {
                throw DiskImageError.directoryNotEmpty(NameEncoding.latin1.text(name(in: dir)))
            }
            try releaseDirCache(of: entryBlock)
        } else if sec == SecType.file {
            for data in try dataBlocks(of: entryBlock) { try release(data) }
            // The extension blocks are the chain the data tables hang off.
            var next = Self.signed(block, extensionOffset)
            var seen = Set<Int>()
            while store.holds(next), next > 0, !seen.contains(next) {
                seen.insert(next)
                let extensionBlock = try store.block(next)
                let following = Self.signed(extensionBlock, extensionOffset)
                try release(next)
                next = following
            }
        }

        try unlink(entryBlock, from: directory)
        try release(entryBlock)
        try refreshDirectory(directory)
        try touchRoot()
    }

    /// A new name means a new hash, so the entry comes out of its chain and
    /// goes back into the one the new name belongs to.
    func rename(_ entryBlock: Int, in directory: Int, to rawName: [UInt8]) throws {
        let entryName = Self.legalName(rawName)
        if let existing = try existingEntry(named: entryName, in: directory), existing != entryBlock {
            throw DiskImageError.nameExists(NameEncoding.latin1.text(entryName))
        }
        try unlink(entryBlock, from: directory)
        var block = try store.block(entryBlock)
        block[nameLengthOffset] = UInt8(entryName.count)
        for i in 0..<30 {
            block[nameLengthOffset + 1 + i] = i < entryName.count ? entryName[i] : 0
        }
        Self.applyHeaderChecksum(&block)
        try store.write(entryBlock, block)
        try insert(entryBlock, into: directory)
        try refreshDirectory(directory)
        try touchRoot()
    }

    func setProtection(_ entryBlock: Int, bits: UInt32) throws {
        var block = try store.block(entryBlock)
        Self.setLong(&block, protectionOffset, bits)
        Self.applyHeaderChecksum(&block)
        try store.write(entryBlock, block)
        if let parent = try? Self.signed(store.block(entryBlock), parentOffset), store.holds(parent) {
            try refreshDirectory(parent)
        }
    }

    func setVolumeName(_ rawName: [UInt8]) throws {
        let entryName = Self.legalName(rawName)
        var root = try store.block(rootBlock)
        root[nameLengthOffset] = UInt8(entryName.count)
        for i in 0..<30 {
            root[nameLengthOffset + 1 + i] = i < entryName.count ? entryName[i] : 0
        }
        Self.applyHeaderChecksum(&root)
        try store.write(rootBlock, root)
        try touchRoot()
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
