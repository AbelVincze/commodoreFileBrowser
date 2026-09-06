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

/// A window onto a file, read through a memory map and written a block at a
/// time. A hard disk image runs to hundreds of megabytes, so the blocks that
/// changed are the only ones that go back to disk — and a partition is the same
/// file seen through a smaller window.
final class FileBlockStore: BlockStore {
    let blockSize: Int
    let blockCount: Int
    /// Where this window starts in the file. A raw hardfile starts at zero; a
    /// partition starts wherever its first cylinder does.
    private let byteOffset: Int
    private let url: URL
    private var mapped: Data
    private var pending: [Int: [UInt8]] = [:]

    var isDirty: Bool { !pending.isEmpty }

    init(url: URL, blockSize: Int, byteOffset: Int = 0, blockCount: Int? = nil) throws {
        self.url = url
        self.blockSize = blockSize
        self.byteOffset = byteOffset
        self.mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        let available = (mapped.count - byteOffset) / blockSize
        self.blockCount = min(blockCount ?? available, max(0, available))
        guard self.blockCount > 0 else { throw DiskImageError.unsupportedFormat }
    }

    func block(_ index: Int) throws -> [UInt8] {
        guard holds(index) else { throw DiskImageError.corrupt("block \(index) is outside the image") }
        if let waiting = pending[index] { return waiting }
        let start = mapped.startIndex + byteOffset + index * blockSize
        return [UInt8](mapped[start..<(start + blockSize)])
    }

    func write(_ index: Int, _ bytes: [UInt8]) throws {
        guard holds(index) else { throw DiskImageError.corrupt("block \(index) is outside the image") }
        guard bytes.count == blockSize else {
            throw DiskImageError.corrupt("a block is \(blockSize) bytes, not \(bytes.count)")
        }
        pending[index] = bytes
    }

    /// Seek to each changed block and put it back. Nothing else in the file is
    /// read, rewritten or moved.
    func flush() throws {
        guard !pending.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for index in pending.keys.sorted() {
            try handle.seek(toOffset: UInt64(byteOffset + index * blockSize))
            handle.write(Data(pending[index]!))
        }
        try handle.synchronize()
        pending.removeAll()
        mapped = try Data(contentsOf: url, options: .mappedIfSafe)
    }

    func reload() throws {
        pending.removeAll()
        mapped = try Data(contentsOf: url, options: .mappedIfSafe)
    }
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
