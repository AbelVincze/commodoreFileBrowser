import Foundation

/// Block-addressed storage under a file system.
///
/// A floppy image is small enough to hold whole and write back whole, which is
/// what every Commodore format here does. A hard disk image is not: it can run
/// to gigabytes, and rewriting the file to change one directory entry is not a
/// thing to do. Both shapes are the same to the file system above them, so the
/// choice lives here rather than in the code that reads blocks.
protocol BlockStore: AnyObject {
    var blockCount: Int { get }
    var blockSize: Int { get }
    var isDirty: Bool { get }

    func block(_ index: Int) throws -> [UInt8]
    func write(_ index: Int, _ bytes: [UInt8]) throws
    func flush() throws
    func reload() throws
}

extension BlockStore {
    /// True when `index` names a block that is actually in the store. Every
    /// pointer read out of an image is a number some other program wrote, so
    /// nothing here follows one without asking this first.
    func holds(_ index: Int) -> Bool { index >= 0 && index < blockCount }
}

/// The whole image in memory, written back in one piece.
final class MemoryBlockStore: BlockStore {
    let blockSize: Int
    private(set) var bytes: [UInt8]
    private(set) var isDirty = false
    /// Where to write on flush. Nil for an image that exists only in memory,
    /// which is what an archive unpacked for browsing is.
    private let url: URL?
    /// Bytes ahead of the first block, for a container that wraps the image in
    /// a header. Written back untouched.
    private let headerBytes: Int

    var blockCount: Int { (bytes.count - headerBytes) / blockSize }

    init(bytes: [UInt8], blockSize: Int, url: URL?, headerBytes: Int = 0) {
        self.bytes = bytes
        self.blockSize = blockSize
        self.url = url
        self.headerBytes = headerBytes
    }

    convenience init(url: URL, blockSize: Int) throws {
        self.init(bytes: [UInt8](try Data(contentsOf: url)), blockSize: blockSize, url: url)
    }

    private func range(_ index: Int) throws -> Range<Int> {
        guard holds(index) else { throw DiskImageError.corrupt("block \(index) is outside the image") }
        let start = headerBytes + index * blockSize
        return start..<(start + blockSize)
    }

    func block(_ index: Int) throws -> [UInt8] { Array(bytes[try range(index)]) }

    func write(_ index: Int, _ newBytes: [UInt8]) throws {
        let r = try range(index)
        guard newBytes.count == blockSize else {
            throw DiskImageError.corrupt("a block is \(blockSize) bytes, not \(newBytes.count)")
        }
        bytes.replaceSubrange(r, with: newBytes)
        isDirty = true
    }

    func flush() throws {
        guard isDirty, let url else { return }
        try Data(bytes).write(to: url, options: .atomic)
        isDirty = false
    }

    func reload() throws {
        guard let url else { return }
        bytes = [UInt8](try Data(contentsOf: url))
        isDirty = false
    }
}
