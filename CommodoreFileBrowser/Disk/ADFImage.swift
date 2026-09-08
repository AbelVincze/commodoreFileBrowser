import Foundation

/// An Amiga floppy image: 880K double density, or 1760K high density, holding
/// one AmigaDOS volume. The image is small enough to keep in memory and write
/// back whole, the way the Commodore formats here do.
///
/// A DMS archive arrives here too, unpacked into memory. It is the same volume
/// once it is open — only where the bytes came from differs, and that it can
/// only be read.
final class ADFImage: DiskImage {

    let url: URL
    private let store: MemoryBlockStore
    private var volume: AmigaVolume
    let canWrite: Bool
    /// Set when the image was unpacked from an archive rather than read whole.
    private let archive: DMSArchive.Info?

    /// 1760 blocks of 512 on a double density disk, twice that on a high
    /// density one. Nothing else is an ADF.
    static let doubleDensity = 901_120
    static let highDensity = 1_802_240

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url)
        guard data.count == Self.doubleDensity || data.count == Self.highDensity else {
            throw DiskImageError.unsupportedFormat
        }
        store = MemoryBlockStore(bytes: [UInt8](data), blockSize: 512, url: url)
        volume = try AmigaVolume(store: store)
        canWrite = FileManager.default.isWritableFile(atPath: url.path)
        archive = nil
    }

    /// Open a DiskMasher archive by unpacking it into memory. Nothing is
    /// written back: the file on disk is the archive, not the disk.
    init(unpacking url: URL) throws {
        self.url = url
        let packed = [UInt8](try Data(contentsOf: url))
        let info = try DMSArchive.info(packed)
        let bytes = try DMSArchive.unpack(packed)
        store = MemoryBlockStore(bytes: bytes, blockSize: 512, url: nil)
        volume = try AmigaVolume(store: store)
        canWrite = false
        archive = info
    }

    /// The disk this archive holds, as an ADF would have it.
    static func unpackedImage(at url: URL) throws -> Data {
        Data(try DMSArchive.unpack([UInt8](try Data(contentsOf: url))))
    }

    // MARK: - What the panel shows

    var listingStyle: ListingStyle { .text }
    var supportsDirectories: Bool { true }
    var usableBytesPerBlock: Int { volume.dataBytesPerBlock }

    var diskName: [UInt8] { volume.volumeName }
    /// An Amiga volume has a name and no ID.
    var diskID: [UInt8]? { nil }
    var displayDiskName: String { NameEncoding.latin1.text(volume.volumeName) }
    func nameBytes(for text: String) -> [UInt8] {
        AmigaVolume.legalName(NameEncoding.latin1.bytes(text))
    }

    var formatName: String {
        let size = store.blockCount == 3520 ? "1760K" : "880K"
        if let archive {
            return "DMS (\(archive.modeNames)) · \(size), \(volume.variant.name)"
        }
        return "ADF (\(size), \(volume.variant.name))"
    }

    var blocksFree: Int { volume.freeBlocks }

    /// Spelled out rather than taken from the shared formatter, which renders
    /// an empty disk as "Zero KB".
    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    var freeDescription: String {
        let bytes = Int64(blocksFree) * Int64(store.blockSize)
        return Self.sizeFormatter.string(fromByteCount: bytes) + " free"
    }

    var hasUnsavedChanges: Bool { store.isDirty }

    /// The one thing worth checking on sight: a root block whose longs do not
    /// sum to zero has been written by something that got it wrong, and every
    /// pointer read out of it is suspect.
    var integrityNote: String? {
        guard let root = try? store.block(volume.rootBlock) else { return "UNREADABLE ROOT BLOCK" }
        let stored = AmigaVolume.long(root, 20)
        return stored == AmigaVolume.headerChecksum(root, at: 20) ? nil : "ROOT BLOCK CHECKSUM"
    }

    // MARK: - Reading

    var entries: [ImageEntry] { (try? volume.entries(at: [])) ?? [] }

    func entries(at path: [String]) throws -> [ImageEntry] { try volume.entries(at: path) }

    func read(_ entry: ImageEntry) throws -> Data { try volume.read(entry) }

    func read(_ entry: ImageEntry, at path: [String]) throws -> Data { try volume.read(entry) }

    // MARK: - Writing

    func write(name: [UInt8], type: CBMFileType, data: Data) throws {
        try write(name: name, type: type, data: data, at: [])
    }

    func write(name: [UInt8], type: CBMFileType, data: Data, at path: [String]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        try volume.createFile(name: name, data: data, in: volume.directoryBlock(at: path))
    }

    func delete(_ entry: ImageEntry) throws { try delete(entry, at: []) }

    func delete(_ entry: ImageEntry, at path: [String]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        try volume.delete(entry.slot, in: volume.directoryBlock(at: path))
    }

    func rename(_ entry: ImageEntry, to name: [UInt8]) throws { try rename(entry, at: [], to: name) }

    func rename(_ entry: ImageEntry, at path: [String], to name: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        try volume.rename(entry.slot, in: volume.directoryBlock(at: path), to: name)
    }

    func makeDirectory(name: [UInt8], at path: [String]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        try volume.createDirectory(name: name, in: volume.directoryBlock(at: path))
    }

    /// The write bit of the protection field, which is the nearest thing an
    /// Amiga file has to the 1541's lock.
    func setLocked(_ entry: ImageEntry, locked: Bool) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let block = try store.block(entry.slot)
        let bits = AmigaVolume.long(block, store.blockSize - 192)
        try volume.setProtection(entry.slot, bits: locked ? bits | 0x04 : bits & ~0x04)
    }

    /// A volume has a name and nothing to put an ID in, so the ID is dropped.
    func setDiskHeader(name: [UInt8], id: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        try volume.setVolumeName(name)
    }

    /// A hash table has no order to rearrange, and a directory has no room for
    /// a row that is not an entry.
    var supportsEntryReordering: Bool { false }
    func moveEntry(_ entry: ImageEntry, by offset: Int) throws { throw DiskImageError.unsupportedFormat }
    func addDecorativeEntry(name: [UInt8], after entry: ImageEntry?) throws {
        throw DiskImageError.unsupportedFormat
    }

    func save() throws { try store.flush() }

    func reload() throws {
        // An unpacked archive has nothing on disk to reload from.
        guard archive == nil else { return }
        try store.reload()
        volume = try AmigaVolume(store: store)
    }

    // MARK: - Formatting a blank image

    /// Write an empty 880K floppy image.
    static func createBlank(variant: AmigaVolume.Variant, name: [UInt8], at url: URL) throws {
        let bytes = try AmigaVolume.format(blockCount: doubleDensity / 512, variant: variant, name: name)
        try Data(bytes).write(to: url, options: .withoutOverwriting)
    }
}
