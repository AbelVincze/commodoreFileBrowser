import Foundation

/// An Amiga floppy image: 880K double density, or 1760K high density, holding
/// one AmigaDOS volume. The image is small enough to keep in memory and write
/// back whole, the way the Commodore formats here do.
final class ADFImage: DiskImage {

    let url: URL
    private let store: MemoryBlockStore
    private var volume: AmigaVolume
    let canWrite: Bool

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
        // Writing arrives with the code that maintains a bitmap and a hash
        // chain; until then an ADF is opened to be read and copied out of.
        canWrite = false
    }

    // MARK: - What the panel shows

    var listingStyle: ListingStyle { .text }
    var supportsDirectories: Bool { true }
    var usableBytesPerBlock: Int { volume.dataBytesPerBlock }

    var diskName: [UInt8] { volume.volumeName }
    /// An Amiga volume has a name and no ID.
    var diskID: [UInt8]? { nil }

    var formatName: String {
        let size = store.blockCount == 3520 ? "1760K" : "880K"
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

    private(set) var hasUnsavedChanges = false

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

    func write(name: [UInt8], type: CBMFileType, data: Data) throws { throw DiskImageError.readOnly }
    func delete(_ entry: ImageEntry) throws { throw DiskImageError.readOnly }
    func rename(_ entry: ImageEntry, to name: [UInt8]) throws { throw DiskImageError.readOnly }
    func setLocked(_ entry: ImageEntry, locked: Bool) throws { throw DiskImageError.readOnly }
    func setDiskHeader(name: [UInt8], id: [UInt8]) throws { throw DiskImageError.readOnly }
    func moveEntry(_ entry: ImageEntry, by offset: Int) throws { throw DiskImageError.unsupportedFormat }
    func addDecorativeEntry(name: [UInt8], after entry: ImageEntry?) throws {
        throw DiskImageError.unsupportedFormat
    }

    func save() throws {
        guard hasUnsavedChanges else { return }
        try store.flush()
        hasUnsavedChanges = false
    }

    func reload() throws {
        try store.reload()
        volume = try AmigaVolume(store: store)
        hasUnsavedChanges = false
    }
}
