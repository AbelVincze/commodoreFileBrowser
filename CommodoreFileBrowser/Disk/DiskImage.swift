import Foundation

enum CBMFileType: UInt8, CaseIterable {
    case del = 0, seq = 1, prg = 2, usr = 3, rel = 4, cbm = 5, dir = 6

    var name: String {
        switch self {
        case .del: return "DEL"
        case .seq: return "SEQ"
        case .prg: return "PRG"
        case .usr: return "USR"
        case .rel: return "REL"
        case .cbm: return "CBM"
        case .dir: return "DIR"
        }
    }

    var fileExtension: String { name.lowercased() }

    static func from(fileExtension ext: String) -> CBMFileType {
        CBMFileType.allCases.first { $0.fileExtension == ext.lowercased() } ?? .prg
    }
}

/// One entry of a directory inside an image.
///
/// The Commodore fields carry the whole of a 1541 entry; the ones after them
/// are for formats that know more than CBM DOS does, and default to the
/// nothing a Commodore directory has to say on the subject.
struct ImageEntry: Identifiable, Hashable {
    var id: Int { slot }
    /// Position in the directory, used as a stable identity.
    var slot: Int
    /// Raw name bytes with the padding removed, in `encoding`.
    var name: [UInt8]
    var type: CBMFileType
    /// A file that was never closed properly - listed as `*PRG` by the drive.
    var isSplat: Bool
    /// `<` in a directory listing.
    var isLocked: Bool
    var blocks: Int
    var startTrack: UInt8
    var startSector: UInt8
    /// Byte offset of the 32 byte entry inside the image, for in-place edits.
    var entryOffset: Int

    /// How `name` reads as text.
    var encoding: NameEncoding = .petscii
    /// The exact length, where the format records one. A CBM directory only
    /// counts blocks, so the size of a file on it is known to 254 bytes.
    var byteSize: Int?
    /// A directory the panel can descend into.
    var isDirectory: Bool = false
    /// Permission bits as the platform writes them, e.g. `----rwed`. Empty
    /// where the format has none.
    var flags: String = ""
    var modified: Date?

    var displayName: String { encoding.text(name) }

    /// A name the file system will take, for copying the entry out or handing
    /// it to another application. A Commodore name gains the type as its
    /// extension, which is the only place that information can survive.
    var hostFileName: String {
        switch encoding {
        case .petscii: return PETSCII.hostFileName(name, type: type)
        case .latin1:
            var out = displayName
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            if out.isEmpty || out == "." || out == ".." { out = "unnamed" }
            return out
        }
    }
}

enum DiskImageError: LocalizedError {
    case unsupportedFormat
    case corrupt(String)
    case diskFull
    case directoryFull
    case readOnly
    case fileNotFound
    case nameExists(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Unsupported or damaged image format."
        case .corrupt(let why): return "The image is damaged: \(why)"
        case .diskFull: return "Not enough free blocks on the image."
        case .directoryFull: return "The directory of this image is full."
        case .readOnly: return "This image cannot be written to."
        case .fileNotFound: return "The file no longer exists in this image."
        case .nameExists(let n): return "\"\(n)\" already exists in this image."
        }
    }
}

/// A container that can be browsed as if it were a folder.
protocol DiskImage: AnyObject {
    var url: URL { get }
    /// Volume name in the format's own bytes, as shown in the header line.
    var diskName: [UInt8] { get }
    /// Disk ID + DOS type, e.g. `2A 2A`, or nil on a format that has none.
    var diskID: [UInt8]? { get }
    var entries: [ImageEntry] { get }
    var blocksFree: Int { get }
    var formatName: String { get }
    var canWrite: Bool { get }
    var hasUnsavedChanges: Bool { get }
    /// A short all-caps warning for the panel header, or nil when the
    /// container is internally consistent.
    var integrityNote: String? { get }

    func read(_ entry: ImageEntry) throws -> Data
    func write(name: [UInt8], type: CBMFileType, data: Data) throws
    func delete(_ entry: ImageEntry) throws
    func rename(_ entry: ImageEntry, to name: [UInt8]) throws
    func setLocked(_ entry: ImageEntry, locked: Bool) throws
    func setDiskHeader(name: [UInt8], id: [UInt8]) throws
    /// Swap an entry with its neighbour, for rearranging a directory.
    func moveEntry(_ entry: ImageEntry, by offset: Int) throws
    func addDecorativeEntry(name: [UInt8], after entry: ImageEntry?) throws
    func save() throws
    func reload() throws
}

/// What a format does not have to say for itself. The defaults describe a flat
/// Commodore directory drawn from the character ROM, which is what every format
/// here was until the Amiga ones arrived.
extension DiskImage {
    var listingStyle: ListingStyle { .petscii }
    /// Payload bytes in one block, for sizing an entry the directory only
    /// counts in blocks. 254 on a CBM disk: two of the 256 are the next link.
    var usableBytesPerBlock: Int { 254 }
    /// Free space as the panel footer says it.
    var freeDescription: String { "\(blocksFree) blocks free" }
    var supportsDirectories: Bool { false }

    /// `path` is the directory inside the image, empty for its root. A format
    /// without directories only ever sees the root and can ignore it.
    func entries(at path: [String]) throws -> [ImageEntry] { entries }
    func read(_ entry: ImageEntry, at path: [String]) throws -> Data { try read(entry) }
    func write(name: [UInt8], type: CBMFileType, data: Data, at path: [String]) throws {
        try write(name: name, type: type, data: data)
    }
    func delete(_ entry: ImageEntry, at path: [String]) throws { try delete(entry) }
    func rename(_ entry: ImageEntry, at path: [String], to name: [UInt8]) throws {
        try rename(entry, to: name)
    }
    func makeDirectory(name: [UInt8], at path: [String]) throws {
        throw DiskImageError.unsupportedFormat
    }
}

enum DiskImageFactory {
    static let supportedExtensions: Set<String> = ["d64", "d71", "d81", "t64"]

    static func isImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func open(_ url: URL) throws -> DiskImage {
        switch url.pathExtension.lowercased() {
        case "d64", "d71", "d81": return try CBMDiskImage(url: url)
        case "t64": return try T64Image(url: url)
        default: throw DiskImageError.unsupportedFormat
        }
    }
}
