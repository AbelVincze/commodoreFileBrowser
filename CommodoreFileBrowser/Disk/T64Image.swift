import Foundation

/// T64 tape archives. The container is small and irregular in the wild, so it
/// is parsed into records and rewritten whole whenever it changes.
final class T64Image: DiskImage {

    private struct Record {
        var name: [UInt8]        // 16 raw PETSCII bytes
        var c64Type: UInt8       // usually $82 (closed PRG)
        var startAddress: UInt16
        var payload: Data        // file body, without the load address
    }

    let url: URL
    private var records: [Record] = []
    private var tapeName: [UInt8] = []
    private(set) var hasUnsavedChanges = false
    let canWrite: Bool

    /// Size on disk is the most useful thing a tape archive can report:
    /// it has no tracks and no block allocation.
    private var fileSize = 0
    var formatName: String {
        "T64 tape · \(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))"
    }
    var integrityNote: String? { nil }
    var diskName: [UInt8] { PETSCII.padded16(PETSCII.trimPadding(tapeName)) }
    var diskID: [UInt8] { PETSCII.petscii(fromASCII: "t6 4t") }

    var entries: [CBMEntry] {
        records.enumerated().map { index, r in
            CBMEntry(slot: index,
                     name: PETSCII.trimPadding(r.name),
                     type: .prg,
                     isSplat: false,
                     isLocked: false,
                     blocks: max(1, (r.payload.count + 2 + 253) / 254),
                     startTrack: 0,
                     startSector: 0,
                     entryOffset: index)
        }
    }

    /// A tape has no block allocation; report the room left in the header.
    var blocksFree: Int { 0 }

    init(url: URL) throws {
        self.url = url
        self.canWrite = FileManager.default.isWritableFile(atPath: url.path)
        try parse(Data(contentsOf: url))
    }

    private func parse(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 64 else { throw DiskImageError.unsupportedFormat }
        fileSize = bytes.count

        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> Int {
            Int(bytes[o]) | (Int(bytes[o + 1]) << 8) | (Int(bytes[o + 2]) << 16) | (Int(bytes[o + 3]) << 24)
        }

        tapeName = PETSCII.trimPadding(Array(bytes[40..<64]).map { $0 == 0 ? 0x20 : $0 })

        let maxEntries = max(u16(34), u16(36))
        guard maxEntries > 0, 64 + maxEntries * 32 <= bytes.count else {
            throw DiskImageError.corrupt("bad entry count")
        }

        // Collect the raw directory first so sizes can be repaired from the
        // next record's offset when an end address is wrong (very common).
        var raw: [(name: [UInt8], type: UInt8, start: Int, end: Int, offset: Int)] = []
        for i in 0..<maxEntries {
            let e = 64 + i * 32
            guard bytes[e] != 0 else { continue }
            raw.append((name: Array(bytes[(e + 16)..<(e + 32)]).map { $0 == 0 ? 0x20 : $0 },
                        type: bytes[e + 1],
                        start: u16(e + 2),
                        end: u16(e + 4),
                        offset: u32(e + 8)))
        }

        let boundaries = (raw.map(\.offset) + [bytes.count]).sorted()
        records = raw.compactMap { r in
            guard r.offset >= 0, r.offset < bytes.count else { return nil }
            var size = r.end - r.start
            let nextBoundary = boundaries.first { $0 > r.offset } ?? bytes.count
            if size <= 0 || r.offset + size > bytes.count { size = nextBoundary - r.offset }
            size = max(0, min(size, bytes.count - r.offset))
            return Record(name: r.name,
                          c64Type: r.type == 0 ? 0x82 : r.type,
                          startAddress: UInt16(r.start & 0xFFFF),
                          payload: data.subdata(in: r.offset..<(r.offset + size)))
        }
    }

    func reload() throws {
        try parse(Data(contentsOf: url))
        hasUnsavedChanges = false
    }

    // MARK: - Contents

    /// Returns a PRG: the two byte load address followed by the body.
    func read(_ entry: CBMEntry) throws -> Data {
        guard entry.slot < records.count else { throw DiskImageError.fileNotFound }
        let r = records[entry.slot]
        var out = Data([UInt8(r.startAddress & 0xFF), UInt8(r.startAddress >> 8)])
        out.append(r.payload)
        return out
    }

    func write(name: [UInt8], type: CBMFileType, data: Data) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let clean = PETSCII.trimPadding(Array(name.prefix(16)))
        if records.contains(where: { PETSCII.trimPadding($0.name) == clean }) {
            throw DiskImageError.nameExists(PETSCII.ascii(clean))
        }
        let start: UInt16 = data.count >= 2
            ? UInt16(data[data.startIndex]) | (UInt16(data[data.startIndex + 1]) << 8)
            : 0x0801
        let payload = data.count >= 2 ? data.subdata(in: (data.startIndex + 2)..<data.endIndex) : Data()
        records.append(Record(name: PETSCII.padded16(clean).map { $0 == 0xA0 ? 0x20 : $0 },
                              c64Type: 0x82, startAddress: start, payload: payload))
        hasUnsavedChanges = true
    }

    func delete(_ entry: CBMEntry) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        guard entry.slot < records.count else { throw DiskImageError.fileNotFound }
        records.remove(at: entry.slot)
        hasUnsavedChanges = true
    }

    func rename(_ entry: CBMEntry, to name: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        guard entry.slot < records.count else { throw DiskImageError.fileNotFound }
        records[entry.slot].name = PETSCII.padded16(PETSCII.trimPadding(name)).map { $0 == 0xA0 ? 0x20 : $0 }
        hasUnsavedChanges = true
    }

    func setLocked(_ entry: CBMEntry, locked: Bool) throws {
        throw DiskImageError.readOnly
    }

    func setDiskHeader(name: [UInt8], id: [UInt8]) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        tapeName = PETSCII.trimPadding(Array(name.prefix(24)))
        hasUnsavedChanges = true
    }

    func moveEntry(_ entry: CBMEntry, by delta: Int) throws {
        guard canWrite else { throw DiskImageError.readOnly }
        let target = entry.slot + delta
        guard entry.slot < records.count, target >= 0, target < records.count else { return }
        records.swapAt(entry.slot, target)
        hasUnsavedChanges = true
    }

    func addDecorativeEntry(name: [UInt8], after entry: CBMEntry?) throws {
        throw DiskImageError.unsupportedFormat
    }

    // MARK: - Saving

    func save() throws {
        guard hasUnsavedChanges else { return }
        let maxEntries = max(30, records.count)
        var out = [UInt8](repeating: 0, count: 64 + maxEntries * 32)

        for (i, b) in Array("C64S tape image file".utf8).enumerated() { out[i] = b }
        out[32] = 0x00; out[33] = 0x02                       // version $0200
        out[34] = UInt8(maxEntries & 0xFF); out[35] = UInt8(maxEntries >> 8)
        out[36] = UInt8(records.count & 0xFF); out[37] = UInt8(records.count >> 8)
        var description = PETSCII.trimPadding(tapeName)
        if description.isEmpty { description = PETSCII.petscii(fromASCII: "tape") }
        for i in 0..<24 { out[40 + i] = i < description.count ? description[i] : 0x20 }

        var body = Data()
        var offset = out.count
        for (i, r) in records.enumerated() {
            let e = 64 + i * 32
            let end = Int(r.startAddress) + r.payload.count
            out[e] = 1
            out[e + 1] = r.c64Type
            out[e + 2] = UInt8(r.startAddress & 0xFF); out[e + 3] = UInt8(r.startAddress >> 8)
            out[e + 4] = UInt8(end & 0xFF); out[e + 5] = UInt8((end >> 8) & 0xFF)
            out[e + 8] = UInt8(offset & 0xFF)
            out[e + 9] = UInt8((offset >> 8) & 0xFF)
            out[e + 10] = UInt8((offset >> 16) & 0xFF)
            out[e + 11] = UInt8((offset >> 24) & 0xFF)
            let padded = PETSCII.padded16(PETSCII.trimPadding(r.name))
            for j in 0..<16 { out[e + 16 + j] = padded[j] == 0xA0 ? 0x20 : padded[j] }
            body.append(r.payload)
            offset += r.payload.count
        }

        var data = Data(out)
        data.append(body)
        try data.write(to: url, options: .atomic)
        hasUnsavedChanges = false
    }
}
