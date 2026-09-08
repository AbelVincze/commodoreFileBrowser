import Foundation

/// A UAE hardfile. Either one bare AmigaDOS volume filling the file, or a
/// disk with a Rigid Disk Block at the front describing partitions — in which
/// case the root of the image is the partition list, and a volume is a level
/// down from it.
///
/// The file is read through a memory map and written a block at a time, so
/// changing a directory entry on a two gigabyte hardfile writes one block.
final class HDFImage: DiskImage {

    struct Partition {
        var name: String
        var byteOffset: Int
        var blockSize: Int
        var blockCount: Int
        var dosType: UInt32

        /// `DOS\0` to `DOS\5` are the ones AmigaDOS itself reads. PFS and SFS
        /// are third party file systems that live in a partition just the same.
        var isAmigaDOS: Bool { dosType & 0xFFFF_FF00 == 0x444F_5300 && dosType & 0xFF <= 5 }

        var fileSystemName: String {
            var tag = ""
            for shift in [24, 16, 8] {
                let c = UInt8(truncatingIfNeeded: dosType >> UInt32(shift))
                tag.append(c >= 0x20 && c < 0x7F ? Character(UnicodeScalar(c)) : "?")
            }
            return "\(tag)\\\(dosType & 0xFF)"
        }
    }

    let url: URL
    let canWrite: Bool
    private(set) var partitions: [Partition] = []
    /// Nil on an RDB disk until a partition is entered. A raw hardfile has its
    /// one volume from the start.
    private var mounted: (partition: Int, store: FileBlockStore, volume: AmigaVolume)?
    private let fileSize: Int

    var isPartitioned: Bool { !partitions.isEmpty }

    init(url: URL) throws {
        self.url = url
        self.canWrite = FileManager.default.isWritableFile(atPath: url.path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        self.fileSize = values.fileSize ?? 0
        guard fileSize >= 4096 else { throw DiskImageError.unsupportedFormat }

        partitions = try Self.readRigidDiskBlock(url: url)
        if partitions.isEmpty {
            // No partition table, so the whole file is one volume.
            let store = try FileBlockStore(url: url, blockSize: 512)
            mounted = (0, store, try AmigaVolume(store: store))
        }
    }

    // MARK: - The partition table

    /// The Rigid Disk Block sits in one of the first sixteen blocks, and its
    /// partition entries are a chain from there.
    private static func readRigidDiskBlock(url: URL) throws -> [Partition] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        func long(_ o: Int) -> UInt32 {
            guard o >= 0, o + 4 <= data.count else { return 0 }
            let i = data.startIndex + o
            return (UInt32(data[i]) << 24) | (UInt32(data[i + 1]) << 16)
                 | (UInt32(data[i + 2]) << 8) | UInt32(data[i + 3])
        }

        // The block it sits in is stated in the block itself, so finding it has
        // to come first: it is within the first sixteen blocks of whatever that
        // size turns out to be, and stepping by the smallest of them finds it
        // wherever it is.
        var rdb = -1
        for candidate in 0..<32 where long(candidate * 512) == 0x5244_534B {    // "RDSK"
            rdb = candidate * 512
            break
        }
        guard rdb >= 0 else { return [] }

        // Every block number in an RDB counts in the drive's own blocks, which
        // are not always 512 bytes.
        let rdbBlockSize = max(512, Int(long(rdb + 16)))

        var out: [Partition] = []
        var next = Int(Int32(bitPattern: long(rdb + 28)))                       // partition list
        var seen = Set<Int>()
        while next > 0, next * rdbBlockSize + rdbBlockSize <= data.count, !seen.contains(next) {
            seen.insert(next)
            let part = next * rdbBlockSize
            guard long(part) == 0x5041_5254 else { break }                      // "PART"

            // The drive name is a BSTR: a length byte and then the characters.
            let nameLength = min(Int(data[data.startIndex + part + 36]), 31)
            var name = ""
            for i in 0..<nameLength {
                let c = data[data.startIndex + part + 37 + i]
                name.append(c >= 0x20 ? Character(UnicodeScalar(c)) : "_")
            }

            // The geometry lives in the DOS environment vector at +128, and the
            // block size there is counted in longs.
            let env = part + 128
            let blockSize = max(512, Int(long(env + 4)) * 4)
            let surfaces = Int(long(env + 12))
            let sectorsPerBlock = max(1, Int(long(env + 16)))
            let blocksPerTrack = Int(long(env + 20))
            let lowCyl = Int(long(env + 36))
            let highCyl = Int(long(env + 40))
            let dosType = long(env + 64)
            let perCylinder = surfaces * blocksPerTrack * sectorsPerBlock

            if perCylinder > 0, highCyl >= lowCyl {
                out.append(Partition(name: name.isEmpty ? "DH\(out.count)" : name,
                                     byteOffset: lowCyl * perCylinder * blockSize,
                                     blockSize: blockSize,
                                     blockCount: (highCyl - lowCyl + 1) * perCylinder,
                                     dosType: dosType))
            }
            next = Int(Int32(bitPattern: long(part + 16)))
        }
        return out
    }

    // MARK: - Mounting

    /// The volume a path is inside, and what is left of the path within it. On
    /// a partitioned disk the first component names the partition.
    private func resolve(_ path: [String]) throws -> (AmigaVolume, [String]) {
        guard isPartitioned else {
            guard let mounted else { throw DiskImageError.unsupportedFormat }
            return (mounted.volume, path)
        }
        guard let wanted = path.first else { throw DiskImageError.fileNotFound }
        guard let index = partitions.firstIndex(where: { $0.name == wanted }) else {
            throw DiskImageError.fileNotFound
        }
        let partition = partitions[index]
        guard partition.isAmigaDOS else {
            throw DiskImageError.corrupt("\(partition.name) is a \(partition.fileSystemName) partition, "
                                         + "which this cannot read")
        }
        if mounted?.partition != index {
            try saveMounted()
            let store = try FileBlockStore(url: url, blockSize: partition.blockSize,
                                           byteOffset: partition.byteOffset,
                                           blockCount: partition.blockCount)
            mounted = (index, store, try AmigaVolume(store: store))
        }
        guard let mounted else { throw DiskImageError.unsupportedFormat }
        return (mounted.volume, Array(path.dropFirst()))
    }

    private func saveMounted() throws {
        guard let mounted, mounted.store.isDirty else { return }
        try mounted.store.flush()
    }

    // MARK: - What the panel shows

    var listingStyle: ListingStyle { .text }
    var supportsDirectories: Bool { true }
    var usableBytesPerBlock: Int { mounted?.volume.dataBytesPerBlock ?? 512 }

    var diskName: [UInt8] {
        if isPartitioned, mounted == nil {
            return NameEncoding.latin1.bytes(url.deletingPathExtension().lastPathComponent)
        }
        return mounted?.volume.volumeName ?? []
    }
    var diskID: [UInt8]? { nil }
    var displayDiskName: String { NameEncoding.latin1.text(diskName) }
    func nameBytes(for text: String) -> [UInt8] {
        AmigaVolume.legalName(NameEncoding.latin1.bytes(text))
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    var formatName: String {
        let size = Self.sizeFormatter.string(fromByteCount: Int64(fileSize))
        if isPartitioned {
            return "HDF (\(size), RDB, \(partitions.count) partition\(partitions.count == 1 ? "" : "s"))"
        }
        return "HDF (\(size), \(mounted?.volume.variant.name ?? "?"))"
    }

    var blocksFree: Int { mounted?.volume.freeBlocks ?? 0 }

    var freeDescription: String {
        guard let mounted else {
            return Self.sizeFormatter.string(fromByteCount: Int64(fileSize))
        }
        let bytes = Int64(mounted.volume.freeBlocks) * Int64(mounted.store.blockSize)
        return Self.sizeFormatter.string(fromByteCount: bytes) + " free"
    }

    var hasUnsavedChanges: Bool { mounted?.store.isDirty ?? false }

    var integrityNote: String? {
        guard let mounted else { return nil }
        guard let root = try? mounted.store.block(mounted.volume.rootBlock) else {
            return "UNREADABLE ROOT BLOCK"
        }
        return AmigaVolume.long(root, 20) == AmigaVolume.headerChecksum(root, at: 20)
            ? nil : "ROOT BLOCK CHECKSUM"
    }

    // MARK: - Reading

    var entries: [ImageEntry] { (try? entries(at: [])) ?? [] }

    func entries(at path: [String]) throws -> [ImageEntry] {
        // The root of a partitioned disk is its partition list.
        if isPartitioned, path.isEmpty {
            return partitions.enumerated().map { index, partition in
                ImageEntry(slot: -(index + 1),
                           name: NameEncoding.latin1.bytes(partition.name),
                           type: .dir,
                           isSplat: false,
                           isLocked: !partition.isAmigaDOS,
                           blocks: partition.blockCount,
                           startTrack: 0,
                           startSector: 0,
                           entryOffset: -(index + 1),
                           encoding: .latin1,
                           byteSize: partition.blockCount * partition.blockSize,
                           isDirectory: true,
                           flags: partition.fileSystemName,
                           modified: nil)
            }
        }
        let (volume, rest) = try resolve(path)
        return try volume.entries(at: rest)
    }

    func read(_ entry: ImageEntry) throws -> Data { try read(entry, at: []) }

    func read(_ entry: ImageEntry, at path: [String]) throws -> Data {
        let (volume, _) = try resolve(path)
        return try volume.read(entry)
    }

    // MARK: - Writing

    func write(name: [UInt8], type: CBMFileType, data: Data) throws {
        try write(name: name, type: type, data: data, at: [])
    }

    func write(name: [UInt8], type: CBMFileType, data: Data, at path: [String]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let (volume, rest) = try resolve(path)
        try volume.createFile(name: name, data: data, in: volume.directoryBlock(at: rest))
    }

    func delete(_ entry: ImageEntry) throws { try delete(entry, at: []) }

    func delete(_ entry: ImageEntry, at path: [String]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        guard !(isPartitioned && path.isEmpty) else {
            throw DiskImageError.unsupportedFormat
        }
        let (volume, rest) = try resolve(path)
        try volume.delete(entry.slot, in: volume.directoryBlock(at: rest))
    }

    func rename(_ entry: ImageEntry, to name: [UInt8]) throws { try rename(entry, at: [], to: name) }

    func rename(_ entry: ImageEntry, at path: [String], to name: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        guard !(isPartitioned && path.isEmpty) else {
            throw DiskImageError.unsupportedFormat
        }
        let (volume, rest) = try resolve(path)
        try volume.rename(entry.slot, in: volume.directoryBlock(at: rest), to: name)
    }

    func makeDirectory(name: [UInt8], at path: [String]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        guard !(isPartitioned && path.isEmpty) else {
            throw DiskImageError.unsupportedFormat
        }
        let (volume, rest) = try resolve(path)
        try volume.createDirectory(name: name, in: volume.directoryBlock(at: rest))
    }

    func setLocked(_ entry: ImageEntry, locked: Bool) throws {
        guard canWrite, let mounted else { throw DiskImageError.readOnly }
        let block = try mounted.store.block(entry.slot)
        let bits = AmigaVolume.long(block, mounted.store.blockSize - 192)
        try mounted.volume.setProtection(entry.slot, bits: locked ? bits | 0x04 : bits & ~0x04)
    }

    func setDiskHeader(name: [UInt8], id: [UInt8]) throws {
        guard canWrite, let mounted else { throw DiskImageError.readOnly }
        try mounted.volume.setVolumeName(name)
    }

    /// A partition table is not a directory to rearrange, and a hash table has
    /// no order to rearrange either.
    var supportsEntryReordering: Bool { false }
    func moveEntry(_ entry: ImageEntry, by offset: Int) throws { throw DiskImageError.unsupportedFormat }
    func addDecorativeEntry(name: [UInt8], after entry: ImageEntry?) throws {
        throw DiskImageError.unsupportedFormat
    }

    func save() throws { try saveMounted() }

    func reload() throws {
        try mounted?.store.reload()
        if let mounted {
            self.mounted = (mounted.partition, mounted.store, try AmigaVolume(store: mounted.store))
        }
    }
}
