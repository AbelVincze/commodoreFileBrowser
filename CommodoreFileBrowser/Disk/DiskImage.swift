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

/// One entry of a Commodore directory.
struct CBMEntry: Identifiable, Hashable {
    var id: Int { slot }
    /// Position in the directory, used as a stable identity.
    var slot: Int
    /// Raw PETSCII name with the $A0 padding removed.
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

    var displayName: String { PETSCII.ascii(name) }
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

/// A Commodore container that can be browsed as if it were a folder.
protocol DiskImage: AnyObject {
    var url: URL { get }
    /// Disk name in raw PETSCII, as shown in the reverse-video header line.
    var diskName: [UInt8] { get }
    /// Disk ID + DOS type, e.g. `2A 2A`.
    var diskID: [UInt8] { get }
    var entries: [CBMEntry] { get }
    var blocksFree: Int { get }
    var formatName: String { get }
    var canWrite: Bool { get }
    var hasUnsavedChanges: Bool { get }
    /// A short all-caps warning for the panel header, or nil when the
    /// container is internally consistent.
    var integrityNote: String? { get }

    func read(_ entry: CBMEntry) throws -> Data
    func write(name: [UInt8], type: CBMFileType, data: Data) throws
    func delete(_ entry: CBMEntry) throws
    func rename(_ entry: CBMEntry, to name: [UInt8]) throws
    func setLocked(_ entry: CBMEntry, locked: Bool) throws
    func setDiskHeader(name: [UInt8], id: [UInt8]) throws
    /// Swap an entry with its neighbour, for rearranging a directory.
    func moveEntry(_ entry: CBMEntry, by offset: Int) throws
    func addDecorativeEntry(name: [UInt8], after entry: CBMEntry?) throws
    func save() throws
    func reload() throws
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
