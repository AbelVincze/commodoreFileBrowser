import Foundation

/// The CBM DOS family: the 1541, 1571 and 1581 disks, the 2040 that came
/// before them, and the 8050 and 8250 of the PET drives. They share the
/// directory entry and the data-block chain, and differ in geometry, in where
/// the BAM sits and — on the PET drives — in the header pointing at the BAM
/// rather than at the directory.
final class CBMDiskImage: DiskImage {

    enum Format {
        case d64(tracks: Int)
        case d67
        case d71
        case d81
        case d80
        case d82

        var name: String {
            switch self {
            case .d64(let t): return "D64 (\(t) tracks)"
            case .d67: return "D67 (35 tracks)"
            case .d71: return "D71 (70 tracks)"
            case .d81: return "D81 (80 tracks)"
            case .d80: return "D80 (77 tracks)"
            case .d82: return "D82 (154 tracks)"
            }
        }

        /// The PET drives put the disk name at the top of the header sector and
        /// chain the header to the BAM; the 1541 family puts the name at the
        /// bottom of the BAM sector and chains straight to the directory.
        var isPET: Bool {
            switch self {
            case .d80, .d82: return true
            default: return false
            }
        }
    }

    // MARK: - Stored state

    let url: URL
    let format: Format
    /// Where the image proper starts. An X64 is a D64 behind a 64 byte header,
    /// and everything below here addresses the body, so the header is only
    /// ever carried along and written back out untouched.
    private let bodyOffset: Int
    private(set) var bytes: [UInt8]
    private(set) var entries: [ImageEntry] = []
    /// Byte offsets of every directory slot, in directory order, including the
    /// empty ones. Used for inserting and rearranging.
    private(set) var slotOffsets: [Int] = []
    private(set) var hasUnsavedChanges = false
    let canWrite: Bool

    // MARK: - Geometry

    private let trackCount: Int
    private let dirTrack: Int
    private let firstDirSector: Int
    private let interleave: Int

    let formatName: String

    // MARK: - Init

    /// The four bytes an X64 opens with: "C", $15, "Ad".
    private static let x64Magic: [UInt8] = [0x43, 0x15, 0x41, 0x64]

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        self.bytes = [UInt8](data)

        let isX64 = bytes.count > 64 && Array(bytes.prefix(4)) == Self.x64Magic
        bodyOffset = isX64 ? 64 : 0
        let size = bytes.count - bodyOffset

        // An X64 states its track count in the header, which settles the two
        // sizes a D64 body can be read as. Everything else goes by length,
        // each format having one size with error info and one without.
        if isX64, [35, 40, 42].contains(Int(bytes[7])) {
            format = .d64(tracks: Int(bytes[7]))
        } else {
            switch size {
            case 174_848, 175_531: format = .d64(tracks: 35)
            case 196_608, 197_376: format = .d64(tracks: 40)
            case 205_312, 206_114: format = .d64(tracks: 42)
            case 176_640, 177_330: format = .d67
            case 349_696, 351_062: format = .d71
            case 819_200, 822_400: format = .d81
            case 533_248, 535_331: format = .d80
            case 1_066_496, 1_070_662: format = .d82
            default:
                // Fall back on the extension for slightly off-size images.
                switch url.pathExtension.lowercased() {
                case "d64", "x64" where size >= 174_848: format = .d64(tracks: 35)
                case "d67" where size >= 176_640: format = .d67
                case "d71" where size >= 349_696: format = .d71
                case "d81" where size >= 819_200: format = .d81
                case "d80" where size >= 533_248: format = .d80
                case "d82" where size >= 1_066_496: format = .d82
                default: throw DiskImageError.unsupportedFormat
                }
            }
        }

        switch format {
        case .d64(let t): trackCount = t; dirTrack = 18; firstDirSector = 1; interleave = 10
        case .d67: trackCount = 35; dirTrack = 18; firstDirSector = 1; interleave = 10
        case .d71: trackCount = 70; dirTrack = 18; firstDirSector = 1; interleave = 6
        case .d81: trackCount = 80; dirTrack = 40; firstDirSector = 3; interleave = 1
        case .d80: trackCount = 77; dirTrack = 39; firstDirSector = 1; interleave = 10
        case .d82: trackCount = 154; dirTrack = 39; firstDirSector = 1; interleave = 10
        }

        formatName = isX64 ? "X64 (\(trackCount) tracks)" : format.name
        canWrite = FileManager.default.isWritableFile(atPath: url.path)
        try scanDirectory()
    }

    static func sectorsPerTrack(_ track: Int, format: Format) -> Int {
        func side(_ t: Int) -> Int {
            switch t {
            case 1...17: return 21
            case 18...24: return 19
            case 25...30: return 18
            default: return 17
            }
        }
        /// The 2040 fitted one more sector on the second zone than the 1541 did.
        func dos1(_ t: Int) -> Int {
            switch t {
            case 1...17: return 21
            case 18...24: return 20
            case 25...30: return 18
            default: return 17
            }
        }
        func pet(_ t: Int) -> Int {
            switch t {
            case 1...39: return 29
            case 40...53: return 27
            case 54...64: return 25
            default: return 23
            }
        }
        switch format {
        case .d81: return 40
        case .d64: return side(track)                       // tracks 36-42 hold 17
        case .d67: return dos1(track)
        case .d71: return side(track > 35 ? track - 35 : track)
        case .d80: return pet(track)
        case .d82: return pet(track > 77 ? track - 77 : track)   // second side repeats
        }
    }

    private func sectorsPerTrack(_ track: Int) -> Int {
        Self.sectorsPerTrack(track, format: format)
    }

    /// Byte offset of a track/sector, or nil if it is outside the image.
    private func offset(_ track: Int, _ sector: Int) -> Int? {
        guard track >= 1, track <= trackCount, sector >= 0, sector < sectorsPerTrack(track) else { return nil }
        var base = 0
        for t in 1..<track { base += sectorsPerTrack(t) }
        let o = bodyOffset + (base + sector) * 256
        return o + 256 <= bytes.count ? o : nil
    }

    // MARK: - Header

    /// Offset of the sector that carries the disk name and ID.
    private var headerOffset: Int { offset(dirTrack, 0) ?? 0 }

    private var nameFieldOffset: Int {
        switch format {
        case .d81: return headerOffset + 4
        case .d80, .d82: return headerOffset + 6
        default: return headerOffset + 144
        }
    }

    private var idFieldOffset: Int {
        switch format {
        case .d81: return headerOffset + 22
        case .d80, .d82: return headerOffset + 24
        default: return headerOffset + 162
        }
    }

    private var dosTypeOffset: Int {
        switch format {
        case .d81: return headerOffset + 25
        case .d80, .d82: return headerOffset + 27
        default: return headerOffset + 165
        }
    }

    var diskName: [UInt8] {
        Array(bytes[nameFieldOffset..<(nameFieldOffset + 16)])
    }

    /// `ID` + space + DOS type, exactly as a real drive prints it.
    var diskID: [UInt8]? {
        let id = Array(bytes[idFieldOffset..<(idFieldOffset + 2)])
        let dos = Array(bytes[dosTypeOffset..<(dosTypeOffset + 2)])
        return id + [0x20] + dos
    }

    /// The bytes of the header sector a directory listing prints: 16 of name,
    /// two of padding, two of ID, one more of padding and two of DOS type.
    /// Every format lays them out in that order — only the start moves — so
    /// one slice covers the lot, and a decorated directory can have all of it.
    static let headerFieldLength = 23

    var headerFieldBytes: [UInt8] {
        let o = nameFieldOffset
        guard o + Self.headerFieldLength <= bytes.count else { return [] }
        return Array(bytes[o..<(o + Self.headerFieldLength)])
    }

    /// Write that field back byte for byte, with none of the tidying
    /// `setDiskHeader` does. Anything short is padded out with shifted spaces.
    func setHeaderFieldBytes(_ raw: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let o = nameFieldOffset
        guard o + Self.headerFieldLength <= bytes.count else { throw DiskImageError.unsupportedFormat }
        for i in 0..<Self.headerFieldLength {
            bytes[o + i] = i < raw.count ? raw[i] : PETSCII.shiftedSpace
        }
        hasUnsavedChanges = true
    }

    func setDiskHeader(name: [UInt8], id: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let padded = PETSCII.padded16(PETSCII.trimPadding(name))
        for i in 0..<16 { bytes[nameFieldOffset + i] = padded[i] }
        var idBytes = Array(id.prefix(2))
        while idBytes.count < 2 { idBytes.append(0x20) }
        bytes[idFieldOffset] = idBytes[0]
        bytes[idFieldOffset + 1] = idBytes[1]
        hasUnsavedChanges = true
    }

    // MARK: - Directory

    func scanDirectory() throws {
        entries.removeAll()
        slotOffsets.removeAll()

        // The 1541 family chains the header sector straight to the first
        // directory sector. A PET drive chains it to the BAM instead, and the
        // directory only follows the last BAM block, so following the pointer
        // there would read allocation bitmaps as file names.
        var track = format.isPET ? dirTrack : Int(bytes[headerOffset])
        var sector = format.isPET ? firstDirSector : Int(bytes[headerOffset + 1])
        if track == 0 || offset(track, sector) == nil {
            track = dirTrack
            sector = firstDirSector
        }

        var visited = Set<Int>()
        var slot = 0

        while track != 0, let secOff = offset(track, sector), !visited.contains(secOff) {
            visited.insert(secOff)
            for i in 0..<8 {
                let e = secOff + i * 32
                slotOffsets.append(e)
                let typeByte = bytes[e + 2]
                defer { slot += 1 }
                guard typeByte != 0 else { continue }
                let type = CBMFileType(rawValue: typeByte & 0x07) ?? .prg
                let rawName = Array(bytes[(e + 5)..<(e + 21)])
                entries.append(ImageEntry(
                    slot: slot,
                    name: PETSCII.trimPadding(rawName),
                    type: type,
                    isSplat: (typeByte & 0x80) == 0,
                    isLocked: (typeByte & 0x40) != 0,
                    blocks: Int(bytes[e + 30]) | (Int(bytes[e + 31]) << 8),
                    startTrack: bytes[e + 3],
                    startSector: bytes[e + 4],
                    entryOffset: e))
            }
            track = Int(bytes[secOff])
            sector = Int(bytes[secOff + 1])
        }
        checkBAM()
    }

    /// Number of blocks where the BAM disagrees with what the directory and
    /// its files actually occupy. Recomputed whenever the directory is scanned.
    private(set) var bamMismatch = 0

    var integrityNote: String? {
        guard bamMismatch > 0 else { return nil }
        return "BAM MISMATCH (\(bamMismatch) BLOCK\(bamMismatch == 1 ? "" : "S"))"
    }

    /// Compare the allocation bitmap against the blocks the contents really
    /// use. Scene disks often hide data from the DOS by leaving the two out of
    /// step, and a half-written image shows up here too.
    private func checkBAM() {
        var used = Set<Int>()

        func claim(_ track: Int, _ sector: Int) {
            if let o = offset(track, sector) { used.insert(o / 256) }
        }
        func claimChain(from track: Int, _ sector: Int) {
            var t = track, s = sector
            var guardSet = Set<Int>()
            while t != 0, let o = offset(t, s), !guardSet.contains(o) {
                guardSet.insert(o)
                used.insert(o / 256)
                t = Int(bytes[o]); s = Int(bytes[o + 1])
            }
        }

        // The BAM and header sectors are always allocated on a real disk.
        claim(dirTrack, 0)
        switch format {
        case .d71: claim(53, 0)
        case .d81: claim(40, 1); claim(40, 2)
        case .d80: claim(38, 0); claim(38, 3)
        case .d82: for s in [0, 3, 6, 9] { claim(38, s) }
        case .d64, .d67: break
        }
        claimChain(from: Int(bytes[headerOffset]), Int(bytes[headerOffset + 1]))

        // And the directory as `scanDirectory` actually found it. Following
        // only the header link is not enough: a disk whose link byte is
        // rubbish still has a directory, read from the fixed first sector, and
        // its blocks are in use whatever the header says. Two disks here point
        // their header at track 169 and were reporting their own six directory
        // sectors as a mismatch that nothing could ever clear.
        var dirT = format.isPET ? dirTrack : Int(bytes[headerOffset])
        var dirS = format.isPET ? firstDirSector : Int(bytes[headerOffset + 1])
        if dirT == 0 || offset(dirT, dirS) == nil {
            dirT = dirTrack
            dirS = firstDirSector
        }
        claimChain(from: dirT, dirS)

        // A DEL entry owns nothing — the drive frees a scratched file's blocks
        // and only the name is left — so its start pointer, where it has one,
        // is not a claim on anything.
        for entry in entries where entry.startTrack != 0 && entry.type != .del {
            claimChain(from: Int(entry.startTrack), Int(entry.startSector))
        }

        var allocated = Set<Int>()
        for t in 1...trackCount where bam(track: t) != nil {
            for s in 0..<sectorsPerTrack(t) where !isFree(t, s) {
                if let o = offset(t, s) { allocated.insert(o / 256) }
            }
        }

        // Only blocks on tracks the BAM actually covers can be compared.
        var comparable = Set<Int>()
        for t in 1...trackCount where bam(track: t) != nil {
            for s in 0..<sectorsPerTrack(t) {
                if let o = offset(t, s) { comparable.insert(o / 256) }
            }
        }
        bamMismatch = used.intersection(comparable).symmetricDifference(allocated).count
    }

    func reload() throws {
        bytes = [UInt8](try Data(contentsOf: url))
        hasUnsavedChanges = false
        try scanDirectory()
    }

    // MARK: - BAM

    /// Where the free count and the allocation bitmap of a track live.
    private func bam(track: Int) -> (count: Int, bitmap: Int)? {
        guard track >= 1, track <= trackCount else { return nil }
        switch format {
        case .d64:
            // Tracks beyond 35 have no standard BAM, so we never allocate there.
            guard track <= 35, let base = offset(18, 0) else { return nil }
            return (base + 4 * track, base + 4 * track + 1)
        case .d67:
            guard let base = offset(18, 0) else { return nil }
            return (base + 4 * track, base + 4 * track + 1)
        case .d80, .d82:
            // Fifty tracks to a BAM block — a free count and four bitmap bytes
            // each — and the blocks sit three sectors apart on track 38.
            guard let base = offset(38, ((track - 1) / 50) * 3) else { return nil }
            let o = base + 6 + ((track - 1) % 50) * 5
            return (o, o + 1)
        case .d71:
            guard let base = offset(18, 0) else { return nil }
            if track <= 35 { return (base + 4 * track, base + 4 * track + 1) }
            guard let extra = offset(53, 0) else { return nil }
            return (base + 0xDD + (track - 36), extra + (track - 36) * 3)
        case .d81:
            let bamSector = track <= 40 ? 1 : 2
            guard let base = offset(40, bamSector) else { return nil }
            let o = base + 16 + ((track - 1) % 40) * 6
            return (o, o + 1)
        }
    }

    private func isFree(_ track: Int, _ sector: Int) -> Bool {
        guard let b = bam(track: track), sector < sectorsPerTrack(track) else { return false }
        return bytes[b.bitmap + sector / 8] & (1 << UInt8(sector % 8)) != 0
    }

    private func setAllocated(_ track: Int, _ sector: Int, _ allocated: Bool) {
        guard let b = bam(track: track), sector < sectorsPerTrack(track) else { return }
        let mask: UInt8 = 1 << UInt8(sector % 8)
        let idx = b.bitmap + sector / 8
        let wasFree = bytes[idx] & mask != 0
        if allocated, wasFree {
            bytes[idx] &= ~mask
            if bytes[b.count] > 0 { bytes[b.count] -= 1 }
        } else if !allocated, !wasFree {
            bytes[idx] |= mask
            if Int(bytes[b.count]) < sectorsPerTrack(track) { bytes[b.count] += 1 }
        }
    }

    var blocksFree: Int {
        var total = 0
        for t in countedTracks {
            if let b = bam(track: t) { total += Int(bytes[b.count]) }
        }
        return total
    }

    /// The tracks whose free counter adds up to `blocksFree`: everything the
    /// BAM covers apart from the directory track, and apart from the second
    /// BAM block a 1571 keeps on track 53.
    private var countedTracks: [Int] {
        (1...trackCount).filter { t in
            if t == dirTrack { return false }
            if case .d71 = format, t == 53 { return false }
            return bam(track: t) != nil
        }
    }

    /// The largest figure those counters can honestly add up to — a blank disk.
    var maximumBlocksFree: Int { countedTracks.reduce(0) { $0 + sectorsPerTrack($1) } }

    /// Make the directory report a given number of blocks free.
    ///
    /// Cosmetic: it moves the per-track free counters and leaves the
    /// allocation bitmaps alone, which is how a demo directory claims a full
    /// disk with the files still on it. The existing counts are nudged rather
    /// than rebuilt, so a disk stays as close to its real shape as the figure
    /// allows, and Repair Disk — which counts the bitmaps — would put it back.
    func setBlocksFree(_ target: Int) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        var delta = min(max(target, 0), maximumBlocksFree) - blocksFree
        for t in countedTracks {
            guard delta != 0, let b = bam(track: t) else { continue }
            let held = Int(bytes[b.count])
            let step = delta > 0 ? min(delta, max(0, sectorsPerTrack(t) - held))
                                 : max(delta, -held)
            bytes[b.count] = UInt8(held + step)
            delta -= step
        }
        hasUnsavedChanges = true
    }

    /// Track scan order: outwards from the directory track, the way CBM DOS does it.
    private var allocationTrackOrder: [Int] {
        var order: [Int] = []
        for d in 1...trackCount {
            let below = dirTrack - d
            let above = dirTrack + d
            if below >= 1 { order.append(below) }
            if above <= trackCount { order.append(above) }
        }
        if case .d71 = format { return order.filter { $0 != 53 } }
        return order
    }

    private func allocateSector(near previous: (track: Int, sector: Int)?) -> (track: Int, sector: Int)? {
        var candidates: [Int] = []
        if let previous, bam(track: previous.track) != nil { candidates.append(previous.track) }
        candidates.append(contentsOf: allocationTrackOrder)

        for track in candidates {
            guard bam(track: track) != nil else { continue }
            let count = sectorsPerTrack(track)
            var start = 0
            if let previous, previous.track == track { start = (previous.sector + interleave) % count }
            for i in 0..<count {
                let sector = (start + i) % count
                if isFree(track, sector) {
                    setAllocated(track, sector, true)
                    return (track, sector)
                }
            }
        }
        return nil
    }

    // MARK: - Reading

    func read(_ entry: ImageEntry) throws -> Data {
        var out = Data()
        var track = Int(entry.startTrack)
        var sector = Int(entry.startSector)
        var visited = Set<Int>()

        while track != 0 {
            guard let o = offset(track, sector), !visited.contains(o) else {
                if out.isEmpty { throw DiskImageError.corrupt("broken block chain") }
                break
            }
            visited.insert(o)
            let nextTrack = Int(bytes[o])
            let nextSector = Int(bytes[o + 1])
            if nextTrack == 0 {
                let used = max(0, nextSector - 1)
                out.append(contentsOf: bytes[(o + 2)..<(o + 2 + min(used, 254))])
                break
            }
            out.append(contentsOf: bytes[(o + 2)..<(o + 256)])
            track = nextTrack
            sector = nextSector
        }
        return out
    }

    // MARK: - Writing

    func write(name: [UInt8], type: CBMFileType, data: Data) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let clean = PETSCII.trimPadding(Array(name.prefix(16)))
        if entries.contains(where: { $0.name == clean && $0.type != .del }) {
            throw DiskImageError.nameExists(PETSCII.ascii(clean))
        }

        var chunks: [[UInt8]] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: 254, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append([UInt8](data[index..<end]))
            index = end
        }
        if chunks.isEmpty { chunks = [[]] }
        guard blocksFree >= chunks.count else { throw DiskImageError.diskFull }

        var allocated: [(track: Int, sector: Int)] = []
        var previous: (track: Int, sector: Int)?
        for _ in chunks {
            guard let s = allocateSector(near: previous) else {
                for a in allocated { setAllocated(a.track, a.sector, false) }
                throw DiskImageError.diskFull
            }
            allocated.append(s)
            previous = s
        }

        let slotOffset: Int
        do {
            slotOffset = try allocateDirectorySlot()
        } catch {
            for a in allocated { setAllocated(a.track, a.sector, false) }
            throw error
        }

        for (i, chunk) in chunks.enumerated() {
            guard let o = offset(allocated[i].track, allocated[i].sector) else { continue }
            for j in 0..<256 { bytes[o + j] = 0 }
            if i + 1 < allocated.count {
                bytes[o] = UInt8(allocated[i + 1].track)
                bytes[o + 1] = UInt8(allocated[i + 1].sector)
            } else {
                bytes[o] = 0
                bytes[o + 1] = UInt8(min(255, chunk.count + 1))
            }
            for (j, b) in chunk.enumerated() { bytes[o + 2 + j] = b }
        }

        writeEntry(at: slotOffset,
                   typeByte: 0x80 | type.rawValue,
                   name: clean,
                   track: UInt8(allocated[0].track),
                   sector: UInt8(allocated[0].sector),
                   blocks: allocated.count)

        hasUnsavedChanges = true
        try scanDirectory()
    }

    private func writeEntry(at o: Int, typeByte: UInt8, name: [UInt8], track: UInt8, sector: UInt8, blocks: Int) {
        for i in 2..<32 { bytes[o + i] = 0 }
        bytes[o + 2] = typeByte
        bytes[o + 3] = track
        bytes[o + 4] = sector
        let padded = PETSCII.padded16(name)
        for i in 0..<16 { bytes[o + 5 + i] = padded[i] }
        bytes[o + 30] = UInt8(blocks & 0xFF)
        bytes[o + 31] = UInt8((blocks >> 8) & 0xFF)
    }

    /// A free directory slot, growing the directory by a sector if needed.
    private func allocateDirectorySlot() throws -> Int {
        for o in slotOffsets where bytes[o + 2] == 0 { return o }

        // Link a fresh sector onto the end of the directory chain.
        var track = Int(bytes[headerOffset])
        var sector = Int(bytes[headerOffset + 1])
        if track == 0 || offset(track, sector) == nil { track = dirTrack; sector = firstDirSector }
        var lastOffset = offset(track, sector)
        var visited = Set<Int>()
        while let o = lastOffset, !visited.contains(o) {
            visited.insert(o)
            let nt = Int(bytes[o]), ns = Int(bytes[o + 1])
            if nt == 0 { break }
            guard let next = offset(nt, ns) else { break }
            lastOffset = next
        }
        guard let tail = lastOffset else { throw DiskImageError.directoryFull }

        let count = sectorsPerTrack(dirTrack)
        var newSector: Int?
        for s in 1..<count where isFree(dirTrack, s) { newSector = s; break }
        guard let ns = newSector, let newOffset = offset(dirTrack, ns) else {
            throw DiskImageError.directoryFull
        }
        setAllocated(dirTrack, ns, true)
        for i in 0..<256 { bytes[newOffset + i] = 0 }
        bytes[newOffset] = 0
        bytes[newOffset + 1] = 0xFF
        bytes[tail] = UInt8(dirTrack)
        bytes[tail + 1] = UInt8(ns)
        try scanDirectory()
        return newOffset
    }

    func delete(_ entry: ImageEntry) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        var track = Int(entry.startTrack)
        var sector = Int(entry.startSector)
        var visited = Set<Int>()
        while track != 0, let o = offset(track, sector), !visited.contains(o) {
            visited.insert(o)
            setAllocated(track, sector, false)
            track = Int(bytes[o])
            sector = Int(bytes[o + 1])
        }
        bytes[entry.entryOffset + 2] = 0
        hasUnsavedChanges = true
        try scanDirectory()
    }

    func rename(_ entry: ImageEntry, to name: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let padded = PETSCII.padded16(PETSCII.trimPadding(Array(name.prefix(16))))
        for i in 0..<16 { bytes[entry.entryOffset + 5 + i] = padded[i] }
        hasUnsavedChanges = true
        try scanDirectory()
    }

    /// The 16 name bytes exactly as the entry holds them, padding and all.
    /// `ImageEntry.name` has the trailing padding taken off, and a decorated
    /// entry is mostly padding, so an editor needs the field itself.
    func rawName(of entry: ImageEntry) -> [UInt8] {
        guard entry.entryOffset + 21 <= bytes.count else { return [] }
        return Array(bytes[(entry.entryOffset + 5)..<(entry.entryOffset + 21)])
    }

    /// Rewrite the two things a directory row prints for an entry: the whole
    /// 16 byte name field, past the shifted space that closes the quote as
    /// well as before it, and the block count in front of it.
    ///
    /// Neither is checked against the disk. The block count is what the
    /// listing says, not what the file occupies, which is the point — a
    /// decorated directory spells its picture in both.
    func setEntryFields(_ entry: ImageEntry, name: [UInt8], blocks: Int) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let padded = PETSCII.padded16(Array(name.prefix(16)))
        for i in 0..<16 { bytes[entry.entryOffset + 5 + i] = padded[i] }
        let count = min(max(blocks, 0), 0xFFFF)
        bytes[entry.entryOffset + 30] = UInt8(count & 0xFF)
        bytes[entry.entryOffset + 31] = UInt8((count >> 8) & 0xFF)
        hasUnsavedChanges = true
        try scanDirectory()
    }

    func setLocked(_ entry: ImageEntry, locked: Bool) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        if locked { bytes[entry.entryOffset + 2] |= 0x40 } else { bytes[entry.entryOffset + 2] &= ~0x40 }
        hasUnsavedChanges = true
        try scanDirectory()
    }

    // MARK: - Directory cosmetics

    func moveEntry(_ entry: ImageEntry, by delta: Int) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        guard let index = slotOffsets.firstIndex(of: entry.entryOffset) else { throw DiskImageError.fileNotFound }
        let target = index + delta
        guard target >= 0, target < slotOffsets.count else { return }
        swapSlots(slotOffsets[index], slotOffsets[target])
        hasUnsavedChanges = true
        try scanDirectory()
    }

    private func swapSlots(_ a: Int, _ b: Int) {
        for i in 2..<32 {
            bytes.swapAt(a + i, b + i)
        }
    }

    func addDecorativeEntry(name: [UInt8], after entry: ImageEntry?) throws {
        try addDecorativeEntry(name: name, blocks: 0, after: entry)
    }

    /// The same, with the block count the row prints spelled out — a decorated
    /// directory uses that column as much as it uses the name.
    func addDecorativeEntry(name: [UInt8], blocks: Int, after entry: ImageEntry?) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let free = try allocateDirectorySlot()
        guard let freeIndex = slotOffsets.firstIndex(of: free) else { throw DiskImageError.directoryFull }

        var insertIndex = freeIndex
        if let entry, let at = slotOffsets.firstIndex(of: entry.entryOffset), at + 1 <= freeIndex {
            insertIndex = at + 1
            // Shift everything between the insert point and the free slot down.
            var i = freeIndex
            while i > insertIndex {
                swapSlots(slotOffsets[i], slotOffsets[i - 1])
                i -= 1
            }
        }
        writeEntry(at: slotOffsets[insertIndex], typeByte: 0x80 | CBMFileType.del.rawValue,
                   name: Array(name.prefix(16)), track: 0, sector: 0,
                   blocks: min(max(blocks, 0), 0xFFFF))
        hasUnsavedChanges = true
        try scanDirectory()
    }

    // MARK: - Saving

    func save() throws {
        guard hasUnsavedChanges else { return }
        try Data(bytes).write(to: url, options: .atomic)
        hasUnsavedChanges = false
    }

    // MARK: - Formatting a blank image

    enum BlankFormat: String, CaseIterable, Identifiable {
        case d64 = "D64", d67 = "D67", d71 = "D71", d81 = "D81", d80 = "D80", d82 = "D82"
        var id: String { rawValue }
        var fileExtension: String { rawValue.lowercased() }

        /// Track counts the format can be made at. A 1541 disk was formatted to
        /// 35, but the drive could be pushed to 40 or 42 and images of that are
        /// common; every other format has one size each.
        var trackChoices: [Int] {
            switch self {
            case .d64: return [35, 40, 42]
            case .d67: return [35]
            case .d71: return [70]
            case .d81: return [80]
            case .d80: return [77]
            case .d82: return [154]
            }
        }

        var defaultTracks: Int { trackChoices[0] }

        var format: Format {
            switch self {
            case .d64: return .d64(tracks: defaultTracks)
            case .d67: return .d67
            case .d71: return .d71
            case .d81: return .d81
            case .d80: return .d80
            case .d82: return .d82
            }
        }

        func subtitle(tracks: Int) -> String {
            switch self {
            case .d64:
                let base = "1541 - \(tracks) tracks, 664 blocks free"
                // The BAM a 1541 writes only reaches track 35. The sectors past
                // it are in the file and are left alone, but nothing here — or
                // on an unextended drive — will put a file on them.
                return tracks > 35 ? base + " (36-\(tracks) need an extended DOS)" : base
            case .d67: return "2040 - 35 tracks, 670 blocks free (DOS 1)"
            case .d71: return "1571 - 70 tracks, 1328 blocks free"
            case .d81: return "1581 - 80 tracks, 3160 blocks free"
            case .d80: return "8050 - 77 tracks, 2052 blocks free"
            case .d82: return "8250 - 154 tracks, 4133 blocks free"
            }
        }
    }

    /// Write a freshly formatted, empty image to disk. `tracks` is only a
    /// choice for a D64; the others are clamped to the one size they have.
    static func createBlank(_ kind: BlankFormat, tracks: Int? = nil,
                            name: [UInt8], id: [UInt8], at url: URL) throws {
        let trackCount = kind.trackChoices.contains(tracks ?? -1) ? tracks! : kind.defaultTracks
        let format: Format = (kind == .d64) ? .d64(tracks: trackCount) : kind.format

        // 683 sectors to track 35, then 17 a track: 174,848 bytes at 35,
        // 196,608 at 40 and 205,312 at 42.
        let size = (1...trackCount).reduce(0) { $0 + sectorsPerTrack($1, format: format) } * 256
        var bytes = [UInt8](repeating: 0, count: size)

        func offset(_ track: Int, _ sector: Int) -> Int {
            var base = 0
            for t in 1..<track { base += sectorsPerTrack(t, format: format) }
            return (base + sector) * 256
        }
        func bamLocation(_ track: Int) -> (count: Int, bitmap: Int)? {
            switch format {
            case .d64:
                guard track <= 35 else { return nil }
                return (offset(18, 0) + 4 * track, offset(18, 0) + 4 * track + 1)
            case .d67:
                return (offset(18, 0) + 4 * track, offset(18, 0) + 4 * track + 1)
            case .d71:
                if track <= 35 { return (offset(18, 0) + 4 * track, offset(18, 0) + 4 * track + 1) }
                return (offset(18, 0) + 0xDD + (track - 36), offset(53, 0) + (track - 36) * 3)
            case .d81:
                let o = offset(40, track <= 40 ? 1 : 2) + 16 + ((track - 1) % 40) * 6
                return (o, o + 1)
            case .d80, .d82:
                let o = offset(38, ((track - 1) / 50) * 3) + 6 + ((track - 1) % 50) * 5
                return (o, o + 1)
            }
        }
        func markAllocated(_ track: Int, _ sector: Int) {
            guard let b = bamLocation(track) else { return }
            let mask: UInt8 = 1 << UInt8(sector % 8)
            if bytes[b.bitmap + sector / 8] & mask != 0 {
                bytes[b.bitmap + sector / 8] &= ~mask
                bytes[b.count] -= 1
            }
        }

        let paddedName = PETSCII.padded16(PETSCII.trimPadding(name))
        var diskID = Array(id.prefix(2))
        while diskID.count < 2 { diskID.append(0x20) }

        // Every sector free to begin with. A bitmap byte covers eight sectors,
        // so the widest track of the format decides how many there are.
        let bitmapBytes: Int
        switch format {
        case .d81: bitmapBytes = 5
        case .d80, .d82: bitmapBytes = 4
        default: bitmapBytes = 3
        }
        for t in 1...trackCount {
            guard let b = bamLocation(t) else { continue }
            let n = sectorsPerTrack(t, format: format)
            bytes[b.count] = UInt8(n)
            for i in 0..<bitmapBytes {
                let bitsLeft = n - i * 8
                bytes[b.bitmap + i] = bitsLeft >= 8 ? 0xFF : (bitsLeft <= 0 ? 0x00 : UInt8((1 << bitsLeft) - 1))
            }
        }

        switch format {
        case .d64, .d67, .d71:
            let bam = offset(18, 0)
            bytes[bam] = 18; bytes[bam + 1] = 1
            // DOS 1 on the 2040 numbered its version rather than lettering it,
            // and left the two type bytes blank where later drives wrote "2A".
            bytes[bam + 2] = (kind == .d67) ? 0x01 : 0x41
            bytes[bam + 3] = (kind == .d71) ? 0x80 : 0  // double sided flag
            for i in 0..<16 { bytes[bam + 144 + i] = paddedName[i] }
            bytes[bam + 160] = 0xA0; bytes[bam + 161] = 0xA0
            bytes[bam + 162] = diskID[0]; bytes[bam + 163] = diskID[1]
            bytes[bam + 164] = 0xA0
            if kind == .d67 {
                bytes[bam + 165] = 0x20; bytes[bam + 166] = 0xA0
            } else {
                bytes[bam + 165] = 0x32; bytes[bam + 166] = 0x41   // "2A"
            }
            for i in 167...170 { bytes[bam + i] = 0xA0 }
            let dir = offset(18, 1)
            bytes[dir] = 0; bytes[dir + 1] = 0xFF
            markAllocated(18, 0)
            markAllocated(18, 1)
            if kind == .d71 { markAllocated(53, 0) }

        case .d81:
            let header = offset(40, 0)
            bytes[header] = 40; bytes[header + 1] = 3
            bytes[header + 2] = 0x44                    // 'D'
            for i in 0..<16 { bytes[header + 4 + i] = paddedName[i] }
            bytes[header + 20] = 0xA0; bytes[header + 21] = 0xA0
            bytes[header + 22] = diskID[0]; bytes[header + 23] = diskID[1]
            bytes[header + 24] = 0xA0
            bytes[header + 25] = 0x33; bytes[header + 26] = 0x44  // "3D"
            bytes[header + 27] = 0xA0; bytes[header + 28] = 0xA0
            for (sector, next) in [(1, (40, 2)), (2, (0, 255))] {
                let o = offset(40, sector)
                bytes[o] = UInt8(next.0); bytes[o + 1] = UInt8(next.1)
                bytes[o + 2] = 0x44; bytes[o + 3] = 0xBB
                bytes[o + 4] = diskID[0]; bytes[o + 5] = diskID[1]
                bytes[o + 6] = 0xC0
            }
            let dir = offset(40, 3)
            bytes[dir] = 0; bytes[dir + 1] = 0xFF
            for s in 0...3 { markAllocated(40, s) }

        case .d80, .d82:
            // The header names the disk and points at the BAM; the BAM blocks
            // chain to one another and the last one chains to the directory.
            let bamSectors = (format.isPET && kind == .d82) ? [0, 3, 6, 9] : [0, 3]
            let header = offset(39, 0)
            bytes[header] = 38; bytes[header + 1] = UInt8(bamSectors[0])
            bytes[header + 2] = 0x43                    // 'C'
            for i in 0..<16 { bytes[header + 6 + i] = paddedName[i] }
            bytes[header + 22] = 0xA0; bytes[header + 23] = 0xA0
            bytes[header + 24] = diskID[0]; bytes[header + 25] = diskID[1]
            bytes[header + 26] = 0xA0
            bytes[header + 27] = 0x32; bytes[header + 28] = 0x43   // "2C"
            for i in 29...31 { bytes[header + i] = 0xA0 }

            // Fifty tracks to a block, and each block says which range it holds.
            for (i, sector) in bamSectors.enumerated() {
                let o = offset(38, sector)
                let isLast = i == bamSectors.count - 1
                bytes[o] = isLast ? 39 : 38
                bytes[o + 1] = isLast ? 1 : UInt8(bamSectors[i + 1])
                bytes[o + 2] = 0x43
                bytes[o + 4] = UInt8(i * 50 + 1)
                bytes[o + 5] = UInt8(min(i * 50 + 51, trackCount + 1))
            }

            let dir = offset(39, 1)
            bytes[dir] = 0; bytes[dir + 1] = 0xFF
            markAllocated(39, 0)
            markAllocated(39, 1)
            for sector in bamSectors { markAllocated(38, sector) }
        }

        try Data(bytes).write(to: url, options: .withoutOverwriting)
    }
}

// MARK: - Repair

/// What a repair found, and what it would change.
///
/// Produced before anything is written so the sheet can say both halves of it:
/// this is what is wrong, this is what I am about to do.
struct DiskRepairPlan {
    struct FileFinding {
        var name: String
        var statedBlocks: Int
        var actualBlocks: Int
    }
    /// One sector claimed by more than one file. Blocking: there is no way to
    /// tell which of them the sector really belongs to.
    struct Collision {
        var track: Int
        var sector: Int
        var claimedBy: [String]
    }

    var filesChecked = 0
    /// Unclosed files, which a repair scratches the way `VALIDATE` does.
    var splatToScratch: [String] = []
    var wrongCounts: [FileFinding] = []
    /// Allocated in the BAM and used by nothing.
    var toFree = 0
    /// In use and marked free, which is how a save overwrites a file.
    var toAllocate = 0
    /// Tracks whose free count disagrees with their own map. This is what
    /// makes a disk report more free blocks than it has room for, and the
    /// header's mismatch check cannot see it — that compares which blocks are
    /// allocated, not how many each track says it has.
    var badFreeCounts = 0
    var blocksFreeBefore = 0
    var blocksFreeAfter = 0
    var collisions: [Collision] = []
    var brokenChains: [String] = []

    /// Repair only touches a disk it can put entirely right. A shared sector
    /// or a chain that leaves the disk is damage the BAM cannot describe, and
    /// guessing at it would lose a file rather than save one.
    var canRepair: Bool { collisions.isEmpty && brokenChains.isEmpty }

    /// The files standing between this disk and a repair: the ones whose
    /// chain leaves the disk or turns back on itself, and everyone mixed up
    /// in a shared sector.
    ///
    /// Every claimant of a shared sector is named, not one of them. The
    /// sector belongs to a single file and nothing on the disk says which, so
    /// keeping either would be a guess — and a guess that leaves a live file
    /// pointing into another's data is worse than losing both.
    ///
    /// The directory itself is never listed. It is claimed under one name so
    /// its two routes are not read as two claimants, and it is not a file
    /// anyone can scratch.
    var blockingFiles: [String] {
        var names: [String] = []
        func add(_ name: String) {
            guard name != CBMDiskImage.systemClaimant, !names.contains(name) else { return }
            names.append(name)
        }
        for name in brokenChains { add(name) }
        for clash in collisions { for name in clash.claimedBy { add(name) } }
        return names
    }

    var isClean: Bool {
        splatToScratch.isEmpty && wrongCounts.isEmpty && toFree == 0 && toAllocate == 0
            && badFreeCounts == 0 && collisions.isEmpty && brokenChains.isEmpty
    }
}

extension CBMDiskImage {

    /// What a repair would find and do. Writes nothing.
    func analyseForRepair() -> DiskRepairPlan { survey().plan }

    /// The name a sector held by the disk itself is claimed under. Not a
    /// file, and never offered up for deletion.
    static let systemClaimant = "the directory"

    /// Scratch the files a repair cannot see past, and say which went.
    ///
    /// Only the directory entry is touched. Freeing their blocks here would
    /// be the wrong move twice over — a shared sector is still another file's,
    /// and a chain that loops cannot be walked to its end — so the blocks are
    /// left where they are for the repair that follows to work out afresh.
    /// That is the whole point of doing this first: with the entries gone,
    /// the survey has nothing left it cannot describe.
    @discardableResult
    func deleteBlockingFiles() throws -> [String] {
        guard canWrite else { throw DiskImageError.readOnly }
        let doomed = Set(survey().plan.blockingFiles)
        guard !doomed.isEmpty else { return [] }

        var scratched: [String] = []
        for entry in entries where entry.type != .del && doomed.contains(entry.displayName) {
            bytes[entry.entryOffset + 2] = 0
            scratched.append(entry.displayName)
        }
        hasUnsavedChanges = true
        try scanDirectory()
        return scratched
    }

    /// Put the disk right, and say what was done.
    ///
    /// The survey is taken again rather than trusting the one the sheet was
    /// built from: it is cheap, and it means the report and the repair can
    /// never be describing different disks.
    @discardableResult
    func applyRepair() throws -> DiskRepairPlan {
        guard canWrite else { throw DiskImageError.readOnly }
        let found = survey()
        guard found.plan.canRepair else {
            throw DiskImageError.corrupt("this disk has damage a repair cannot put right")
        }

        // Scratching is a zeroed type byte, which is exactly what the drive
        // does: the slot becomes empty and the next save can have it.
        for offset in found.splatOffsets { bytes[offset + 2] = 0 }

        // The block count is two bytes in the middle of an entry, and
        // `writeEntry` clears the whole of one, so this is written by hand.
        for correction in found.corrections {
            bytes[correction.offset + 30] = UInt8(correction.blocks & 0xFF)
            bytes[correction.offset + 31] = UInt8((correction.blocks >> 8) & 0xFF)
        }

        // Every track back to empty, then everything the files actually occupy
        // allocated again. Starting from a written count rather than the one
        // that was there is the point: from a known figure `setAllocated`
        // subtracting one per sector arrives at the right answer.
        for track in 1...trackCount where bam(track: track) != nil {
            resetTrackToFree(track)
        }
        for key in found.claims.keys { setAllocated(key >> 8, key & 0xFF, true) }

        hasUnsavedChanges = true
        try scanDirectory()
        return found.plan
    }

    // MARK: The survey

    private struct Survey {
        var plan = DiskRepairPlan()
        /// Every sector in use, keyed `track << 8 | sector`, and who claims it.
        var claims: [Int: [String]] = [:]
        var corrections: [(offset: Int, blocks: Int)] = []
        var splatOffsets: [Int] = []
    }

    /// Puts a whole track back to empty: every sector free, and the free count
    /// written rather than counted up to.
    ///
    /// `setAllocated` keeps the count in step by adding and subtracting one,
    /// which is right for a drive going about its business and useless here.
    /// Freeing a sector that is already free changes nothing, so a count byte
    /// that was rubbish to begin with would survive being freed and then be
    /// decremented from rubbish. One disk here claims 193 free sectors on a
    /// track that holds 21, and 3106 free blocks on a disk that holds 664.
    private func resetTrackToFree(_ track: Int) {
        guard let b = bam(track: track) else { return }
        let count = sectorsPerTrack(track)
        for byte in 0..<((count + 7) / 8) { bytes[b.bitmap + byte] = 0 }
        for sector in 0..<count { bytes[b.bitmap + sector / 8] |= 1 << UInt8(sector % 8) }
        bytes[b.count] = UInt8(count)
    }

    /// Tracks whose free count does not match their own bitmap. Nothing else
    /// looks at this: `checkBAM` compares which blocks are allocated, so a disk
    /// can have a perfectly good map and still report an impossible number of
    /// blocks free.
    private func tracksWithBadFreeCount() -> Int {
        var bad = 0
        for track in 1...trackCount {
            guard let b = bam(track: track) else { continue }
            let count = sectorsPerTrack(track)
            let free = (0..<count).filter { isFree(track, $0) }.count
            if Int(bytes[b.count]) != free { bad += 1 }
        }
        return bad
    }

    /// Follows a sector chain. `ok` is false where it ran off the disk or came
    /// back to a sector it had already been through — neither is something the
    /// BAM can be made to describe.
    private func repairChain(from track: Int, _ sector: Int) -> (blocks: [Int], ok: Bool) {
        var out: [Int] = []
        var t = track, s = sector
        var seen = Set<Int>()
        while t != 0 {
            guard let o = offset(t, s), !seen.contains(o) else { return (out, false) }
            seen.insert(o)
            out.append(t << 8 | s)
            t = Int(bytes[o])
            s = Int(bytes[o + 1])
        }
        return (out, true)
    }

    private func survey() -> Survey {
        var found = Survey()
        found.plan.blocksFreeBefore = blocksFree

        func claim(_ key: Int, by name: String) {
            guard offset(key >> 8, key & 0xFF) != nil else { return }
            if found.claims[key]?.contains(name) == true { return }
            found.claims[key, default: []].append(name)
        }

        // The sectors a drive always keeps for itself: the header, the BAM
        // blocks of whichever format this is, and the directory. Claimed under
        // one name so the directory arriving by two routes below is not read
        // as two claimants.
        let system = Self.systemClaimant
        claim(dirTrack << 8, by: system)
        switch format {
        case .d71: claim(53 << 8, by: system)
        case .d81: claim(40 << 8 | 1, by: system); claim(40 << 8 | 2, by: system)
        case .d80: claim(38 << 8, by: system); claim(38 << 8 | 3, by: system)
        case .d82: for s in [0, 3, 6, 9] { claim(38 << 8 | s, by: system) }
        case .d64, .d67: break
        }

        // Both routes into the directory, because both are real. A PET drive
        // chains its header to the BAM and the directory only follows that,
        // while `scanDirectory` falls back to the fixed first sector when the
        // link is unusable — and the blocks it read are the blocks in use.
        for key in repairChain(from: Int(bytes[headerOffset]),
                               Int(bytes[headerOffset + 1])).blocks {
            claim(key, by: system)
        }
        var track = format.isPET ? dirTrack : Int(bytes[headerOffset])
        var sector = format.isPET ? firstDirSector : Int(bytes[headerOffset + 1])
        if track == 0 || offset(track, sector) == nil {
            track = dirTrack
            sector = firstDirSector
        }
        for key in repairChain(from: track, sector).blocks { claim(key, by: system) }

        for entry in entries {
            let name = entry.displayName
            // A listed DEL is a rule or a box drawn in the directory. It owns
            // no blocks and is left exactly as it is.
            if entry.type == .del { continue }
            // An unclosed file is what a drive leaves after an interrupted
            // save, and its entry usually still points into a live file's
            // data. VALIDATE scratches these, and setting them aside here —
            // before anything is compared — is what lets the rest of the disk
            // be put right at all.
            if entry.isSplat {
                found.plan.splatToScratch.append(name)
                found.splatOffsets.append(entry.entryOffset)
                continue
            }

            found.plan.filesChecked += 1
            let walk = repairChain(from: Int(entry.startTrack), Int(entry.startSector))
            guard walk.ok else { found.plan.brokenChains.append(name); continue }
            var blocks = walk.blocks

            // A REL file's side sectors are blocks like any other, and nothing
            // else in this browser follows them. Missing them would mean
            // freeing them, which is how a repair would break a file.
            if entry.type == .rel {
                let side = repairChain(from: Int(bytes[entry.entryOffset + 21]),
                                       Int(bytes[entry.entryOffset + 22]))
                guard side.ok else { found.plan.brokenChains.append(name); continue }
                blocks += side.blocks
            }

            for key in blocks { claim(key, by: name) }
            if entry.blocks != blocks.count {
                found.plan.wrongCounts.append(.init(name: name,
                                                    statedBlocks: entry.blocks,
                                                    actualBlocks: blocks.count))
            }
            found.corrections.append((entry.entryOffset, blocks.count))
        }

        for (key, names) in found.claims where names.count > 1 {
            found.plan.collisions.append(.init(track: key >> 8, sector: key & 0xFF,
                                               claimedBy: names))
        }
        found.plan.collisions.sort { ($0.track, $0.sector) < ($1.track, $1.sector) }

        // Only tracks the BAM covers can be compared: a 40 track D64 has
        // sectors past the end of its own allocation map.
        for t in 1...trackCount where bam(track: t) != nil {
            for s in 0..<sectorsPerTrack(t) {
                let inUse = found.claims[t << 8 | s] != nil
                let free = isFree(t, s)
                if inUse, free { found.plan.toAllocate += 1 }
                if !inUse, !free { found.plan.toFree += 1 }
            }
        }

        // What `blocksFree` would report afterwards, counted the same way it
        // counts: the directory track never contributes.
        var after = 0
        for t in 1...trackCount where t != dirTrack && bam(track: t) != nil {
            if case .d71 = format, t == 53 { continue }
            let used = (0..<sectorsPerTrack(t)).filter { found.claims[t << 8 | $0] != nil }.count
            after += sectorsPerTrack(t) - used
        }
        found.plan.blocksFreeAfter = after
        found.plan.badFreeCounts = tracksWithBadFreeCount()

        return found
    }
}
