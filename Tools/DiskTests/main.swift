import Foundation
import AppKit
import CryptoKit
setbuf(stdout, nil)

let scratch = NSTemporaryDirectory()
var failures = 0
extension Collection { func allMatch(_ p: (Element) -> Bool) -> Bool { !contains { !p($0) } } }
func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
    if !cond { failures += 1 }
}

func dump(_ path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        let img = try DiskImageFactory.open(url)
        print("\n=== \(url.lastPathComponent) — \(img.formatName)")
        print("  header: \"\(PETSCII.ascii(PETSCII.trimPadding(img.diskName)))\" \(PETSCII.ascii(img.diskID ?? []))")
        for e in img.entries.prefix(8) {
            print(String(format: "  %4d \"%@\" %@%@%@", e.blocks, e.displayName,
                         e.isSplat ? "*" : " ", e.type.name, e.isLocked ? "<" : ""))
        }
        if img.entries.count > 8 { print("  … \(img.entries.count - 8) more") }
        print("  \(img.entries.count) entries, \(img.blocksFree) blocks free")
        // Every file must read back with a plausible size for its block count.
        for e in img.entries where e.type != .del {
            let d = try img.read(e)
            guard e.blocks > 0 else {
                // Scene disks fake the block count; only the chain has to be readable.
                check(true, "read \(e.displayName): \(d.count) bytes (block count faked)")
                continue
            }
            let lo = max(0, (e.blocks - 1) * 254 - 2), hi = e.blocks * 254
            check(d.count >= lo && d.count <= hi, "read \(e.displayName): \(d.count) bytes fits \(e.blocks) blocks")
        }
    } catch {
        print("  FAIL open \(path): \(error)")
        failures += 1
    }
}

for f in ["ace_2.d64", "cbmcmd23.d64", "o-tech-people.d64", "maccdata1.d81", "krakout.t64"] {
    dump("sample_images/\(f)")
}

// --- Format, write, reload, verify ------------------------------------------
print("\n=== blank image round trip")
for kind in CBMDiskImage.BlankFormat.allCases {
    let path = "\(scratch)/blank.\(kind.fileExtension)"
    try? FileManager.default.removeItem(atPath: path)
    let url = URL(fileURLWithPath: path)
    do {
        try CBMDiskImage.createBlank(kind, name: PETSCII.petscii(fromASCII: "test disk"),
                                     id: PETSCII.petscii(fromASCII: "01"), at: url)
        let img = try CBMDiskImage(url: url)
        let expected = [CBMDiskImage.BlankFormat.d64: 664, .d67: 670, .d71: 1328,
                        .d81: 3160, .d80: 2052, .d82: 4133][kind]!
        check(img.blocksFree == expected, "\(kind.rawValue) fresh format: \(img.blocksFree) blocks free (want \(expected))")
        check(img.entries.isEmpty, "\(kind.rawValue) fresh directory is empty")
        check(PETSCII.ascii(PETSCII.trimPadding(img.diskName)) == "test disk", "\(kind.rawValue) disk name")

        // Write a spread of sizes, including ones that cross a block boundary.
        var written: [String: Data] = [:]
        for (i, size) in [1, 253, 254, 255, 508, 20000].enumerated() {
            var payload = Data([0x01, 0x08])
            payload.append(contentsOf: (0..<size).map { UInt8(($0 &* 7 &+ i) & 0xFF) })
            let name = PETSCII.cbmName(fromASCII: "file \(i)")
            try img.write(name: name, type: .prg, data: payload)
            written[PETSCII.ascii(name)] = payload
        }
        try img.save()

        let reread = try CBMDiskImage(url: url)
        check(reread.entries.count == written.count, "\(kind.rawValue) \(reread.entries.count) entries after write")
        for e in reread.entries {
            let got = try reread.read(e)
            check(got == written[e.displayName], "\(kind.rawValue) \(e.displayName) round trips (\(got.count) bytes)")
        }

        // Delete everything and the disk should be empty again.
        for e in reread.entries { try reread.delete(e) }
        check(reread.blocksFree == expected, "\(kind.rawValue) all blocks reclaimed after delete (\(reread.blocksFree))")

        // Rename, lock, rearrange.
        try reread.write(name: PETSCII.cbmName(fromASCII: "aaa"), type: .prg, data: Data([0x01, 0x08, 9, 9]))
        try reread.write(name: PETSCII.cbmName(fromASCII: "bbb"), type: .seq, data: Data([1, 2, 3]))
        try reread.rename(reread.entries[0], to: PETSCII.cbmName(fromASCII: "renamed"))
        check(reread.entries[0].displayName == "renamed", "\(kind.rawValue) rename")
        try reread.moveEntry(reread.entries[0], by: 1)
        check(reread.entries[0].displayName == "bbb" && reread.entries[1].displayName == "renamed",
              "\(kind.rawValue) reorder")
        try reread.addDecorativeEntry(name: PETSCII.cbmName(fromASCII: "---------"), after: reread.entries[0])
        check(reread.entries.count == 3 && reread.entries[1].type == .del, "\(kind.rawValue) decorative DEL entry")
        try reread.setDiskHeader(name: PETSCII.cbmName(fromASCII: "new name"), id: PETSCII.petscii(fromASCII: "2B"))
        try reread.save()
        let third = try CBMDiskImage(url: url)
        check(PETSCII.ascii(PETSCII.trimPadding(third.diskName)) == "new name", "\(kind.rawValue) header edit persists")
        check(third.entries.count == 3, "\(kind.rawValue) 3 entries persist")

        // --- Byte level directory editing --------------------------------
        // The whole printed header, graphics and all, and the figure the
        // listing ends on: what a decorated directory is made of.
        var raw = third.headerFieldBytes
        check(raw.count == CBMDiskImage.headerFieldLength, "\(kind.rawValue) header field is 23 bytes")
        raw[0] = 0xA0          // an early shifted space closes the quote
        raw[1] = 0xB0          // and graphics follow it
        raw[16] = 0xA6
        raw[17] = 0xA7
        raw[20] = 0xB1
        try third.setHeaderFieldBytes(raw)

        let decorated = PETSCII.padded16(PETSCII.petscii(fromASCII: "hi"))
            .enumerated().map { $0.offset == 4 ? UInt8(0xB2) : $0.element }
        try third.setEntryFields(third.entries[0], name: decorated, blocks: 1541)
        try third.addDecorativeEntry(name: decorated, blocks: 999, after: third.entries[0])
        try third.setBlocksFree(17)
        check(third.blocksFree == 17, "\(kind.rawValue) blocks free forced to 17 (\(third.blocksFree))")
        try third.setBlocksFree(third.maximumBlocksFree + 100)
        check(third.blocksFree == third.maximumBlocksFree,
              "\(kind.rawValue) and clamped to a blank disk (\(third.blocksFree))")
        try third.setBlocksFree(17)
        try third.save()

        let fourth = try CBMDiskImage(url: url)
        check(fourth.headerFieldBytes == raw, "\(kind.rawValue) the header field survives byte for byte")
        check(fourth.rawName(of: fourth.entries[0]) == decorated,
              "\(kind.rawValue) the name field survives past the quote")
        check(fourth.entries[0].blocks == 1541, "\(kind.rawValue) a faked block count persists")
        check(fourth.entries[1].type == .del && fourth.entries[1].blocks == 999,
              "\(kind.rawValue) a DEL entry carries its own block count")
        check(fourth.blocksFree == 17, "\(kind.rawValue) the forced free count persists")
        // The line the panel draws must show what was written, quote and all.
        let line = PanelModel.headerLine(for: fourth)
        check(line.count == 2 + 18 + 6, "\(kind.rawValue) header line is the full printed field")
        check(line[4] == 0xB0 && line[20] == 0xA7 && line[23] == 0xB1,
              "\(kind.rawValue) header line draws the pad bytes as stored")
        let row = PanelModel.listingLine(for: fourth.entries[0])
        check(row[5] == 0x22 && row[8] == 0x22 && row[10] == 0xB2,
              "\(kind.rawValue) the row closes its quote on the shifted space")
    } catch {
        print("  FAIL \(kind.rawValue): \(error)")
        failures += 1
    }
}

// --- Fill a disk completely --------------------------------------------------
// --- The drives beyond the 1541 --------------------------------------------
print("\n=== other Commodore geometries")
do {
    // Sizes are what a drive of each kind wrote, and the free count is what it
    // reported on a fresh disk. Both were checked against VICE's own c1541.
    for (kind, size, free) in [(CBMDiskImage.BlankFormat.d67, 176_640, 670),
                               (.d80, 533_248, 2052),
                               (.d82, 1_066_496, 4133)] {
        let url = URL(fileURLWithPath: "\(scratch)/geo.\(kind.fileExtension)")
        try? FileManager.default.removeItem(at: url)
        try CBMDiskImage.createBlank(kind, name: PETSCII.petscii(fromASCII: "test disk"),
                                     id: PETSCII.petscii(fromASCII: "01"), at: url)
        let bytes = try Data(contentsOf: url).count
        check(bytes == size, "\(kind.rawValue) is \(bytes) bytes (want \(size))")
        let img = try CBMDiskImage(url: url)
        check(img.blocksFree == free, "\(kind.rawValue) fresh: \(img.blocksFree) blocks free (want \(free))")
        check(img.integrityNote == nil, "\(kind.rawValue) BAM agrees with the directory")
        check(PETSCII.ascii(PETSCII.trimPadding(img.diskName)) == "test disk", "\(kind.rawValue) names its disk")

        // The last track has to be inside the BAM, which is the thing four
        // blocks of allocation bitmap on a D82 could most easily get wrong.
        var payload = Data([0x01, 0x08])
        payload.append(contentsOf: (0..<600).map { UInt8($0 & 0xFF) })
        try img.write(name: PETSCII.cbmName(fromASCII: "hello"), type: .prg, data: payload)
        try img.save()
        let reread = try CBMDiskImage(url: url)
        check(try reread.read(reread.entries[0]) == payload, "\(kind.rawValue) round trips a file")
        check(reread.blocksFree == free - 3, "\(kind.rawValue) spent 3 blocks on it")
        check(reread.integrityNote == nil, "\(kind.rawValue) still consistent after a write")
    }

    // A PET header points at the BAM rather than at the directory, so finding
    // the directory means ignoring that pointer rather than following it.
    let pet = try CBMDiskImage(url: URL(fileURLWithPath: "\(scratch)/geo.d80"))
    check(pet.entries.count == 1 && pet.entries[0].displayName == "hello",
          "the 8050 directory is found past the BAM the header points at")
    check(PETSCII.ascii(pet.diskID ?? []) == "01 2c", "and the 8050 writes DOS type 2C")

    // DOS 1 numbered its version and left the type bytes blank.
    let dos1 = try Data(contentsOf: URL(fileURLWithPath: "\(scratch)/geo.d67"))
    let header = 17 * 21 * 256
    check(dos1[header + 2] == 0x01, "a 2040 disk carries DOS version 1")
    check(dos1[header + 165] == 0x20 && dos1[header + 166] == 0xA0, "and no DOS type after its ID")

    // An X64 is a D64 behind a 64 byte header: same contents, and the header
    // has to survive being written through.
    let source = URL(fileURLWithPath: "sample_images/cbmcmd23.d64")
    var head = [UInt8](repeating: 0, count: 64)
    head[0] = 0x43; head[1] = 0x15; head[2] = 0x41; head[3] = 0x64
    head[4] = 1; head[5] = 2; head[6] = 1; head[7] = 35
    let xurl = URL(fileURLWithPath: "\(scratch)/wrapped.x64")
    try? FileManager.default.removeItem(at: xurl)
    try (Data(head) + Data(contentsOf: source)).write(to: xurl)
    let x = try CBMDiskImage(url: xurl)
    let plain = try CBMDiskImage(url: source)
    check(x.formatName.hasPrefix("X64"), "an X64 says what it is: \(x.formatName)")
    check(x.entries.map(\.displayName) == plain.entries.map(\.displayName),
          "and lists the same \(x.entries.count) files as the D64 it wraps")
    check(try x.read(x.entries[0]) == plain.read(plain.entries[0]), "with the same bytes in them")
    check(x.blocksFree == plain.blocksFree, "and the same \(x.blocksFree) blocks free")
    try x.write(name: PETSCII.cbmName(fromASCII: "added"), type: .prg, data: Data([1, 8, 9, 9]))
    try x.save()
    let after = try Data(contentsOf: xurl)
    check(Array(after.prefix(8)) == Array(head.prefix(8)), "the X64 header survives a write")
    check(after.count == 64 + 174_848, "and the body is still a whole D64")
} catch {
    print("  FAIL other geometries: \(error)"); failures += 1
}

print("\n=== disk full handling")
do {
    let path = "\(scratch)/full.d64"
    try? FileManager.default.removeItem(atPath: path)
    let url = URL(fileURLWithPath: path)
    try CBMDiskImage.createBlank(.d64, name: PETSCII.petscii(fromASCII: "full"), id: [0x30, 0x31], at: url)
    let img = try CBMDiskImage(url: url)
    var count = 0
    while true {
        do {
            try img.write(name: PETSCII.cbmName(fromASCII: "f\(count)"), type: .prg,
                          data: Data(repeating: 0x41, count: 2540))
            count += 1
        } catch { break }
    }
    check(count > 60, "wrote \(count) x 10 block files before running out")
    check(img.blocksFree >= 0, "free count stays sane: \(img.blocksFree)")
    // Every file must still read back correctly on a packed disk.
    var allGood = true
    for e in img.entries where try! img.read(e).count != 2540 { allGood = false }
    check(allGood, "all files on a packed disk read back at full length")
} catch {
    print("  FAIL disk-full: \(error)"); failures += 1
}

// --- T64 -------------------------------------------------------------------
print("\n=== T64 round trip")
do {
    let src = try T64Image(url: URL(fileURLWithPath: "sample_images/krakout.t64"))
    let original = try src.entries.map { try src.read($0) }
    let path = "\(scratch)/out.t64"
    try? FileManager.default.removeItem(atPath: path)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0, count: 64))
    // Build a fresh archive by copying every record across.
    var header = [UInt8](repeating: 0, count: 64 + 30 * 32)
    for (i, b) in Array("C64S tape image file".utf8).enumerated() { header[i] = b }
    header[32] = 0; header[33] = 2; header[34] = 30; header[36] = 0
    try Data(header).write(to: URL(fileURLWithPath: path))
    let dst = try T64Image(url: URL(fileURLWithPath: path))
    for (i, e) in src.entries.enumerated() {
        try dst.write(name: e.name, type: .prg, data: original[i])
    }
    try dst.save()
    let reread = try T64Image(url: URL(fileURLWithPath: path))
    check(reread.entries.count == src.entries.count, "\(reread.entries.count) records copied")
    var ok = true
    for (i, e) in reread.entries.enumerated() where try! reread.read(e) != original[i] { ok = false }
    check(ok, "every T64 record round trips byte for byte")
    try reread.delete(reread.entries[0])
    try reread.save()
    let after = try T64Image(url: URL(fileURLWithPath: path))
    check(after.entries.count == src.entries.count - 1, "T64 delete")
    if let first = after.entries.first {
        check(try after.read(first) == original[1], "remaining T64 record still intact after delete")
    }
} catch {
    print("  FAIL t64: \(error)"); failures += 1
}

// --- Editing an image is a transaction -------------------------------------
// Edits live in memory. Walking up to the parent commits them; leaving with
// Esc (keepChanges: false) throws them away and never touches the file.
print("\n=== deferred save")
do {
    let path = "\(scratch)/txn.d64"
    try? FileManager.default.removeItem(atPath: path)
    try FileManager.default.copyItem(atPath: "sample_images/cbmcmd23.d64", toPath: path)
    let url = URL(fileURLWithPath: path)
    let folder = url.deletingLastPathComponent()
    let originalCount = try CBMDiskImage(url: url).entries.count

    func openPanel() -> PanelModel {
        let panel = PanelModel(side: .left)
        panel.navigate(to: .image(url))
        return panel
    }

    // Edit, then confirm nothing reached the file yet.
    var panel = openPanel()
    check(panel.hasUnsavedChanges == false, "a freshly opened image is clean")
    try panel.image!.delete(panel.image!.entries[0])
    check(panel.hasUnsavedChanges, "the panel reports the pending edit")
    check(try CBMDiskImage(url: url).entries.count == originalCount,
          "the file on disk is untouched while editing")

    // Esc: leave without saving.
    panel.goUp(keepChanges: false)
    check(panel.location == .directory(folder), "Esc lands in the parent folder")
    check(try CBMDiskImage(url: url).entries.count == originalCount,
          "discarding leaves the image exactly as it was")

    // Normal exit: commit.
    panel = openPanel()
    try panel.image!.delete(panel.image!.entries[0])
    try panel.image!.write(name: PETSCII.cbmName(fromASCII: "added"), type: .prg, data: Data([0x01, 0x08, 1, 2, 3]))
    panel.goUp(keepChanges: true)
    let saved = try CBMDiskImage(url: url)
    check(saved.entries.count == originalCount, "walking up to the parent wrote the edits")
    check(saved.entries.contains { $0.displayName == "added" }, "the added file survived the save")

    // A rebuild after an operation must not re-read the untouched file.
    panel = openPanel()
    try panel.image!.write(name: PETSCII.cbmName(fromASCII: "pending"), type: .prg, data: Data([0x01, 0x08, 9]))
    panel.refresh()
    check(panel.hasUnsavedChanges, "refresh keeps the pending edits")
    check(panel.items.contains { $0.title == "pending" }, "refresh redraws them from memory")
    panel.goUp(keepChanges: false)
    check(try !CBMDiskImage(url: url).entries.contains { $0.displayName == "pending" },
          "and they are still discardable afterwards")
} catch {
    print("  FAIL deferred save: \(error)"); failures += 1
}

// --- Navigation memory ------------------------------------------------------
print("\n=== navigation")
do {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: scratch).appendingPathComponent("nav")
    try? fm.removeItem(at: root)
    for sub in ["alpha/deep", "beta", "gamma"] {
        try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    for f in ["one.txt", "two.txt", "three.txt"] {
        try Data("x".utf8).write(to: root.appendingPathComponent("alpha").appendingPathComponent(f))
    }
    UserDefaults.standard.removeObject(forKey: "panel.left.volumeFolders")

    let panel = PanelModel(side: .left)
    panel.navigate(to: .directory(root))
    check(panel.cursor == 0, "entering a folder starts on the first row (..)")

    // Descend into alpha.
    guard let alphaIndex = panel.items.firstIndex(where: { $0.title == "alpha" }) else {
        throw DiskImageError.fileNotFound
    }
    panel.moveCursor(to: alphaIndex)
    panel.open()
    func at(_ url: URL) -> Bool {
        panel.location.url?.standardizedFileURL.path == url.standardizedFileURL.path
    }
    check(at(root.appendingPathComponent("alpha")), "entered alpha")
    check(panel.cursor == 0, "first visit to alpha starts on ..")

    // Park the cursor on a file, then walk out.
    guard let twoIndex = panel.items.firstIndex(where: { $0.title == "two.txt" }) else {
        throw DiskImageError.fileNotFound
    }
    panel.moveCursor(to: twoIndex)
    panel.goUp()
    check(at(root), "back in the parent")
    check(panel.currentItem?.title == "alpha", "cursor is on the folder we came out of")

    // Going back in must restore the cursor, not reset it.
    panel.open()
    check(panel.currentItem?.title == "two.txt", "returning to alpha restores the cursor")

    // Deeper, then out twice, then back in twice.
    panel.moveCursor(to: panel.items.firstIndex { $0.title == "deep" } ?? 0)
    panel.open()
    check(panel.cursor == 0, "first visit to deep starts on ..")
    panel.goUp(); panel.goUp()
    check(at(root), "two levels back out")
    check(panel.currentItem?.title == "alpha", "cursor still on alpha")
    panel.open()
    check(panel.currentItem?.title == "deep", "alpha remembers the deeper folder now")

    // The right arrow only descends. On the `..` row it must do nothing,
    // where Return still walks out.
    panel.navigate(to: .directory(root.appendingPathComponent("alpha")))
    panel.moveCursor(to: 0)   // alpha already has a remembered cursor by now
    check(panel.currentItem?.kind == .parent, "cursor is on the .. row")
    panel.open(allowParent: false)
    check(at(root.appendingPathComponent("alpha")), "right arrow on .. stays put in a folder")
    panel.open()
    check(at(root), "Return on .. still goes up")

    // Same inside an image listing, which is where it was most annoying.
    let image = URL(fileURLWithPath: "sample_images/cbmcmd23.d64")
    panel.navigate(to: .image(image))
    check(panel.isImagePanel && panel.currentItem?.kind == .parent, "inside the image, cursor on ..")
    panel.open(allowParent: false)
    check(panel.isImagePanel, "right arrow does not leave the image")
    panel.moveCursor(to: 2)
    panel.open(allowParent: false)
    check(panel.isImagePanel, "right arrow on a Commodore file does nothing")
    panel.moveCursor(to: 0)
    panel.open()
    check(!panel.isImagePanel, "Return on .. leaves the image")

    panel.navigate(to: .directory(root.appendingPathComponent("alpha")))

    // Volumes: jump out, then come back to where we left off.
    let before = panel.location
    panel.goToVolumes()
    check(panel.location == .volumes, "jumped to the volume list")
    let volumeName = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    check(panel.currentItem?.title == volumeName, "cursor is on the volume we were in (\(volumeName ?? "?"))")
    panel.open()
    check(panel.location.url?.standardizedFileURL.path == before.url?.standardizedFileURL.path,
          "selecting the volume returns to the folder we left")
} catch {
    print("  FAIL navigation: \(error)"); failures += 1
}

/// The bare bones of an Amiga volume: enough of a boot block and a root block
/// for one to open, so that the parts that depend only on the file system
/// variant — the name hash, above all — can be exercised without a disk.
func blankVolumeBytes(international: Bool) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 1760 * 512)
    bytes[0] = 0x44; bytes[1] = 0x4F; bytes[2] = 0x53      // "DOS"
    bytes[3] = international ? 2 : 0
    let root = 880 * 512
    bytes[root + 3] = 2                                    // T_HEADER
    bytes[root + 511] = 1                                  // ST_ROOT
    return bytes
}

// --- Amiga volumes ----------------------------------------------------------
print("\n=== Amiga ADF")
do {
    // Real disks, when this machine has some. There is no ADF in sample_images
    // — an 880K image each is a lot to keep — so the checks that need one look
    // for a collection and say so when there is none.
    let floppies = NSString(string: "~/Emulation/Amiga/Floppys").expandingTildeInPath
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: floppies)) ?? [])
        .filter { $0.lowercased().hasSuffix(".adf") }.sorted()

    if names.isEmpty {
        print("  --   no ADF collection on this machine, skipping the disk checks")
    } else {
        var volumes = 0, loaders = 0, failures = 0
        var files = 0, wrongLength = 0, freeBlocksInUse = 0
        var headerBlocks = 0, badHeaderSum = 0
        var ofsBlocks = 0, ofsOutOfOrder = 0, badDataSum = 0

        for name in names {
            let url = URL(fileURLWithPath: "\(floppies)/\(name)")
            let image: ADFImage
            do { image = try ADFImage(url: url) } catch {
                if case DiskImageError.noFileSystem = error { loaders += 1 } else { failures += 1 }
                continue
            }
            volumes += 1
            let volume = try AmigaVolume(store: MemoryBlockStore(url: url, blockSize: 512))

            func walk(_ path: [String], _ depth: Int) {
                guard depth < 8, let list = try? image.entries(at: path) else { return }
                for entry in list {
                    if let block = try? volume.store.block(entry.slot) {
                        headerBlocks += 1
                        if AmigaVolume.long(block, 20) != AmigaVolume.headerChecksum(block, at: 20) {
                            badHeaderSum += 1
                        }
                    }
                    if entry.isDirectory { walk(path + [entry.displayName], depth + 1); continue }
                    guard let data = try? image.read(entry, at: path) else { continue }
                    files += 1
                    if data.count != entry.byteSize { wrongLength += 1 }
                    for block in (try? volume.dataBlocks(of: entry.slot)) ?? [] {
                        if (try? volume.isFree(block)) == true { freeBlocksInUse += 1 }
                        // An OFS data block names the file it belongs to and
                        // its own place in the file, so the order this reads
                        // them in can be checked against the blocks themselves.
                        guard !volume.variant.isFFS, let d = try? volume.store.block(block) else { continue }
                        ofsBlocks += 1
                        if AmigaVolume.signed(d, 4) != entry.slot { ofsOutOfOrder += 1 }
                        if AmigaVolume.long(d, 20) != AmigaVolume.headerChecksum(d, at: 20) { badDataSum += 1 }
                    }
                }
            }
            walk([], 0)
        }

        check(failures == 0, "\(names.count) disks: \(volumes) volumes, \(loaders) with no file system, \(failures) unexplained")
        check(volumes > 0, "at least one volume was read")
        check(wrongLength == 0, "\(files) files came out the length the directory states")
        check(freeBlocksInUse == 0, "no file holds a block the bitmap calls free")
        check(badHeaderSum == 0, "\(headerBlocks) header blocks pass their checksum")
        check(ofsOutOfOrder == 0, "\(ofsBlocks) OFS data blocks name the file they belong to")
        check(badDataSum == 0, "and pass their own checksum")
    }

    // Hashing is what finds a name in a directory, and the two rules disagree
    // exactly where a Latin-1 letter has an upper case form.
    let plain = try? AmigaVolume(store: MemoryBlockStore(bytes: blankVolumeBytes(international: false),
                                                        blockSize: 512, url: nil))
    let intl = try? AmigaVolume(store: MemoryBlockStore(bytes: blankVolumeBytes(international: true),
                                                       blockSize: 512, url: nil))
    if let plain, let intl {
        let lower = NameEncoding.latin1.bytes("test")
        let upper = NameEncoding.latin1.bytes("TEST")
        check(plain.hash(lower) == plain.hash(upper), "a name hashes the same in either case")
        let accented = NameEncoding.latin1.bytes("\u{e4}bc")     // ä
        let capital = NameEncoding.latin1.bytes("\u{c4}bc")      // Ä
        check(intl.hash(accented) == intl.hash(capital),
              "the international rule folds an accented letter")
        check(plain.hash(accented) != plain.hash(capital),
              "and the plain rule leaves it alone, as its file system does")
        check(plain.hash(NameEncoding.latin1.bytes("Startup-Sequence")) < 72,
              "a hash lands inside the table")
    } else {
        print("  FAIL could not build a volume to hash against")
        failures += 1
    }
} catch {
    print("  FAIL Amiga ADF: \(error)"); failures += 1
}

// --- Writing an Amiga volume ------------------------------------------------
print("\n=== Amiga ADF write")
for option in NewImageFormat.adf.options {
    let variant = NewImageFormat.amigaVariant(option)
    let tag = option.replacingOccurrences(of: " ", with: "_")
    let url = URL(fileURLWithPath: "\(scratch)/blank-\(tag).adf")
    try? FileManager.default.removeItem(at: url)
    do {
        try ADFImage.createBlank(variant: variant,
                                 name: NameEncoding.latin1.bytes("Test Disk"), at: url)
        let image = try ADFImage(url: url)
        // 1758 blocks, less the root and the bitmap, less one more for the
        // root's own cache on a file system that keeps one.
        let empty = variant.hasDirCache ? 1755 : 1756
        check(image.blocksFree == empty, "\(option) fresh: \(image.blocksFree) blocks free (want \(empty))")
        check(image.entries.isEmpty, "\(option) fresh volume is empty")
        check(image.displayDiskName == "Test Disk", "\(option) names its volume")
        check(image.integrityNote == nil, "\(option) root block checksum")

        // Sizes that straddle each boundary: an OFS data block holds 488 bytes
        // and an FFS one 512, and a pointer table runs out after 72 of them.
        var written: [String: Data] = [:]
        for (i, size) in [0, 1, 487, 488, 512, 513, 35_136, 36_865, 90_000].enumerated() {
            let payload = Data((0..<size).map { UInt8(($0 &* 31 &+ i) & 0xFF) })
            let name = "file\(i)"
            try image.write(name: NameEncoding.latin1.bytes(name), type: .prg, data: payload, at: [])
            written[name] = payload
        }
        try image.makeDirectory(name: NameEncoding.latin1.bytes("Drawer"), at: [])
        try image.makeDirectory(name: NameEncoding.latin1.bytes("Deeper"), at: ["Drawer"])
        try image.write(name: NameEncoding.latin1.bytes("buried"), type: .prg,
                        data: Data("hello from the bottom".utf8), at: ["Drawer", "Deeper"])
        try image.save()

        let reread = try ADFImage(url: url)
        check(reread.entries.count == written.count + 1, "\(option) \(reread.entries.count) entries after a save")
        var intact = true
        for entry in reread.entries where !entry.isDirectory {
            if try reread.read(entry, at: []) != written[entry.displayName] { intact = false }
        }
        check(intact, "\(option) every file round trips through a save and reopen")
        let buried = try reread.entries(at: ["Drawer", "Deeper"])
        check(buried.count == 1, "\(option) a file two directories down")
        check(String(decoding: try reread.read(buried[0], at: ["Drawer", "Deeper"]), as: UTF8.self)
              == "hello from the bottom", "\(option) and it reads back")
        check(reread.integrityNote == nil, "\(option) still consistent after writing")

        // A rename changes the hash, so the entry moves to a different chain
        // and has to be findable under the new name and gone under the old.
        if let target = reread.entries.first(where: { $0.displayName == "file3" }) {
            try reread.rename(target, at: [], to: NameEncoding.latin1.bytes("Renamed"))
            let names = reread.entries.map(\.displayName)
            check(names.contains("Renamed") && !names.contains("file3"),
                  "\(option) a rename moves the entry between hash chains")
            let moved = reread.entries.first { $0.displayName == "Renamed" }!
            check(try reread.read(moved, at: []) == written["file3"], "\(option) and its bytes are untouched")
            try reread.rename(moved, at: [], to: NameEncoding.latin1.bytes("file3"))
        } else {
            check(false, "\(option) could not find a file to rename")
        }

        // The cache AmigaDOS trusts over the directory has to agree with it.
        if variant.hasDirCache {
            let volume = try AmigaVolume(store: MemoryBlockStore(url: url, blockSize: 512))
            var agrees = true
            for path in [[], ["Drawer"], ["Drawer", "Deeper"]] {
                let listed = Set(try volume.entries(at: path).map(\.displayName))
                let cached = Set(try volume.cachedNames(of: volume.directoryBlock(at: path)))
                if listed != cached { agrees = false }
            }
            check(agrees, "\(option) the directory cache matches the directory")
        }

        // Emptying the volume has to hand back exactly what was taken.
        for entry in try reread.entries(at: ["Drawer", "Deeper"]) { try reread.delete(entry, at: ["Drawer", "Deeper"]) }
        for entry in try reread.entries(at: ["Drawer"]) { try reread.delete(entry, at: ["Drawer"]) }
        for entry in reread.entries { try reread.delete(entry, at: []) }
        check(reread.entries.isEmpty, "\(option) empty again")
        check(reread.blocksFree == empty, "\(option) all blocks reclaimed (\(reread.blocksFree))")
    } catch {
        print("  FAIL \(option): \(error)"); failures += 1
    }
}

// A directory with something in it must not go, the way AmigaDOS insists.
do {
    let url = URL(fileURLWithPath: "\(scratch)/notempty.adf")
    try? FileManager.default.removeItem(at: url)
    try ADFImage.createBlank(variant: NewImageFormat.amigaVariant("FFS"),
                             name: NameEncoding.latin1.bytes("Test"), at: url)
    let image = try ADFImage(url: url)
    try image.makeDirectory(name: NameEncoding.latin1.bytes("Drawer"), at: [])
    try image.write(name: NameEncoding.latin1.bytes("inside"), type: .prg,
                    data: Data([1, 2, 3]), at: ["Drawer"])
    do {
        try image.delete(image.entries[0], at: [])
        check(false, "a directory with a file in it was deleted anyway")
    } catch {
        check("\(error)".contains("still has something") || error is DiskImageError,
              "a directory is not deleted while something is in it")
    }
    // And a name that is already taken is refused.
    do {
        try image.write(name: NameEncoding.latin1.bytes("inside"), type: .prg,
                        data: Data([9]), at: ["Drawer"])
        check(false, "a duplicate name was accepted")
    } catch { check(true, "a name already in the directory is refused") }
} catch {
    print("  FAIL ADF rules: \(error)"); failures += 1
}

// --- Amiga hard disk images -------------------------------------------------
print("\n=== Amiga HDF")

/// A hardfile with a Rigid Disk Block and the partitions described, each one
/// formatted. Built here rather than kept as a sample: a useful one is
/// megabytes, and every field in it matters more than its contents do.
func makeHardfile(at url: URL, blockSize: Int,
                  partitions: [(name: String, cylinders: Int, dosType: UInt32)]) throws {
    let surfaces = 2, blocksPerTrack = 32
    let perCylinder = surfaces * blocksPerTrack
    let reserved = 2
    let total = reserved + partitions.reduce(0) { $0 + $1.cylinders }
    var bytes = [UInt8](repeating: 0, count: total * perCylinder * blockSize)
    func put(_ o: Int, _ v: Int) { AmigaVolume.setLong(&bytes, o, v) }

    put(0, 0x5244_534B)                              // "RDSK"
    put(4, 64); put(12, 7)
    put(16, blockSize); put(24, -1)
    put(28, 1)                                       // the partition list starts at block 1
    put(32, -1); put(36, -1)
    put(64, total); put(68, blocksPerTrack); put(72, surfaces)

    var lowCyl = reserved
    for (i, p) in partitions.enumerated() {
        let base = (1 + i) * blockSize
        put(base, 0x5041_5254)                       // "PART"
        put(base + 4, 64); put(base + 12, 7)
        put(base + 16, i + 1 < partitions.count ? 2 + i : -1)
        put(base + 20, 1)
        bytes[base + 36] = UInt8(p.name.count)
        for (j, c) in Array(p.name.utf8).enumerated() { bytes[base + 37 + j] = c }
        let env = base + 128
        put(env, 16); put(env + 4, blockSize / 4)
        put(env + 12, surfaces); put(env + 16, 1); put(env + 20, blocksPerTrack)
        put(env + 24, 2); put(env + 36, lowCyl); put(env + 40, lowCyl + p.cylinders - 1)
        put(env + 44, 30); put(env + 52, 0x7FFF_FFFF); put(env + 56, 0x7FFF_FFFE)
        put(env + 64, Int(p.dosType))

        if p.dosType & 0xFFFF_FF00 == 0x444F_5300,
           let variant = AmigaVolume.Variant(dosFlags: UInt8(p.dosType & 0xFF)) {
            let volume = try AmigaVolume.format(blockCount: p.cylinders * perCylinder,
                                                blockSize: blockSize, variant: variant,
                                                name: NameEncoding.latin1.bytes(p.name))
            let at = lowCyl * perCylinder * blockSize
            for (j, b) in volume.enumerated() { bytes[at + j] = b }
        }
        lowCyl += p.cylinders
    }
    try Data(bytes).write(to: url)
}

do {
    let url = URL(fileURLWithPath: "\(scratch)/rdb.hdf")
    try? FileManager.default.removeItem(at: url)
    try makeHardfile(at: url, blockSize: 512,
                     partitions: [("DH0", 80, 0x444F_5301),      // FFS
                                  ("DH1", 40, 0x444F_5300),      // OFS
                                  ("DH2", 20, 0x5346_5300)])     // SFS, which this cannot read

    let image = try HDFImage(url: url)
    check(image.isPartitioned, "the partition table was found")
    let listed = image.entries
    check(listed.count == 3, "all three partitions are listed")
    check(listed.allSatisfy(\.isDirectory), "and each is something to go into")
    check(listed.map(\.displayName) == ["DH0", "DH1", "DH2"], "named as the table names them")

    for name in ["DH0", "DH1"] {
        check(try image.entries(at: [name]).isEmpty, "\(name) starts empty")
        let payload = Data((0..<9000).map { UInt8($0 & 0xFF) })
        try image.write(name: NameEncoding.latin1.bytes("hello"), type: .prg, data: payload, at: [name])
        try image.makeDirectory(name: NameEncoding.latin1.bytes("Drawer"), at: [name])
        try image.write(name: NameEncoding.latin1.bytes("deep"), type: .prg,
                        data: Data("inside".utf8), at: [name, "Drawer"])
        try image.save()
        let written = try image.entries(at: [name]).first { $0.displayName == "hello" }!
        check(try image.read(written, at: [name]) == payload, "\(name) round trips a file")
    }

    // Reopened from disk, because the writes went a block at a time rather
    // than by rewriting the file.
    let again = try HDFImage(url: url)
    for name in ["DH0", "DH1"] {
        check(try again.entries(at: [name]).map(\.displayName).sorted() == ["Drawer", "hello"],
              "\(name) still holds both entries after reopening")
        check(try again.entries(at: [name, "Drawer"]).first?.displayName == "deep",
              "\(name) still holds the buried file, so the partitions kept out of each other's way")
    }
    do {
        _ = try again.entries(at: ["DH2"])
        check(false, "a partition this cannot read was opened anyway")
    } catch {
        check("\((error as? LocalizedError)?.errorDescription ?? "")".contains("SFS"),
              "a partition of another file system says so rather than being read as rubbish")
    }

    // A block number in an RDB counts in the drive's own blocks, which are not
    // always 512 bytes, and the file system tables scale with them too.
    let wideURL = URL(fileURLWithPath: "\(scratch)/rdb1024.hdf")
    try? FileManager.default.removeItem(at: wideURL)
    try makeHardfile(at: wideURL, blockSize: 1024, partitions: [("Work", 60, 0x444F_5301)])
    let wide = try HDFImage(url: wideURL)
    check(wide.isPartitioned, "a 1024 byte block hardfile is read")
    let big = Data((0..<50_000).map { UInt8(($0 &* 7) & 0xFF) })
    try wide.write(name: NameEncoding.latin1.bytes("wide"), type: .prg, data: big, at: ["Work"])
    try wide.save()
    let wideAgain = try HDFImage(url: wideURL)
    check(try wideAgain.read(wideAgain.entries(at: ["Work"])[0], at: ["Work"]) == big,
          "and round trips a 50 KB file through 1024 byte blocks")

    // The point of the whole block store: a hard disk is not rewritten to
    // change one directory entry.
    let probeURL = URL(fileURLWithPath: "\(scratch)/probe.hdf")
    try? FileManager.default.removeItem(at: probeURL)
    try makeHardfile(at: probeURL, blockSize: 512, partitions: [("DH0", 80, 0x444F_5301)])
    let before = try Data(contentsOf: probeURL)
    let probe = try HDFImage(url: probeURL)
    try probe.write(name: NameEncoding.latin1.bytes("one"), type: .prg, data: Data([1, 2, 3]), at: ["DH0"])
    try probe.save()
    let after = try Data(contentsOf: probeURL)
    check(before.count == after.count, "the file did not change size")
    var rewritten = 0
    for b in 0..<(before.count / 512) where before[(b * 512)..<(b * 512 + 512)] != after[(b * 512)..<(b * 512 + 512)] {
        rewritten += 1
    }
    check((1...12).contains(rewritten),
          "writing one file rewrote \(rewritten) blocks of \(before.count / 512), not the file")

    // And the hardfile on this machine, if there is one.
    let realPath = NSString(string: "~/Emulation/Amiga/harddisks/system.HDF").expandingTildeInPath
    if FileManager.default.fileExists(atPath: realPath) {
        let real = try HDFImage(url: URL(fileURLWithPath: realPath))
        check(!real.isPartitioned, "a raw hardfile is one volume with no partition table")
        check(!real.entries.isEmpty, "and lists its root: \(real.entries.count) entries")
        check(real.integrityNote == nil, "with a root block that checks out")
        var files = 0, wrongLength = 0
        func walk(_ path: [String], _ depth: Int) {
            guard depth < 3, let list = try? real.entries(at: path) else { return }
            for entry in list {
                if entry.isDirectory { walk(path + [entry.displayName], depth + 1); continue }
                guard let data = try? real.read(entry, at: path) else { continue }
                files += 1
                if data.count != entry.byteSize { wrongLength += 1 }
            }
        }
        walk([], 0)
        check(wrongLength == 0, "\(files) files on it come out the length it states")
    } else {
        print("  --   no hardfile on this machine, skipping the real one")
    }
} catch {
    print("  FAIL Amiga HDF: \(error)"); failures += 1
}

// --- DiskMasher archives ----------------------------------------------------
print("\n=== DMS")
do {
    // A track of a floppy, packed with no compression at all, is the one shape
    // that can be built here from nothing and checked without a real archive.
    func archive(tracks: [(number: Int, bytes: [UInt8])]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 56)
        out[0] = 0x44; out[1] = 0x4D; out[2] = 0x53; out[3] = 0x21          // "DMS!"
        out[16] = 0; out[17] = UInt8(tracks.first?.number ?? 0)
        out[18] = 0; out[19] = UInt8(tracks.last?.number ?? 0)
        let headerCRC = DMSArchive.crc(out[4..<54])
        out[54] = UInt8(headerCRC >> 8); out[55] = UInt8(headerCRC & 0xFF)

        for track in tracks {
            var header = [UInt8](repeating: 0, count: 20)
            header[0] = 0x54; header[1] = 0x52                               // "TR"
            header[2] = UInt8(track.number >> 8); header[3] = UInt8(track.number & 0xFF)
            let length = track.bytes.count
            for (at, value) in [(6, length), (8, length), (10, length)] {
                header[at] = UInt8(value >> 8); header[at + 1] = UInt8(value & 0xFF)
            }
            header[12] = 1                                                   // keep state
            header[13] = 0                                                   // stored
            let sum = DMSArchive.checksum(track.bytes)
            header[14] = UInt8(sum >> 8); header[15] = UInt8(sum & 0xFF)
            let dataCRC = DMSArchive.crc(track.bytes[0...])
            header[16] = UInt8(dataCRC >> 8); header[17] = UInt8(dataCRC & 0xFF)
            let headerCRC = DMSArchive.crc(header[0..<18])
            header[18] = UInt8(headerCRC >> 8); header[19] = UInt8(headerCRC & 0xFF)
            out += header + track.bytes
        }
        return out
    }

    let one = (0..<DMSArchive.trackBytes).map { UInt8(($0 &* 13 &+ 7) & 0xFF) }
    let two = (0..<DMSArchive.trackBytes).map { UInt8(($0 &* 5 &+ 1) & 0xFF) }
    let built = archive(tracks: [(0, one), (3, two)])

    check(DMSArchive.isArchive(built), "an archive is recognised by its magic")
    let details = try DMSArchive.info(built)
    check(details.modes == [.none], "and says which compressions it used")
    check(!details.isEncrypted, "and whether it is password protected")

    let image = try DMSArchive.unpack(built)
    check(image.count == 80 * DMSArchive.trackBytes, "unpacking gives a whole floppy")
    check(Array(image[0..<DMSArchive.trackBytes]) == one, "track 0 lands at the front")
    let third = 3 * DMSArchive.trackBytes
    check(Array(image[third..<(third + DMSArchive.trackBytes)]) == two, "track 3 lands where it belongs")
    check(image[DMSArchive.trackBytes..<third].allSatisfy { $0 == 0 }, "and the gap between them is empty")

    // Damage has to be caught rather than passed on as a disk.
    var damaged = built
    damaged[80] ^= 0xFF
    do { _ = try DMSArchive.unpack(damaged); check(false, "a damaged track was accepted") }
    catch { check(true, "a damaged track is refused") }

    var badHeader = built
    badHeader[20] ^= 0xFF
    do { _ = try DMSArchive.info(badHeader); check(false, "a damaged header was accepted") }
    catch { check(true, "a damaged archive header is refused") }

    // The real collection, when this machine has one. Every archive carries a
    // checksum of each track, so it grades its own homework.
    let root = NSString(string: "~/Emulation").expandingTildeInPath
    let archives = ((try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? [])
        .filter { $0.lowercased().hasSuffix(".dms") }
        .map { root + "/" + $0 }
        .sorted()
    if archives.isEmpty {
        print("  --   no DMS collection on this machine, skipping the real archives")
    } else {
        var unpacked = 0, refused = 0, volumes = 0, shortTracks = 0
        for path in archives {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
            guard let image = try? DMSArchive.unpack(bytes) else { refused += 1; continue }
            unpacked += 1
            if image.count % DMSArchive.trackBytes != 0 { shortTracks += 1 }
            if (try? ADFImage(unpacking: URL(fileURLWithPath: path))) != nil { volumes += 1 }
        }
        // xDMS, the reference unpacker, fails on the same handful: they are
        // archives that were damaged before they got here.
        check(unpacked >= archives.count - 5,
              "\(unpacked) of \(archives.count) archives unpack, every track passing its own checksum")
        check(shortTracks == 0, "every one of them comes out a whole number of tracks")
        check(volumes > 0, "\(volumes) of them hold a file system that mounts straight from the archive")
    }
} catch {
    print("  FAIL DMS: \(error)"); failures += 1
}

// --- The widened image model ------------------------------------------------
print("\n=== image model")
do {
    // A location inside an image carries the directory it is showing, and has
    // to survive being written to the defaults and read back.
    // Absolute, because a relative URL keeps its base and comparing one
    // against the absolute URL that comes back out of JSON never matches.
    let d64 = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("sample_images/cbmcmd23.d64")
    let deep = PanelLocation.image(d64, path: ["c", "devs"])
    check(PanelLocation.image(d64) == .image(d64, path: []), "the bare form is the root of the image")
    check(deep.imagePath == ["c", "devs"], "a location remembers the directory inside the image")
    let coded = try JSONDecoder().decode(PanelLocation.self,
                                         from: JSONEncoder().encode(deep))
    check(coded == deep, "and round trips through the defaults")

    // A Commodore entry names its host copy with the type as the extension; an
    // Amiga name is already a name the file system will take.
    let cbm = ImageEntry(slot: 0, name: PETSCII.cbmName(fromASCII: "my file"), type: .prg,
                         isSplat: false, isLocked: false, blocks: 2,
                         startTrack: 17, startSector: 0, entryOffset: 0)
    check(cbm.hostFileName == "my file.prg", "a CBM entry takes its type as an extension")
    check(cbm.displayName == "my file", "and reads back as it was written")
    let amiga = ImageEntry(slot: 0, name: NameEncoding.latin1.bytes("Startup-Sequence"), type: .prg,
                           isSplat: false, isLocked: false, blocks: 3,
                           startTrack: 0, startSector: 0, entryOffset: 0,
                           encoding: .latin1, byteSize: 1204, flags: "----rwed")
    check(amiga.hostFileName == "Startup-Sequence", "an Amiga name is already a host name")
    check(amiga.displayName == "Startup-Sequence", "and keeps the case it was given")
    check(NameEncoding.latin1.text([0xC4, 0x6E, 0x64]) == "Änd", "Latin-1 reads its high letters")
    check(NameEncoding.latin1.text([0x09, 0x41]) == "_A", "and refuses a control code a row")

    // The footer asks the image what it has free rather than testing its type.
    let disk = try CBMDiskImage(url: d64)
    check(disk.freeDescription == "\(disk.blocksFree) blocks free", "a disk reports blocks free")
    let tape = try T64Image(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("sample_images/krakout.t64"))
    check(tape.freeDescription == tape.formatName, "a tape reports its size instead")
    check(tape.diskID == nil, "a tape has no disk ID")
    check(PanelModel.headerLine(for: tape).contains(0x22),
          "the tape header line still quotes its name")
    check(PanelModel.headerLine(for: disk).count > PanelModel.headerLine(for: tape).count,
          "and is shorter than a disk's by the ID the tape does not have")

    // Rows on the file system now carry the modification date the column shows.
    let panel = PanelModel(side: .left)
    panel.navigate(to: .directory(URL(fileURLWithPath: "sample_images")))
    let d64Row = panel.items.first { $0.title == "cbmcmd23.d64" }
    check(d64Row?.modified != nil, "a file system row carries its modification date")
    check(d64Row?.kind == .diskImage, "and still knows it is an image")

    // Inside a Commodore image the rows are PETSCII and flat.
    panel.navigate(to: .image(d64))
    let row = panel.items.first { $0.kind.isInsideImage }
    check(row?.petsciiLine != nil, "a Commodore row is drawn from the character ROM")
    check(row?.kind == .imageFile, "and is a file, not a directory")
    check(row?.modified == nil && row?.flags.isEmpty == true,
          "with no date or protection bits, which a CBM directory does not keep")
} catch {
    print("  FAIL image model: \(error)"); failures += 1
}

// --- Bitmap layout ----------------------------------------------------------
print("\n=== bitmap layout")
do {
    // The forward mapping and the hover mapping must be exact inverses, for
    // every byte, under a spread of layouts including odd block widths.
    for raw in [BitmapLayout(blockWidth: 8, blockHeight: 8, displayWidth: 320),
                BitmapLayout(blockWidth: 24, blockHeight: 21, displayWidth: 192),
                BitmapLayout(blockWidth: 8, blockHeight: 1, displayWidth: 128),
                BitmapLayout(blockWidth: 13, blockHeight: 5, displayWidth: 200),
                BitmapLayout(blockWidth: 24, blockHeight: 21, displayWidth: 192, blockAlign: 64),
                BitmapLayout(blockWidth: 8, blockHeight: 8, displayWidth: 128, blockAlign: 16)] {
        let l = raw.normalized
        var ok = true
        for i in 0..<4000 {
            // Padding bytes have no pixel; every drawn byte must map back to itself.
            guard let p = l.position(ofByte: i) else { continue }
            if l.byteIndex(atX: p.x, y: p.y) != i { ok = false; break }
        }
        check(ok, "round trip \(l.blockWidth)x\(l.blockHeight) @\(l.displayWidth) align \(l.blockAlign)")
    }

    // A width that is not a whole number of bytes rounds up, and the display
    // width settles on a whole number of blocks.
    let odd = BitmapLayout(blockWidth: 13, blockHeight: 5, displayWidth: 200).normalized
    check(odd.blockWidth == 16, "block width 13 rounds up to 16")
    check(odd.displayWidth == 192, "display width 200 settles to 192 (12 blocks)")

    // Hires: 8x8 cells laid out cell by cell, exactly like a C64 screen.
    let hires = BitmapPreset.hires.layout(basedOn: BitmapLayout())
    check(hires.blocksPerRow == 40, "hires is 40 cells across")
    func xy(_ l: BitmapLayout, _ i: Int) -> (Int, Int) {
        l.position(ofByte: i).map { ($0.x, $0.y) } ?? (-1, -1)
    }
    check(xy(hires, 0) == (0, 0), "byte 0 at (0,0)")
    check(xy(hires, 1) == (0, 1), "byte 1 drops a row inside the cell")
    check(xy(hires, 8) == (8, 0), "byte 8 starts the next cell")
    check(xy(hires, 320) == (0, 8), "byte 320 wraps to the second cell row")
    check(hires.pixelHeight(forByteCount: 8000) == 200, "8000 bytes is 200 rows tall")

    // Sprites: 63 drawn bytes inside a 64 byte slot, 8 across. Without the
    // align every sprite after the first would slide a byte to the left.
    let sprite = BitmapPreset.sprites.layout(basedOn: BitmapLayout())
    check(sprite.bytesPerBlock == 63, "a sprite draws 63 bytes")
    check(sprite.blockAlign == 64 && sprite.blockStride == 64, "but consumes 64")
    check(sprite.blocksPerRow == 8, "8 sprites per row")
    check(sprite.position(ofByte: 63) == nil, "the 64th byte is padding, not drawn")
    check(xy(sprite, 64) == (24, 0), "the second sprite starts at byte 64, not 63")
    check(xy(sprite, 62) == (16, 20), "the first sprite ends at its bottom right")
    check(sprite.pixelHeight(forByteCount: 64 * 8) == 21, "8 sprites fit on one row")

    // Align only ever pads; it never overlaps or drops drawn bytes.
    var tight = sprite
    tight.blockAlign = 0
    check(tight.blockStride == 63, "align 0 packs tight")
    check(xy(tight, 63) == (24, 0), "and then the second sprite starts at 63")

    // Suggestions from file size.
    check(BitmapPreset.suggested(forByteCount: 8000) == .hires, "8000 bytes suggests hires")
    check(BitmapPreset.suggested(forByteCount: 2048) == .charset, "2048 bytes suggests charset")
    check(BitmapPreset.suggested(forByteCount: 300000) == .linear, "a big file suggests linear")

    // Rasterising: a lit byte must land where the layout says it does.
    var bytes = [UInt8](repeating: 0, count: 8000)
    bytes[321] = 0xFF                                  // second cell row, second byte
    let image = BitmapRenderer.shared.image(bytes: bytes, layout: hires)
    check(image != nil, "hires image renders")
    if let image, let rep = image.representations.first as? NSBitmapImageRep {
        check(rep.pixelsWide == 320 && rep.pixelsHigh == 200, "image is 320x200")
        let p = hires.position(ofByte: 321) ?? (x: -1, y: -1)
        let lit = rep.colorAt(x: p.x, y: p.y)?.alphaComponent ?? 0
        let dark = rep.colorAt(x: p.x, y: p.y == 0 ? 1 : p.y - 1)?.alphaComponent ?? 1
        check(lit > 0.5, "the lit byte is drawn at (\(p.x),\(p.y))")
        check(dark < 0.5, "its neighbouring row stays clear")
    }

    // Invert flips which bits are opaque.
    var flipped = hires
    flipped.invert = true
    if let normal = BitmapRenderer.shared.image(bytes: bytes, layout: hires),
       let inverted = BitmapRenderer.shared.image(bytes: bytes, layout: flipped),
       let a = normal.representations.first as? NSBitmapImageRep,
       let b = inverted.representations.first as? NSBitmapImageRep {
        let x = 0, y = 0   // byte 0 is zero, so clear normally and lit inverted
        check((a.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.5
              && (b.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5, "invert swaps the bits")
    }
} catch {
    print("  FAIL bitmap: \(error)"); failures += 1
}

// --- BASIC detokeniser ------------------------------------------------------
print("\n=== basic listing")
do {
    // 10 PRINT "HELLO"
    // 20 GOTO 10
    var prg: [UInt8] = [0x01, 0x08]                    // load address $0801
    prg += [0x0E, 0x08, 0x0A, 0x00]                    // link, line 10
    prg += [0x99, 0x20, 0x22] + Array("HELLO".utf8) + [0x22, 0x00]
    prg += [0x16, 0x08, 0x14, 0x00]                    // link, line 20
    prg += [0x89, 0x31, 0x30, 0x00]                    // GOTO 10
    prg += [0x00, 0x00]                                // end of program

    let lines = CommodoreBASIC.listing(prg)
    check(lines.count == 2, "two lines parsed")
    check(lines.first?.number == 10 && lines.last?.number == 20, "line numbers 10 and 20")
    check(PETSCII.ascii(lines[0].text) == "print \"hello\"", "line 10 detokenised: \(PETSCII.ascii(lines[0].text))")
    // No space: none was stored, and a real C64 lists it exactly this way.
    check(PETSCII.ascii(lines[1].text) == "goto10", "line 20 detokenised: \(PETSCII.ascii(lines[1].text))")
    check(PETSCII.ascii(lines[0].petscii) == "10 print \"hello\"", "the listing line carries its number")

    // A token byte inside quotes is a character, not a keyword.
    var quoted: [UInt8] = [0x01, 0x08]
    quoted += [0x0A, 0x08, 0x0A, 0x00]
    quoted += [0x99, 0x22, 0x99, 0x22, 0x00]           // PRINT "<$99>"
    quoted += [0x00, 0x00]
    let q = CommodoreBASIC.listing(quoted)
    check(q.count == 1 && q[0].text == [0x50, 0x52, 0x49, 0x4E, 0x54, 0x22, 0x99, 0x22],
          "a token inside quotes stays a raw byte")

    // Every keyword resolves, and the table is the right length.
    check(CommodoreBASIC.tokens.count == 76, "76 tokens, $80 to $CB")
    check(CommodoreBASIC.tokens[0x99 - 0x80] == "print", "$99 is PRINT")
    check(CommodoreBASIC.tokens[0x9E - 0x80] == "sys", "$9E is SYS")
    check(CommodoreBASIC.tokens[0xCB - 0x80] == "go", "$CB is GO")

    // Junk must not hang or crash the parser.
    check(CommodoreBASIC.listing([UInt8](repeating: 0xAA, count: 5000)).count <= 20_000,
          "random data terminates")
    check(CommodoreBASIC.listing([]).isEmpty, "empty data gives no lines")

    // A real BASIC loader off one of the sample disks.
    let img = try CBMDiskImage(url: URL(fileURLWithPath: "sample_images/cbmcmd23.d64"))
    if let entry = img.entries.first(where: { $0.displayName == "LOADCBMCMD" }) {
        let real = CommodoreBASIC.listing([UInt8](try img.read(entry)))
        check(!real.isEmpty, "LOADCBMCMD lists \(real.count) line(s)")
        for line in real.prefix(3) {
            print("      \(PETSCII.ascii(line.petscii))")
        }
    }
} catch {
    print("  FAIL basic: \(error)"); failures += 1
}

// --- SID tune detection -----------------------------------------------------
print("\n=== sid tune detection")
do {
    // The naming convention, against every shape seen on the real disks.
    let expected: [(String, Int, Int, Bool)] = [
        ("Z10 I1000 P1003", 0x1000, 0x1003, false),   // the standard
        ("Z8 I4000 P4003", 0x4000, 0x4003, false),
        ("Z108 !2800 P2803", 0x2800, 0x2803, true),   // ! replaces the I
        ("Z11 I1800 P1803!", 0x1800, 0x1803, true),   // trailing !
        ("Z101 !E006PPE000", 0xE006, 0xE000, true),   // run together, doubled P
        ("Z121 !41C9 P41C0", 0x41C9, 0x41C0, true),
        ("z900 if000 pf003", 0xF000, 0xF003, false),   // lower case, as written on the Mac
        ("z50 !ab00 pab03", 0xAB00, 0xAB03, true),
    ]
    for (name, wantInit, wantPlay, wantMulti) in expected {
        if let got = SIDTuneLoader.addressesFromName(name) {
            check(got.init_ == wantInit && got.play == wantPlay && got.multi == wantMulti,
                  String(format: "%-18@ -> init $%04X play $%04X%@", name as NSString,
                         got.init_, got.play, got.multi ? " multi" : ""))
        } else {
            check(false, "\(name) did not parse")
        }
    }
    // Things on the same disks that must NOT look like tunes.
    for name in ["PLAYER V3.1 0800", "PLAY ALL+   /MAC", "NOTES", "Z50"] {
        check(SIDTuneLoader.addressesFromName(name) == nil, "\(name.trimmingCharacters(in: .whitespaces)) is not a tune")
    }

    // Sweep every INTROMUSICS disk and report the real hit rate.
    let disks = (try? FileManager.default.contentsOfDirectory(
        atPath: "/Users/macc/Emulation/c64/SD_backup/macc/maccdisks"))?
        .filter { $0.uppercased().hasPrefix("INTROMUSICS") && $0.uppercased().hasSuffix(".D64") }
        .sorted() ?? []
    var parsed = 0, multi = 0, skipped = 0
    for disk in disks {
        let img = try CBMDiskImage(url: URL(fileURLWithPath:
            "/Users/macc/Emulation/c64/SD_backup/macc/maccdisks/\(disk)"))
        for entry in img.entries where entry.type == .prg {
            if let got = SIDTuneLoader.addressesFromName(entry.displayName) {
                parsed += 1
                if got.multi { multi += 1 }
            } else { skipped += 1 }
        }
    }
    check(!disks.isEmpty, "found \(disks.count) INTROMUSICS disks")
    check(parsed > 150, "\(parsed) tunes resolved from their names (\(multi) multi-song)")
    check(skipped > 0, "\(skipped) non-tune PRGs correctly left alone")

    // A real tune off a disk loads with its address from the PRG header.
    let img = try CBMDiskImage(url: URL(fileURLWithPath:
        "/Users/macc/Emulation/c64/SD_backup/macc/maccdisks/INTROMUSICS_007.D64"))
    if let entry = img.entries.first(where: { $0.displayName.hasPrefix("z10 ") }) {
        let bytes = [UInt8](try img.read(entry))
        if let tune = SIDTuneLoader.detect(name: entry.displayName, data: bytes) {
            check(tune.source == .naming, "Z10 detected from its name")
            check(tune.initAddress == 0x1000 && tune.playAddress == 0x1003, "init/play $1000/$1003")
            check(tune.loadAddress == 0x1000, String(format: "loads at $%04X", tune.loadAddress))
            check(tune.payload.count == bytes.count - 2, "payload drops the load address")
        } else { check(false, "Z10 did not detect") }
    }

    // PSID, from the user's own collection.
    let sids = (try? FileManager.default.contentsOfDirectory(
        atPath: "/Users/macc/Music/C64music/MUSICIANS/P/PCH"))?
        .filter { $0.lowercased().hasSuffix(".sid") }.sorted() ?? []
    if let first = sids.first {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath:
            "/Users/macc/Music/C64music/MUSICIANS/P/PCH/\(first)")))
        check(SIDTuneLoader.isPSID(bytes), "\(first) has a PSID header")
        if let tune = SIDTuneLoader.psid(bytes) {
            check(tune.source == .psid, "parsed from the header")
            check(tune.initAddress != 0, String(format: "init $%04X, play $%04X, load $%04X",
                                                tune.initAddress, tune.playAddress, tune.loadAddress))
            check((tune.songCount ?? 0) >= 1,
                  "\(tune.songCount.map(String.init) ?? "an unknown number of") song(s), "
                  + "title \"\(tune.title)\"")
            check(!tune.payload.isEmpty, "\(tune.payload.count) bytes of payload")
        } else { check(false, "PSID did not parse") }
    } else { print("      (no .sid files found to test)") }

    // Raw: the load address comes from the first two bytes.
    let prg: [UInt8] = [0x00, 0x20] + [UInt8](repeating: 0xEA, count: 100)
    if let tune = SIDTuneLoader.raw(prg, name: "T", initAddress: 0x2000, playAddress: 0x2003) {
        check(tune.loadAddress == 0x2000 && tune.payload.count == 100, "raw PRG loads at $2000")
    }

    // Music Assembler, recognised by the player's own code rather than by the
    // name. Sweep the user's MUSICS disks and report the hit rate.
    let musics = "/Users/macc/Emulation/c64/SD_backup/macc/music"
    let musicDisks = (try? FileManager.default.contentsOfDirectory(atPath: musics))?
        .filter { $0.uppercased().hasSuffix(".D64") }.sorted() ?? []
    var found = 0, handler = 0, bare = 0, misplaced = 0
    for disk in musicDisks {
        let img = try CBMDiskImage(url: URL(fileURLWithPath: "\(musics)/\(disk)"))
        for entry in img.entries where entry.type == .prg {
            let bytes = [UInt8](try img.read(entry))
            guard let tune = SIDTuneLoader.musicAssembler(entry.displayName, prg: bytes)
            else { continue }
            found += 1
            if tune.initAddress != tune.loadAddress + 0x48 { misplaced += 1 }
            if tune.playAddress == tune.loadAddress + 0x18 { handler += 1 }
            if tune.playAddress == tune.loadAddress + 0x21 { bare += 1 }
        }
    }
    check(!musicDisks.isEmpty, "found \(musicDisks.count) MUSICS disks")
    check(found > 200, "\(found) Music Assembler tunes recognised without their names")
    check(misplaced == 0, "every one puts init $48 past the load address")
    check(handler + bare == found,
          "\(handler) play through the interrupt handler, \(bare) through the routine it calls")

    // The two shapes, off one disk: a tune that kept its standalone player, and
    // one a ripper wrote a banner over.
    let mmus = try CBMDiskImage(url: URL(fileURLWithPath: "\(musics)/MMUS_279.D64"))
    func mac(_ name: String) throws -> SIDTune? {
        guard let entry = mmus.entries.first(where: {
            $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return SIDTuneLoader.detect(name: entry.displayName, data: [UInt8](try mmus.read(entry)))
    }
    if let tune = try mac("S.MAC.09") {
        check(tune.source == .musicAssembler, "s.mac.09 detected from the player")
        check(tune.loadAddress == 0xC000 && tune.initAddress == 0xC048
              && tune.playAddress == 0xC018, "load $C000, init $C048, play $C018")
    } else { check(false, "s.mac.09 did not detect") }
    if let tune = try mac("S.MAC.06") {
        check(tune.playAddress == 0xC021, "the banner-over-the-player copy plays at $C021")
    } else { check(false, "s.mac.06 did not detect") }

    // The editor itself and a utility sit on the same disk and must be left be.
    for name in ["MUSIC ASSEMBLER", "FILTEX!", "S-PLAYER V1 /MAC"] {
        check((try? mac(name)) ?? nil == nil, "\(name) is not taken for a tune")
    }
} catch {
    print("  FAIL sid: \(error)"); failures += 1
}

// --- The SID engine actually runs -------------------------------------------
print("\n=== sid engine")
do {
    let img = try CBMDiskImage(url: URL(fileURLWithPath:
        "/Users/macc/Emulation/c64/SD_backup/macc/maccdisks/INTROMUSICS_007.D64"))
    guard let entry = img.entries.first(where: { $0.displayName.hasPrefix("z10 ") }),
          let tune = SIDTuneLoader.detect(name: entry.displayName,
                                          data: [UInt8](try img.read(entry)))
    else { throw DiskImageError.fileNotFound }

    func render(seconds: Int, hz: Double) -> (nonSilent: Int, peak: Int, calls: UInt) {
        cSID_init(44100)
        tune.payload.withUnsafeBufferPointer {
            csid_load($0.baseAddress, Int32($0.count), UInt32(tune.loadAddress))
        }
        csid_set_addresses(UInt32(tune.initAddress), UInt32(tune.playAddress))
        csid_set_sid(8580, 0, 0)
        csid_set_speed_hz(hz)
        csid_start(0, tune.selector)

        let frames = 44100 * seconds
        var buffer = [Int16](repeating: 0, count: frames)
        buffer.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, Int32(frames)) }
        return (buffer.filter { $0 != 0 }.count,
                Int(buffer.map { abs(Int($0)) }.max() ?? 0),
                UInt(csid_play_call_count()))
    }

    // Sound, not silence and not garbage.
    let vsync = render(seconds: 2, hz: 0)
    check(vsync.nonSilent > 40_000, "2s render is audible: \(vsync.nonSilent)/88200 non-silent samples")
    check(vsync.peak > 1000 && vsync.peak <= 32767, "peak amplitude \(vsync.peak) is in range")

    // Timing: the tune's own rate is PAL vsync, near 50 Hz.
    let vsyncHz = Double(vsync.calls) / 2.0
    check(abs(vsyncHz - 50.0) < 1.5, String(format: "default timing is %.1f Hz (PAL vsync)", vsyncHz))

    // An explicit rate overrides it, and scales the way it should.
    for hz in [100.0, 200.0, 400.0] {
        let forced = render(seconds: 1, hz: hz)
        let measured = Double(forced.calls)
        check(abs(measured - hz) / hz < 0.05,
              String(format: "%.0f Hz requested -> play called %.0f times in 1s", hz, measured))
    }

    // The A/X/Y byte reaches the tune. Individual tunes may ignore it — of the
    // 35 multi-song files on these disks, 33 respond and 2 do not — so look for
    // the first that does rather than resting on one file.
    func fingerprint(_ t: SIDTune, _ selector: UInt8) -> Int {
        cSID_init(44100)
        t.payload.withUnsafeBufferPointer {
            csid_load($0.baseAddress, Int32($0.count), UInt32(t.loadAddress))
        }
        csid_set_addresses(UInt32(t.initAddress), UInt32(t.playAddress))
        csid_set_sid(8580, 0, 0); csid_set_speed_hz(0)
        csid_start(selector, selector)
        var buffer = [Int16](repeating: 0, count: 44100)
        buffer.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, 44100) }
        return buffer.reduce(0) { $0 &+ Int($1) &* Int($1) }
    }

    // Disk 007 carries only one such file and it is one of the two that ignore
    // the selector, so look across the set.
    let musicDir = "/Users/macc/Emulation/c64/SD_backup/macc/maccdisks"
    var tried = 0, responder: String?
    outer: for disk in (try FileManager.default.contentsOfDirectory(atPath: musicDir))
        .filter({ $0.uppercased().hasPrefix("INTROMUSICS") && $0.uppercased().hasSuffix(".D64") })
        .sorted() {
        let d = try CBMDiskImage(url: URL(fileURLWithPath: "\(musicDir)/\(disk)"))
        for entry in d.entries where entry.type == .prg && entry.displayName.contains("!") {
            guard let mt = SIDTuneLoader.detect(name: entry.displayName,
                                               data: [UInt8](try d.read(entry))) else { continue }
            tried += 1
            if fingerprint(mt, 0) != fingerprint(mt, 1) { responder = entry.displayName; break outer }
            if tried >= 12 { break outer }
        }
    }
    check(responder != nil,
          "the selector changes the tune: \(responder ?? "none") (tried \(tried))")

    // Per-voice capture for the oscilloscope. Many of these intro tunes use a
    // single voice, so check against one that is known to use all three.
    guard let three = img.entries.first(where: { $0.displayName.hasPrefix("zj0 ") }),
          let threeTune = SIDTuneLoader.detect(name: three.displayName,
                                               data: [UInt8](try img.read(three)))
    else { throw DiskImageError.fileNotFound }

    cSID_init(44100)
    threeTune.payload.withUnsafeBufferPointer {
        csid_load($0.baseAddress, Int32($0.count), UInt32(threeTune.loadAddress))
    }
    csid_set_addresses(UInt32(threeTune.initAddress), UInt32(threeTune.playAddress))
    csid_set_sid(8580, 0, 0); csid_set_speed_hz(0)
    csid_start(0, threeTune.selector)
    csid_scope_enable(1)

    let length = Int(csid_scope_length())
    func track(_ i: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: length)
        out.withUnsafeMutableBufferPointer { csid_scope_read(Int32(i), $0.baseAddress, Int32(length)) }
        return out
    }
    func peak(_ t: [Int16]) -> Int { t.map { abs(Int($0)) }.max() ?? 0 }

    // Peaks are gathered over the whole render: a voice can be silent in any
    // one 46 ms window even when the tune uses it.
    var voicePeak = [Int](repeating: 0, count: 10)
    var chunk = [Int16](repeating: 0, count: 4410)
    for _ in 0..<40 {
        chunk.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, 4410) }
        for t in 0..<10 { voicePeak[t] = max(voicePeak[t], peak(track(t))) }
    }

    check(csid_sid_count() == 1, "one SID chip, so the scope is 3 rows by 1 column")
    check(voicePeak[9] > 0, "the mix track carries signal")
    check((0..<3).allMatch { voicePeak[$0] > 0 },
          "all three voices sound: \(voicePeak[0]), \(voicePeak[1]), \(voicePeak[2])")
    check(track(0) != track(1), "voice 1 and voice 2 differ")
    check((3..<9).allMatch { voicePeak[$0] == 0 }, "voices of absent chips stay silent")

    csid_scope_enable(0)

    // Both shapes of Music Assembler tune actually sound, at the addresses the
    // player's layout gives them.
    func audible(_ t: SIDTune) -> Int {
        cSID_init(44100)
        t.payload.withUnsafeBufferPointer {
            csid_load($0.baseAddress, Int32($0.count), UInt32(t.loadAddress))
        }
        csid_set_addresses(UInt32(t.initAddress), UInt32(t.playAddress))
        csid_set_sid(8580, 0, 0); csid_set_speed_hz(0)
        csid_start(0, t.selector)
        let frames = 44100 * 2
        var buffer = [Int16](repeating: 0, count: frames)
        buffer.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, Int32(frames)) }
        return buffer.filter { $0 != 0 }.count
    }
    let macDisk = try CBMDiskImage(url: URL(fileURLWithPath:
        "/Users/macc/Emulation/c64/SD_backup/macc/music/MMUS_279.D64"))
    for name in ["S.MAC.09", "S.MAC.06"] {
        guard let entry = macDisk.entries.first(where: {
                  $0.displayName.caseInsensitiveCompare(name) == .orderedSame }),
              let macTune = SIDTuneLoader.detect(name: entry.displayName,
                                                 data: [UInt8](try macDisk.read(entry)))
        else { check(false, "\(name) did not detect"); continue }
        let heard = audible(macTune)
        check(heard > 40_000,
              String(format: "%@ plays at $%04X: %d/88200 non-silent samples",
                     name, macTune.playAddress, heard))
    }

    // Handing a file inside an image to the system means writing a copy out
    // first. It is a copy, and read-only so that stays true.
    do {
        let container = URL(fileURLWithPath: "\(scratch)/handoff.d64")
        let folder = HostHandoff.temporaryFolder(for: container)
        try? FileManager.default.removeItem(at: folder)

        let payload = Data([0x01, 0x08, 0x41, 0x42, 0x43])
        let url = try HostHandoff.write(payload, named: "a file.prg", in: folder)
        check(url.deletingLastPathComponent() == folder, "the copy lands in the image's own folder")
        check(folder.lastPathComponent == "handoff", "which is named after the image")
        check((try Data(contentsOf: url)) == payload, "byte for byte what was read out")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        check(mode == 0o444, "written read-only, so an editor cannot save into it")

        // Opening the same entry twice must hand back the same path rather
        // than collecting numbered duplicates beside it.
        let again = try HostHandoff.write(Data([0x09]), named: "a file.prg", in: folder)
        check(again == url, "the second copy replaces the first")
        check((try Data(contentsOf: again)) == Data([0x09]), "and holds the newer bytes")
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        check(listing.count == 1, "one file in the folder, not \(listing.count)")

        // A CBM name can hold what a path cannot.
        check(HostHandoff.safeName("a/b:c") == "a-b-c", "slashes and colons are replaced")
        check(HostHandoff.safeName(".hidden") == "_hidden", "a leading dot cannot hide the copy")
        check(HostHandoff.safeName("   ") == "unnamed", "an empty name still writes somewhere")

        // The name comes from the same place the copy-out path uses.
        let entryName = PETSCII.cbmName(fromASCII: "tune")
        check(PETSCII.hostFileName(entryName, type: .prg) == "tune.prg",
              "and it is the host name the copy-out path gives")
    }

    // A D64 can be made at 35, 40 or 42 tracks. The extra ones are in the file
    // and reachable, but the BAM a 1541 writes stops at 35, so nothing is ever
    // put on them and the free count does not move.
    do {
        for tracks in [35, 40, 42] {
            let url = URL(fileURLWithPath: "\(scratch)/blank-\(tracks).d64")
            try? FileManager.default.removeItem(at: url)
            try CBMDiskImage.createBlank(.d64, tracks: tracks,
                                         name: PETSCII.cbmName(fromASCII: "wide"),
                                         id: PETSCII.petscii(fromASCII: "01"), at: url)
            let size = (try Data(contentsOf: url)).count
            let expected = [35: 174_848, 40: 196_608, 42: 205_312][tracks]!
            check(size == expected, "\(tracks) tracks is \(size) bytes")

            let img = try CBMDiskImage(url: url)
            check(img.formatName == "D64 (\(tracks) tracks)", "reads back as \(img.formatName)")
            check(img.blocksFree == 664, "\(tracks) tracks still shows 664 blocks free")
            check(img.integrityNote == nil, "\(tracks) tracks formats with a consistent BAM")
            check(PETSCII.ascii(PETSCII.trimPadding(img.diskName)) == "wide",
                  "\(tracks) tracks keeps its header")

            // It has to hold files like any other image.
            try img.write(name: PETSCII.cbmName(fromASCII: "a file"), type: .prg,
                          data: Data([0x01, 0x08, 1, 2, 3]))
            try img.save()
            let reread = try CBMDiskImage(url: url)
            check(reread.entries.count == 1 && reread.entries[0].displayName == "a file",
                  "\(tracks) tracks takes a file")
            check((try Data(contentsOf: url)).count == expected,
                  "\(tracks) tracks did not change size when written to")
        }
        // A choice the format does not offer falls back rather than writing a
        // file of some size nothing can read.
        let url = URL(fileURLWithPath: "\(scratch)/blank-odd.d64")
        try? FileManager.default.removeItem(at: url)
        try CBMDiskImage.createBlank(.d64, tracks: 37, name: PETSCII.cbmName(fromASCII: "odd"),
                                     id: PETSCII.petscii(fromASCII: "01"), at: url)
        check((try Data(contentsOf: url)).count == 174_848, "an unoffered track count falls back to 35")
    }

    // Case decides which form of a letter is stored: lower case the unshifted
    // one a machine types by default, upper case the shifted one. Both survive
    // the round trip, which is what lets a name be given in mixed case.
    do {
        check(PETSCII.petscii(fromASCII: "new disk")
              == [0x4E, 0x45, 0x57, 0x20, 0x44, 0x49, 0x53, 0x4B],
              "lower case stores the unshifted letters")
        check(PETSCII.petscii(fromASCII: "NEW") == [0xCE, 0xC5, 0xD7],
              "upper case stores the shifted ones")
        for name in ["new disk", "NewFile", "NEWFILE", "z10 i1000 p1003"] {
            check(PETSCII.ascii(PETSCII.petscii(fromASCII: name)) == name,
                  "\"\(name)\" survives the round trip")
        }
        // Unshifted letters are the same glyph indices in both halves of the
        // ROM, which is what makes one spelling read either way.
        check(PETSCII.screenCodes(ascii: "new") == [0x0E, 0x05, 0x17],
              "and draw from the letter range of whichever set is on")
        check(PETSCII.cbmName(fromASCII: "new disk").allSatisfy { $0 != 0xA0 },
              "no name byte collides with the padding")
    }

    // The picture an export writes. Odd dimensions are the failure that matters:
    // H.264 will not take them.
    do {
        let expected: [(VideoResolution, VideoAspect, Int, Int)] = [
            (.p720, .sixteenNine, 1280, 720), (.p1080, .sixteenNine, 1920, 1080),
            (.uhd4K, .sixteenNine, 3840, 2160), (.p720, .fourThree, 960, 720),
            (.p1080, .fourThree, 1440, 1080), (.uhd4K, .fourThree, 2880, 2160),
        ]
        for (resolution, aspect, width, height) in expected {
            let size = VideoFormat.size(resolution, aspect)
            check(Int(size.width) == width && Int(size.height) == height,
                  "\(resolution.label) \(aspect.label) is \(Int(size.width))×\(Int(size.height))")
            check(Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0,
                  "and both sides are even")
        }
    }

    // Trigger sync. Tested on a controlled wave first: a real tune changes what
    // it is playing between frames, so drift there measures the music, not the
    // alignment.
    do {
        func square(period: Int, phase: Int, count: Int = 2048) -> [Int16] {
            (0..<count).map { ((($0 + phase) % period) < period / 2) ? 8000 : -8000 }
        }
        // The same wave caught at two different phases must produce the same
        // picture once triggered.
        let first = square(period: 100, phase: 0)
        let second = square(period: 100, phase: 37)
        let w = ScopeRenderer.displayWindow
        let s1 = ScopeRenderer.windowStart(first), s2 = ScopeRenderer.windowStart(second)
        check(s1 != s2, "the two phases start the window at different offsets (\(s1) and \(s2))")
        check(Array(first[s1..<(s1 + w)]) == Array(second[s2..<(s2 + w)]),
              "triggered windows are identical despite the phase difference")
        check(Array(first[0..<w]) != Array(second[0..<w]),
              "and untriggered they would not have been")

        // Every trigger must land on a rising crossing, and sit at the middle
        // of the drawn window rather than at its left edge.
        for phase in [0, 13, 49, 71, 99] {
            let wave = square(period: 100, phase: phase)
            guard let index = ScopeRenderer.triggerIndex(wave) else {
                check(false, "phase \(phase) triggers at all"); continue
            }
            check(wave[index] > 0 && wave[index - 1] < 0,
                  "phase \(phase) triggers on a rising edge at \(index)")
            let start = ScopeRenderer.windowStart(wave)
            check(start == index - w / 2, "the trigger sits half a window in")
            check(start >= 0 && start + w <= wave.count, "the centred window stays in the buffer")
        }

        check(ScopeRenderer.triggerIndex([Int16](repeating: 0, count: 2048)) == nil,
              "silence never triggers")
        check(ScopeRenderer.windowStart([Int16](repeating: 0, count: 2048)) == 512,
              "and draws the middle of the buffer")
        check(ScopeRenderer.windowStart([Int16](repeating: 0, count: 10)) == 0,
              "a buffer shorter than the window is safe")
    }

    // On a real tune, every frame that triggers must still begin on a rising
    // crossing — that property is what keeps successive frames in step.
    do {
        cSID_init(44100)
        threeTune.payload.withUnsafeBufferPointer {
            csid_load($0.baseAddress, Int32($0.count), UInt32(threeTune.loadAddress))
        }
        csid_set_addresses(UInt32(threeTune.initAddress), UInt32(threeTune.playAddress))
        csid_set_sid(8580, 0, 0); csid_set_speed_hz(0)
        csid_start(0, threeTune.selector)
        csid_scope_enable(1)
        var advance = [Int16](repeating: 0, count: 882)

        var fired = 0, rising = 0
        for _ in 0..<40 {
            advance.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, 882) }
            let length = Int(csid_scope_length())
            var buf = [Int16](repeating: 0, count: length)
            buf.withUnsafeMutableBufferPointer { csid_scope_read(1, $0.baseAddress, Int32(length)) }
            if let index = ScopeRenderer.triggerIndex(buf) {
                fired += 1
                // The contract is hysteresis, not a sign change on the very
                // previous sample: the signal fell below the threshold at some
                // point before rising back through it. The sample just before
                // the trigger may sit inside the dead band.
                if buf[index] >= 400, buf[0..<index].contains(where: { $0 < -400 }) { rising += 1 }
            }
        }
        check(fired > 20, "the trigger fired on \(fired) of 40 frames of real audio")
        check(rising == fired, "all \(fired) rose through the threshold after falling below it")
        csid_scope_enable(0)
    }

    // Speed and chip model change without restarting the tune. csid_start
    // zeroes the play-call counter, so a counter that keeps climbing across a
    // change is proof that init was not re-run.
    func startThreeVoiceTune(model: Int32) {
        cSID_init(44100)
        threeTune.payload.withUnsafeBufferPointer {
            csid_load($0.baseAddress, Int32($0.count), UInt32(threeTune.loadAddress))
        }
        csid_set_addresses(UInt32(threeTune.initAddress), UInt32(threeTune.playAddress))
        csid_set_sid(model, 0, 0); csid_set_speed_hz(0)
        csid_start(0, threeTune.selector)
    }
    func renderSecond() {
        var b = [Int16](repeating: 0, count: 44100)
        b.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, 44100) }
    }

    startThreeVoiceTune(model: 8580)
    renderSecond()
    let afterTuneRate = UInt(csid_play_call_count())
    check(abs(Double(afterTuneRate) - 50.0) < 2, "1s at the tune's own rate: \(afterTuneRate) calls")

    csid_set_speed_hz(200)          // live
    renderSecond()
    let after200 = UInt(csid_play_call_count())
    check(after200 > afterTuneRate, "the counter kept climbing, so the tune did not restart")
    check(abs(Double(after200 - afterTuneRate) - 200.0) < 6,
          "the next second ran at 200 Hz: \(after200 - afterTuneRate) calls")

    csid_set_speed_hz(0)            // back to the tune's own timing, still live
    renderSecond()
    let afterBack = UInt(csid_play_call_count())
    check(abs(Double(afterBack - after200) - 50.0) < 2,
          "back to tune timing: \(afterBack - after200) calls, and still no restart")

    // Fast forward is that same live rate change, worked out the way the player
    // works it out: ten times whatever the engine is running at, whether that
    // came from the tune or from the speed row.
    let fast = 10.0 * 44100.0 / csid_frame_sampleperiod()
    csid_set_speed_hz(fast)
    renderSecond()
    let afterFast = UInt(csid_play_call_count())
    check(abs(Double(afterFast - afterBack) - 500.0) < 15,
          "fast forward ran a second at ten times the rate: \(afterFast - afterBack) calls")
    csid_set_speed_hz(0)            // key released
    renderSecond()
    let afterRelease = UInt(csid_play_call_count())
    check(abs(Double(afterRelease - afterFast) - 50.0) < 2,
          "and let go it is back to the tune's own rate: \(afterRelease - afterFast) calls")

    csid_set_model(6581)            // live
    renderSecond()
    check(UInt(csid_play_call_count()) > afterRelease, "changing chip model did not restart either")

    // And the model choice does reach the sound.
    func fingerprintFromStart(model: Int32) -> Int {
        startThreeVoiceTune(model: model)
        var b = [Int16](repeating: 0, count: 44100)
        b.withUnsafeMutableBufferPointer { csid_render($0.baseAddress, 44100) }
        return b.reduce(0) { $0 &+ Int($1) &* Int($1) }
    }
    check(fingerprintFromStart(model: 8580) != fingerprintFromStart(model: 6581),
          "8580 and 6581 render differently")

} catch {
    print("  FAIL sid engine: \(error)"); failures += 1
}

// --- Module detection -------------------------------------------------------
print("\n=== module detection")
do {
    // The channel-count marks, which are spelled rather than tabulated.
    let spelled: [(String, Bool)] = [
        ("6CHN", true), ("8CHN", true), ("16CH", true), ("32CN", true), ("TDZ3", true),
        ("M.K.", true), ("FLT8", true), ("OKTA", true),
        ("0CHN", false), ("ABCD", false), ("CHN4", false), ("TDZ9", false), ("\0\0\0\0", false),
    ]
    // A believable 31-sample header to hang them on: one pattern, one order
    // entry, and no sample data. A pattern is 64 rows of one note per channel,
    // so how big the file has to be depends on the mark itself.
    func skeleton(_ tag: String, channels: Int = 4) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1084 + 64 * channels * 4)
        bytes[950] = 1
        bytes.replaceSubrange(1080..<1084, with: Array(tag.utf8).prefix(4))
        return bytes
    }
    // How many voices each mark stands for, so the skeleton is the right size.
    func voices(_ tag: String) -> Int {
        switch tag {
        case "FLT8", "OKTA", "CD81", "OCTA": return 8
        case "6CHN": return 6
        case "8CHN": return 8
        case "16CH", "16CN": return 16
        case "32CH", "32CN": return 32
        case "TDZ3": return 3
        default: return 4
        }
    }
    for (tag, want) in spelled {
        let got = ModuleLoader.detect(skeleton(tag, channels: voices(tag))) != nil
        check(got == want, "\(tag.debugDescription) at 1080 \(want ? "is" : "is not") a module")
    }

    // The header has to add up, not just carry the mark. A module accounts for
    // its own file: header, patterns, then samples.
    var noSongLength = skeleton("M.K."); noSongLength[950] = 0
    check(ModuleLoader.detect(noSongLength) == nil, "a song of no length rules it out")
    var wildOrder = skeleton("M.K."); wildOrder[952 + 5] = 200
    check(ModuleLoader.detect(wildOrder) == nil, "an order entry past 127 rules it out")
    var truncated = skeleton("M.K."); truncated.removeLast(1)
    check(ModuleLoader.detect(truncated) == nil, "a file too short for its patterns rules it out")
    var hugeSamples = skeleton("M.K.")
    hugeSamples[20 + 22] = 0xFF; hugeSamples[20 + 23] = 0xFF   // 128 KB in sample 1 alone
    check(ModuleLoader.detect(hugeSamples) == nil, "samples that could not fit rule it out")
    // An eight channel module needs twice the pattern space, and saying so is
    // the difference between reading it and rejecting it.
    check(ModuleLoader.detect(skeleton("8CHN", channels: 8)) != nil, "8CHN sizes its patterns for eight")
    check(ModuleLoader.detect(skeleton("8CHN", channels: 4)) == nil, "and a four channel file is not one")

    // The user's own collection on the file system.
    let music = "/Users/macc/Emulation/Amiga/Music"
    var found: [String: Int] = [:], missed: [String] = [], unmarked = 0
    if let walk = FileManager.default.enumerator(atPath: music) {
        for case let rel as String in walk {
            if rel.hasPrefix("SAMPLES") || (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            let path = "\(music)/\(rel)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                  let data = FileManager.default.contents(atPath: path) else { continue }
            guard let module = ModuleLoader.detect([UInt8](data)) else { continue }
            found[module.format.name.components(separatedBy: " (")[0], default: 0] += 1
            let base = (rel as NSString).lastPathComponent.lowercased()
            if !base.hasPrefix("mod.") && !base.hasPrefix("med.")
                && !base.hasSuffix(".mod") && !base.hasSuffix(".xm")
                && !base.hasSuffix(".s3m") && !base.hasSuffix(".med") { unmarked += 1 }
            if module.title.isEmpty, case .protracker = module.format { missed.append(rel) }
        }
    }
    let total = found.values.reduce(0, +)
    check(total >= 150, "\(total) modules recognised in the music folder by content alone")
    for (kind, count) in found.sorted(by: { $0.key < $1.key }) {
        check(count > 0, "  \(count) \u{00D7} \(kind)")
    }
    check(found["ProTracker"] ?? 0 >= 98, "\(found["ProTracker"] ?? 0) ProTracker modules")
    check(found["OctaMED"] ?? 0 >= 9, "\(found["OctaMED"] ?? 0) OctaMED modules, which no name marks as such")

    // The point of all this: modules inside real Amiga images, where the name
    // is whatever the person who saved it felt like typing.
    let places = ["/Users/macc/Emulation/Amiga/harddisks/dh2/!DMS",
                  "/Users/macc/Emulation/Amiga/Floppys",
                  "/Users/macc/Emulation/Amiga/FS-UAE/Floppies"]
    var images: [String] = []
    for place in places {
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: place)) ?? []
        for name in listing.sorted() where ["adf", "dms"].contains((name as NSString).pathExtension.lowercased()) {
            images.append("\(place)/\(name)")
        }
    }
    check(images.count > 250, "\(images.count) Amiga images to look through")

    var inImages = 0, nameless: [String] = [], opened = 0
    func sweep(_ img: ADFImage, _ path: [String], _ depth: Int) {
        guard depth < 6, let entries = try? img.entries(at: path) else { return }
        for entry in entries {
            if entry.isDirectory { sweep(img, path + [entry.displayName], depth + 1); continue }
            guard let data = try? img.read(entry, at: path),
                  ModuleLoader.detect([UInt8](data)) != nil else { continue }
            inImages += 1
            let base = entry.displayName.lowercased()
            if !base.hasPrefix("mod.") && !base.hasPrefix("med.")
                && !base.hasSuffix(".mod") && !base.hasSuffix(".med") { nameless.append(entry.displayName) }
        }
    }
    for path in images {
        let url = URL(fileURLWithPath: path)
        let img = url.pathExtension.lowercased() == "dms"
            ? try? ADFImage(unpacking: url) : try? ADFImage(url: url)
        guard let img else { continue }
        opened += 1
        sweep(img, [], 0)
    }
    check(opened > 190, "\(opened) of them opened")
    check(inImages >= 45, "\(inImages) modules inside them, found without reading a single name")
    check(nameless.count >= 5,
          "\(nameless.count) carry no name marker at all: \(nameless.sorted().prefix(6).joined(separator: ", "))")

    // Nothing that is not music may be taken for a module. Amiga icons,
    // libraries, fonts, bitmaps and source code all live beside the tunes.
    var nonMusic = 0, falsePositives: [String] = []
    let wanted = ["info", "library", "font", "iff", "device", "datatype", "guide", "c", "s", "doc", "prefs"]
    if let walk = FileManager.default.enumerator(atPath: "/Users/macc/Emulation/Amiga") {
        for case let rel as String in walk {
            guard wanted.contains((rel as NSString).pathExtension.lowercased()),
                  !rel.hasPrefix("Music/"),
                  let data = FileManager.default.contents(atPath: "/Users/macc/Emulation/Amiga/\(rel)"),
                  data.count > 2048 else { continue }
            nonMusic += 1
            if nonMusic > 600 { break }
            if let m = ModuleLoader.detect([UInt8](data)) { falsePositives.append("\(rel) -> \(m.format.name)") }
        }
    }
    check(nonMusic > 300, "\(nonMusic) non-music Amiga files to try it on")
    check(falsePositives.isEmpty, "none of them was taken for a module\(falsePositives.isEmpty ? "" : ": \(falsePositives.prefix(3))")")

    // A title comes out of the file, not the name.
    if let data = FileManager.default.contents(atPath: "\(music)/MACMUSICS/mod.macos"),
       let m = ModuleLoader.detect([UInt8](data)) {
        check(m.format == .protracker("4 channels"), "mod.macos is a 4 channel ProTracker module")
        check(m.title == "macos", "and calls itself \"\(m.title)\"")
    } else { check(false, "mod.macos did not detect") }
} catch {
    print("  FAIL modules: \(error)"); failures += 1
}

// --- The module engine actually runs ----------------------------------------
print("\n=== module engine")
do {
    /// Open a file through the shim and render it a second at a time, counting
    /// the samples that carry signal. Some modules open on a few seconds of
    /// silence before the first note — one S3M here waits three — so this looks
    /// across `seconds` rather than judging the first buffer.
    func play(_ bytes: [UInt8], seconds: Int = 2) -> (opened: Bool, type: String, title: String,
                                                      channels: Int, loud: Int, seconds: Double) {
        let opened = bytes.withUnsafeBufferPointer {
            cmod_open($0.baseAddress, Int32($0.count), 44100)
        } == 1
        guard opened else { cmod_close(); return (false, "", "", 0, 0, 0) }
        let type = String(cString: cmod_type())
        let title = String(cString: cmod_title())
        let channels = Int(cmod_channels())
        let duration = cmod_duration()

        var loud = 0
        var buffer = [Int16](repeating: 0, count: 44100 * 2)    // one second, interleaved
        for _ in 0..<seconds {
            var rendered = 0
            buffer.withUnsafeMutableBufferPointer { rendered = Int(cmod_render($0.baseAddress, 44100)) }
            if rendered == 0 { break }
            loud += buffer.prefix(rendered * 2).filter { $0 != 0 }.count
        }
        cmod_close()
        return (true, type, title, channels, loud, duration)
    }

    func read(_ path: String) -> [UInt8]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return [UInt8](d)
    }

    let music = "/Users/macc/Emulation/Amiga/Music"

    // One of each of the four kinds the collection holds.
    let cases: [(String, String, Int)] = [
        ("\(music)/MACMUSICS/mod.macos", "mod", 4),
        ("\(music)/MACMUSICS/med.macos++", "med", 8),
        ("\(music)/XM/AGONY.XM", "xm", 12),
        ("\(music)/S3M/\((try? FileManager.default.contentsOfDirectory(atPath: "\(music)/S3M"))?.sorted().first(where: { $0.lowercased().hasSuffix(".s3m") }) ?? "")", "s3m", 0),
    ]
    for (path, wantType, wantChannels) in cases {
        guard let bytes = read(path) else { check(false, "\((path as NSString).lastPathComponent) not readable"); continue }
        let r = play(bytes)
        let name = (path as NSString).lastPathComponent
        check(r.opened, "\(name) opened as \(r.type)")
        check(r.type == wantType, "  reported type \"\(r.type)\"")
        if wantChannels > 0 { check(r.channels == wantChannels, "  \(r.channels) channels") }
        check(r.loud > 100_000, "  2s render is audible: \(r.loud)/176400 non-silent samples")
        check(r.seconds > 1, String(format: "  runs %.0f seconds", r.seconds))
    }

    // A title comes out of the file even when the name says nothing.
    if let bytes = read("\(music)/MACMUSICS/mod.macos") {
        check(play(bytes).title == "macos", "the module names itself")
    }

    // Everything the browser calls a module, the engine must be able to open —
    // otherwise Return offers to play something that then does not.
    var recognised = 0, played = 0, mute: [String] = [], refused: [String] = []
    if let walk = FileManager.default.enumerator(atPath: music) {
        for case let rel as String in walk {
            if rel.hasPrefix("SAMPLES") || (rel as NSString).lastPathComponent.hasPrefix(".") { continue }
            let path = "\(music)/\(rel)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
                  let bytes = read(path), ModuleLoader.detect(bytes) != nil else { continue }
            recognised += 1
            let r = play(bytes, seconds: 8)
            if !r.opened { refused.append(rel) } else if r.loud < 1000 { mute.append(rel) } else { played += 1 }
        }
    }
    check(recognised >= 150, "\(recognised) modules recognised in the collection")
    check(refused.isEmpty, "the engine opened every one\(refused.isEmpty ? "" : ", except \(refused.prefix(3))")")
    check(mute.isEmpty, "and every one made a sound\(mute.isEmpty ? "" : "; silent: \(mute.prefix(3))")")
    check(played == recognised, "\(played) of \(recognised) played")

    // Nothing open is not a crash: renders come back silent.
    cmod_close()
    var empty = [Int16](repeating: 0x7FFF, count: 512)
    empty.withUnsafeMutableBufferPointer { _ = cmod_render($0.baseAddress, 256) }
    check(empty.allSatisfy { $0 == 0 }, "rendering with nothing open gives silence")
    check(cmod_channels() == 0 && String(cString: cmod_type()).isEmpty, "and the readers answer with nothing")

    // Rubbish is refused rather than played.
    let rubbish = [UInt8]("this is not a module, it is a sentence".utf8) + [UInt8](repeating: 0x41, count: 4000)
    check(!play(rubbish).opened, "a file of text is refused")

    // --- The Amiga chiptune players, which libopenmpt has no reader for ---
    //
    // These formats carry no magic bytes: the file is a player routine with its
    // data behind it. The only test is to let each player read it and see which
    // one validates it, so what matters here is that the guessing is safe.
    func cflod(_ bytes: [UInt8], seconds: Int = 4) -> (opened: Bool, player: String,
                                                       loud: Int, gaveUp: Bool) {
        let opened = bytes.withUnsafeBufferPointer {
            cflod_open($0.baseAddress, Int32($0.count))
        } == 1
        guard opened else { cflod_close(); return (false, "", 0, false) }
        let who = String(cString: cflod_player_name())
        var loud = 0
        var buffer = [Int16](repeating: 0, count: 44100 * 2)
        for _ in 0..<seconds {
            var rendered = 0
            buffer.withUnsafeMutableBufferPointer { rendered = Int(cflod_render($0.baseAddress, 44100)) }
            if rendered == 0 { break }
            loud += buffer.prefix(rendered * 2).filter { $0 != 0 }.count
        }
        let gaveUp = cflod_gave_up() != 0
        cflod_close()
        return (true, who, loud, gaveUp)
    }

    // The one module in the user's disk images libopenmpt will not open. It is
    // called MUSC, which is exactly the case content detection exists for.
    let alienBreed = "/Users/macc/Emulation/Amiga/harddisks/dh2/!DMS/AlienBreedSE-2.DMS"
    if let img = try? ADFImage(unpacking: URL(fileURLWithPath: alienBreed)) {
        var found = false
        func hunt(_ path: [String], _ depth: Int) {
            guard depth < 6, !found, let entries = try? img.entries(at: path) else { return }
            for entry in entries where !found {
                if entry.isDirectory { hunt(path + [entry.displayName], depth + 1); continue }
                guard let data = try? img.read(entry, at: path) else { continue }
                let bytes = [UInt8](data)
                guard let module = ModuleLoader.detect(bytes),
                      case .soundMon = module.format else { continue }
                found = true
                check(entry.displayName == "MUSC", "found \(entry.displayName), named nothing like a module")
                check(!play(bytes).opened, "libopenmpt has no reader for it")
                let r = cflod(bytes)
                check(r.opened, "c-flod claims it as \(r.player)")
                check(r.player == "BP SoundMon", "  which is the format the bytes said")
                check(r.loud > 100_000, "  and it plays: \(r.loud)/352800 non-silent samples")
                check(!r.gaveUp, "  without hitting a bounds check")
            }
        }
        hunt([], 0)
        check(found, "the SoundMon module was found in AlienBreedSE-2.DMS")
    } else { check(false, "AlienBreedSE-2.DMS did not open") }

    // Nothing that is not music may be claimed. c-flod guesses by trying every
    // player, and the loosest of them scans for 68000 code patterns, so this is
    // the check that keeps Return from offering to play an icon or a library.
    var tried = 0, claimed: [String] = []
    let kinds = ["info", "library", "font", "iff", "device", "datatype", "guide", "c", "s"]
    if let walk = FileManager.default.enumerator(atPath: "/Users/macc/Emulation/Amiga") {
        for case let rel as String in walk {
            guard kinds.contains((rel as NSString).pathExtension.lowercased()),
                  !rel.hasPrefix("Music/"),
                  let data = FileManager.default.contents(atPath: "/Users/macc/Emulation/Amiga/\(rel)"),
                  data.count > 2048 else { continue }
            tried += 1
            if tried > 400 { break }
            let r = cflod([UInt8](data), seconds: 0)
            if r.opened { claimed.append("\(rel) -> \(r.player)") }
        }
    }
    check(tried > 300, "\(tried) non-music Amiga files tried against every chiptune player")
    check(claimed.isEmpty, "none was claimed\(claimed.isEmpty ? "" : ": \(claimed.prefix(3))")")

    // And the tracker modules stay with libopenmpt rather than being grabbed.
    if let mod = FileManager.default.contents(atPath: "\(music)/MACMUSICS/mod.macos") {
        check(!cflod([UInt8](mod), seconds: 0).opened, "a ProTracker module is left to libopenmpt")
    }

    // A bounds check inside c-flod must fail the load, not the process. Feeding
    // it truncated rubbish is the cheapest way to prove the app survives.
    var survived = 0
    for seed in 0..<64 {
        var noise = [UInt8](repeating: 0, count: 8192)
        var value = UInt32(truncatingIfNeeded: seed &* 2654435761 &+ 1)
        for i in 0..<noise.count {
            value = value &* 1664525 &+ 1013904223
            noise[i] = UInt8((value >> 16) & 0xFF)
        }
        _ = cflod(noise, seconds: 0)
        survived += 1
    }
    check(survived == 64, "64 files of noise handed to every player, and the process is still here")
} catch {
    print("  FAIL module engine: \(error)"); failures += 1
}

// --- IFF --------------------------------------------------------------------
print("\n=== IFF")
do {
    /// A picture built by hand, so the decoder is checked against bits whose
    /// answer is known rather than against whatever a disk happens to hold.
    func ilbm(width: Int, height: Int, planes: Int,
              palette: [(UInt8, UInt8, UInt8)], body: [UInt8],
              compression: UInt8 = 0, camg: UInt32? = nil) -> [UInt8] {
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] {
            [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            [UInt8](id.utf8) + be32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
        }
        let bmhd = be16(width) + be16(height) + be16(0) + be16(0)
            + [UInt8(planes), 0, compression, 0] + be16(0) + [10, 11] + be16(width) + be16(height)
        var payload = [UInt8]("ILBM".utf8)
        payload += chunk("BMHD", bmhd)
        payload += chunk("CMAP", palette.flatMap { [$0.0, $0.1, $0.2] })
        if let camg { payload += chunk("CAMG", be32(Int(camg))) }
        payload += chunk("BODY", body)
        return [UInt8]("FORM".utf8) + be32(payload.count) + payload
    }

    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int)? {
        guard let c = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y) else { return nil }
        return (Int(c.redComponent * 255 + 0.5),
                Int(c.greenComponent * 255 + 0.5),
                Int(c.blueComponent * 255 + 0.5))
    }
    func near(_ got: (Int, Int, Int)?, _ want: (Int, Int, Int)) -> Bool {
        guard let got else { return false }
        return abs(got.0 - want.0) <= 2 && abs(got.1 - want.1) <= 2 && abs(got.2 - want.2) <= 2
    }

    // Two planes, sixteen pixels across, two rows. The left half of row one is
    // index 1 and the right half index 2; row two is index 3 throughout.
    let flat: [UInt8] = [0xFF, 0x00, 0x00, 0xFF,
                         0xFF, 0xFF, 0xFF, 0xFF]
    let cmap4: [(UInt8, UInt8, UInt8)] = [(0x11, 0x11, 0x11), (0xFF, 0x11, 0x11),
                                          (0x11, 0xFF, 0x11), (0xFF, 0xFF, 0xFF)]
    let plain = ilbm(width: 16, height: 2, planes: 2, palette: cmap4, body: flat)
    check(IFFLoader.detect(plain) != nil, "a hand built ILBM is recognised")
    do {
        let picture = try ILBMDecoder.decode(plain)
        check(picture.width == 16 && picture.height == 2, "\(picture.width)x\(picture.height) from the BMHD")
        check(near(pixel(picture.image, 0, 0), (0xFF, 0x11, 0x11)), "planes gather into index 1")
        check(near(pixel(picture.image, 8, 0), (0x11, 0xFF, 0x11)), "and into index 2 across the byte")
        check(near(pixel(picture.image, 0, 1), (0xFF, 0xFF, 0xFF)), "and into index 3 on the second row")
        check(abs(picture.heightScale - 11.0 / 10.0) < 0.001, "the 10:11 aspect is carried through")
    } catch { check(false, "hand built ILBM: \(error)") }

    // The same picture packed. One literal run of eight bytes says it all.
    let packed = ilbm(width: 16, height: 2, planes: 2, palette: cmap4,
                      body: [7] + flat, compression: 1)
    do {
        let picture = try ILBMDecoder.decode(packed)
        check(near(pixel(picture.image, 0, 0), (0xFF, 0x11, 0x11))
              && near(pixel(picture.image, 8, 0), (0x11, 0xFF, 0x11))
              && near(pixel(picture.image, 0, 1), (0xFF, 0xFF, 0xFF)),
              "ByteRun1 unpacks to the same picture")
    } catch { check(false, "packed ILBM: \(error)") }

    // A run of the same byte, which the literal case above never exercises.
    let runs = ilbm(width: 16, height: 2, planes: 2, palette: cmap4,
                    body: [0, 0xFF, 0, 0x00, 0, 0x00, 0, 0xFF, UInt8(bitPattern: -3), 0xFF],
                    compression: 1)
    do {
        let picture = try ILBMDecoder.decode(runs)
        check(near(pixel(picture.image, 0, 1), (0xFF, 0xFF, 0xFF)), "a ByteRun1 repeat fills the second row")
    } catch { check(false, "ByteRun1 repeats: \(error)") }

    // Extra Half-Brite: six planes, a palette that stops at 32, and an index
    // of 33, which must come out as colour 1 with every gun halved.
    var ehbBody = [UInt8](repeating: 0, count: 2 * 6)
    ehbBody[0] = 0x80        // plane 0, pixel 0
    ehbBody[10] = 0x80       // plane 5, pixel 0
    var cmap32 = [(UInt8, UInt8, UInt8)](repeating: (0x11, 0x11, 0x11), count: 32)
    cmap32[1] = (0xC8, 0x64, 0x32)
    let ehb = ilbm(width: 16, height: 1, planes: 6, palette: cmap32, body: ehbBody, camg: 0x0080)
    do {
        let picture = try ILBMDecoder.decode(ehb)
        check(picture.mode.contains("EHB"), "six planes and 32 colours read as EHB — \(picture.mode)")
        check(near(pixel(picture.image, 0, 0), (0x64, 0x32, 0x19)), "index 33 is colour 1 halved")
    } catch { check(false, "EHB: \(error)") }

    // Hold-and-modify: pixel one takes colour 1, pixel two holds it and
    // replaces red with full scale.
    var hamBody = [UInt8](repeating: 0, count: 2 * 6)
    hamBody[0] = 0x80                    // plane 0: pixel 0 -> control 00, data 1
    hamBody[10] = 0x40                   // plane 5: pixel 1 -> control 10 (red)
    for plane in 0..<4 { hamBody[plane * 2] |= 0x40 }   // data 15 on pixel 1
    var cmapHAM = [(UInt8, UInt8, UInt8)](repeating: (0x11, 0x11, 0x11), count: 16)
    cmapHAM[1] = (0x11, 0x22, 0x33)
    let ham = ilbm(width: 16, height: 1, planes: 6, palette: cmapHAM, body: hamBody, camg: 0x0800)
    do {
        let picture = try ILBMDecoder.decode(ham)
        check(picture.mode.contains("HAM6"), "six planes with the HAM bit read as HAM6 — \(picture.mode)")
        check(near(pixel(picture.image, 0, 0), (0x11, 0x22, 0x33)), "a control 00 pixel is a palette index")
        check(near(pixel(picture.image, 1, 0), (0xFF, 0x22, 0x33)), "and the next holds it, replacing red")
    } catch { check(false, "HAM6: \(error)") }

    // A palette written the way an OCS painter wrote one: four bits a gun,
    // parked in the high nibble. Taken as read it renders at half brightness.
    let dim: [(UInt8, UInt8, UInt8)] = [(0x00, 0x00, 0x00), (0xF0, 0x80, 0x00),
                                        (0x00, 0xF0, 0x00), (0xF0, 0xF0, 0xF0)]
    do {
        let picture = try ILBMDecoder.decode(ilbm(width: 16, height: 2, planes: 2,
                                                  palette: dim, body: flat))
        check(near(pixel(picture.image, 0, 0), (0xFF, 0x88, 0x00)), "a four bit palette is widened, not halved")
    } catch { check(false, "OCS palette: \(error)") }

    // How big a preview draws a picture. Shrinking is free; growing goes in
    // whole steps, or some rows of a pixel-drawn picture come out two screen
    // pixels tall and their neighbours three.
    do {
        let box = CGSize(width: 720, height: 520)
        // A lores 320x200 at 10:11 is 320x220 true to shape, so it doubles.
        let lores = DecodedPicture.displaySize(width: 320, height: 200, heightScale: 1.1, within: box)
        check(lores == CGSize(width: 640, height: 440), "320x200 lores is drawn at \(lores)")
        // Hires 640x200 has half-width pixels: 640x440, which already fits.
        let hires = DecodedPicture.displaySize(width: 640, height: 200, heightScale: 2.2, within: box)
        check(hires == CGSize(width: 640, height: 440), "640x200 hires is drawn at \(hires)")
        // Bigger than the box shrinks to fit, whole steps or not.
        let big = DecodedPicture.displaySize(width: 1440, height: 1024, heightScale: 1, within: box)
        check(big.width <= box.width && big.height <= box.height && big.width == 720,
              "a 1440x1024 picture is shrunk to \(big)")
        // A tiny brush grows a long way, but still by a whole number.
        let brush = DecodedPicture.displaySize(width: 28, height: 17, heightScale: 1, within: box)
        check(brush.width.truncatingRemainder(dividingBy: 28) == 0,
              "a 28x17 brush grows by a whole number to \(brush)")
    }

    // Nonsense must be refused rather than drawn.
    check(IFFLoader.detect([UInt8]("FORM".utf8) + [0, 0, 0, 4] + [UInt8]("JUNK".utf8)) == nil,
          "an unknown FORM type is not claimed")
    check(IFFLoader.detect([UInt8](repeating: 0x41, count: 512)) == nil, "a file of text is not claimed")
    var truncated = plain
    truncated.removeLast(truncated.count / 2)
    _ = try? ILBMDecoder.decode(truncated)
    check(true, "a truncated picture does not take the process with it")

    // And then the real thing, when this machine has a collection.
    let places = ["~/Emulation/Amiga/Floppys", "~/Emulation/Amiga/FS-UAE/Floppies"]
        .map { NSString(string: $0).expandingTildeInPath }
    var adfs: [String] = []
    for place in places {
        adfs += ((try? FileManager.default.contentsOfDirectory(atPath: place)) ?? [])
            .filter { $0.lowercased().hasSuffix(".adf") }
            .map { "\(place)/\($0)" }
    }

    if adfs.isEmpty {
        print("  --   no ADF collection on this machine, skipping the collection sweep")
    } else {
        var found = 0, drawn = 0, samples = 0, anims = 0, flatOnes = 0
        var refused: [String] = []
        var modes: Set<String> = []

        let hardfile = NSString(string: "~/Emulation/Amiga/harddisks/system.HDF").expandingTildeInPath
        var disks: [(String, DiskImage)] = []
        for path in adfs.sorted() {
            if let image = try? ADFImage(url: URL(fileURLWithPath: path)) { disks.append((path, image)) }
        }
        if FileManager.default.fileExists(atPath: hardfile),
           let image = try? HDFImage(url: URL(fileURLWithPath: hardfile)) {
            disks.append((hardfile, image))
        }

        for (_, image) in disks {
            func walk(_ at: [String], _ depth: Int) {
                guard depth < 8, let list = try? image.entries(at: at) else { return }
                for entry in list {
                    if entry.isDirectory { walk(at + [entry.displayName], depth + 1); continue }
                    guard let data = try? image.read(entry, at: at) else { continue }
                    let bytes = [UInt8](data)
                    guard let form = IFFLoader.detect(bytes) else { continue }
                    if case .eightSVX = form { samples += 1; continue }
                    if case .anim = form { anims += 1 }
                    found += 1
                    do {
                        let picture = try ILBMDecoder.decode(bytes)
                        drawn += 1
                        for part in picture.mode.components(separatedBy: " · ") { modes.insert(part) }
                        // A picture that came out one flat colour usually means
                        // the planes were read wrong rather than that someone
                        // saved an empty screen. Sampled over a grid: three
                        // points on a patterned icon land on the same colour
                        // often enough to mean nothing.
                        var seen: Set<String> = []
                        for gy in 0..<8 {
                            for gx in 0..<8 {
                                let x = gx * max(1, picture.width - 1) / 7
                                let y = gy * max(1, picture.height - 1) / 7
                                if let c = pixel(picture.image, min(x, picture.width - 1),
                                                 min(y, picture.height - 1)) {
                                    seen.insert("\(c.0),\(c.1),\(c.2)")
                                }
                            }
                        }
                        if seen.count <= 1 { flatOnes += 1 }
                    } catch {
                        refused.append("\(entry.displayName): "
                                       + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
                    }
                }
            }
            walk([], 0)
        }

        check(found > 0, "\(found) pictures, \(samples) samples and \(anims) animations found in \(disks.count) disks")
        check(refused.isEmpty, "every one of them decoded\(refused.isEmpty ? "" : ": \(refused.prefix(3))")")
        check(drawn == found, "\(drawn) of \(found) drawn")
        check(flatOnes * 4 < max(1, drawn), "\(flatOnes) of \(drawn) came out a single flat colour")
        print("      modes seen: \(modes.sorted().joined(separator: ", "))")
    }
} catch {
    print("  FAIL IFF: \(error)"); failures += 1
}

// --- C64 pictures -----------------------------------------------------------
print("\n=== C64 pictures")
do {
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int)? {
        guard let c = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y) else { return nil }
        return (Int(c.redComponent * 255 + 0.5),
                Int(c.greenComponent * 255 + 0.5),
                Int(c.blueComponent * 255 + 0.5))
    }
    func colour(_ index: Int) -> (Int, Int, Int) {
        let c = VICII.colours[index]
        return (Int(c.0), Int(c.1), Int(c.2))
    }
    /// The bitmap byte holding the top row of the character cell at `column`
    /// of the top character row.
    func cell(_ column: Int) -> Int { column * 8 }

    // A Koala: the first cell of the bitmap holds one of each bit pair, so the
    // four sources of colour in multicolour mode are all exercised on one row.
    var koala = [UInt8](repeating: 0, count: 10003)
    koala[0] = 0x00; koala[1] = 0x60                 // load $6000
    koala[2 + cell(0)] = 0b00_01_10_11               // background, screen high, low, colour
    koala[2 + 8000] = 0x71                           // screen: 7 yellow over 1 white
    koala[2 + 9000] = 0x0D                           // colour RAM: 13 light green
    koala[2 + 10000] = 0x06                          // background: 6 blue

    if let format = C64Picture.detect(name: "SUNSET", bytes: koala) {
        check(format.name == "Koala Painter", "10003 bytes at $6000 is \(format.name)")
    } else {
        check(false, "a Koala is not recognised")
    }
    do {
        let picture = try PictureLoader.decode(name: "SUNSET", bytes: koala)
        check(picture.width == 320 && picture.height == 200,
              "a Koala is \(picture.width) × \(picture.height)")
        // Every pair is two screen pixels wide, so read the first of each.
        check(pixel(picture.image, 0, 0).map { $0 == colour(6) } == true, "00 is the background")
        check(pixel(picture.image, 2, 0).map { $0 == colour(7) } == true, "01 is the screen's high nibble")
        check(pixel(picture.image, 4, 0).map { $0 == colour(1) } == true, "10 is its low nibble")
        check(pixel(picture.image, 6, 0).map { $0 == colour(13) } == true, "11 is colour RAM")
        check(pixel(picture.image, 1, 0).map { $0 == colour(6) } == true,
              "and a multicolour pixel is two screen pixels wide")
        check(abs(picture.heightScale - VICII.pixelHeightScale) < 0.0001,
              "a C64 picture carries the PAL pixel shape")
    } catch { check(false, "Koala: \(error)") }

    // A cell well away from the origin, which is what catches a row stride
    // taken for a cell stride: character row 7, column 11, the fifth raster
    // line down, with that cell's own colour RAM entry to read. Nothing else
    // out there is set, so it is the only pixel that may differ from the
    // background.
    var stride = koala
    stride[2 + (7 * 40 + 11) * 8 + 4] = 0b11_00_00_00
    stride[2 + 9000 + 7 * 40 + 11] = 0x0D
    do {
        let picture = try PictureLoader.decode(name: "PIC", bytes: stride)
        check(pixel(picture.image, 11 * 8, 7 * 8 + 4).map { $0 == colour(13) } == true,
              "a cell 7 rows down and 11 across lands where it should")
        check(pixel(picture.image, 11 * 8, 7 * 8 + 5).map { $0 == colour(6) } == true,
              "and the raster line below it is still background")
    } catch { check(false, "Koala stride: \(error)") }

    // Paint Magic saves the picture inside the program that shows it, which is
    // why the bitmap starts 114 bytes in rather than at the front: the display
    // code is what lands between the load address and the $2000 boundary the
    // VIC needs the bitmap on. Its offsets are that code's own — it reads the
    // background from $5F40 and fills the whole of colour RAM from $5F43, so
    // one byte stands in for the page every other multicolour format saves.
    var magic = [UInt8](repeating: 0, count: 9332)
    magic[0] = 0x8E; magic[1] = 0x3F                 // load $3F8E
    magic[2 + 114 + cell(0)] = 0b00_01_10_11
    magic[2 + 114 + (7 * 40 + 11) * 8] = 0b11_00_00_00
    magic[2 + 8306] = 0x71                           // $6000 screen: 7 over 1
    magic[2 + 8114] = 0x06                           // $5F40 background: blue
    magic[2 + 8117] = 0x0D                           // $5F43 colour RAM: light green
    do {
        let picture = try PictureLoader.decode(name: "01 ABEL", bytes: magic)
        check(picture.format == "Paint Magic", "9332 bytes at $3F8E is \(picture.format)")
        check(pixel(picture.image, 0, 0).map { $0 == colour(6) } == true,
              "the background comes from $5F40")
        check(pixel(picture.image, 2, 0).map { $0 == colour(7) } == true,
              "the bitmap starts past the display code")
        check(pixel(picture.image, 4, 0).map { $0 == colour(1) } == true,
              "and the video matrix past the gap at the end of it")
        check(pixel(picture.image, 6, 0).map { $0 == colour(13) } == true,
              "the fourth colour is the one byte at $5F43")
        // The same byte serves every cell, which is the whole point of it:
        // a cell that carries no colour of its own still gets that one.
        check(pixel(picture.image, 11 * 8, 7 * 8).map { $0 == colour(13) } == true,
              "and every other cell reads that same byte")
    } catch { check(false, "Paint Magic: \(error)") }

    // The same bytes at Interpaint's address are Interpaint, not Koala.
    var interpaint = koala
    interpaint[1] = 0x40
    check(C64Picture.detect(name: "PIC", bytes: interpaint)?.name == "Interpaint",
          "the load address is what tells two identical layouts apart")

    // Art Studio: one bit a pixel, both colours out of the video matrix.
    var studio = [UInt8](repeating: 0, count: 9009)
    studio[0] = 0x00; studio[1] = 0x20               // load $2000
    studio[2 + cell(0)] = 0b1010_0000
    studio[2 + 8000] = 0x2F                          // 2 red set, 15 light grey clear
    do {
        let picture = try PictureLoader.decode(name: "PIC", bytes: studio)
        check(picture.format == "Art Studio", "9009 bytes at $2000 is \(picture.format)")
        check(pixel(picture.image, 0, 0).map { $0 == colour(2) } == true, "a set bit is the high nibble")
        check(pixel(picture.image, 1, 0).map { $0 == colour(15) } == true, "and a clear bit the low one")
    } catch { check(false, "Art Studio: \(error)") }

    // Doodle puts the video matrix first and pads both pieces to whole pages.
    var doodle = [UInt8](repeating: 0, count: 9218)
    doodle[0] = 0x00; doodle[1] = 0x5C               // load $5C00
    doodle[2 + 1024 + cell(0)] = 0b1000_0000
    doodle[2 + 0] = 0x2F
    do {
        let picture = try PictureLoader.decode(name: "PIC", bytes: doodle)
        check(picture.format == "Doodle", "9218 bytes at $5C00 is \(picture.format)")
        check(pixel(picture.image, 0, 0).map { $0 == colour(2) } == true,
              "the screen comes before the bitmap")
    } catch { check(false, "Doodle: \(error)") }

    // FLI: eight video matrices, one per raster line of the character row, and
    // the leftmost three columns cut off as the artefact they are.
    var fli = [UInt8](repeating: 0, count: 17474)
    fli[0] = 0x00; fli[1] = 0x3B                     // load $3B00
    for line in 0..<8 {
        fli[2 + 0x2500 + cell(3) + line] = 0b0101_0101      // every pair is 01
        fli[2 + 0x500 + line * 1024 + 3] = UInt8(line << 4) // a different colour each line
    }
    do {
        let picture = try PictureLoader.decode(name: "PIC", bytes: fli)
        check(picture.format == "Blackmail FLI", "17474 bytes at $3B00 is \(picture.format)")
        check(picture.width == 296, "the FLI bug columns are cut, leaving \(picture.width)")
        check(pixel(picture.image, 0, 0).map { $0 == colour(0) } == true,
              "column 3 is the first one drawn")
        check(pixel(picture.image, 0, 3).map { $0 == colour(3) } == true,
              "and each raster line reads its own video matrix")
    } catch { check(false, "FLI: \(error)") }

    // Amica Paint: Koala's layout, run through a byte packer. Everything after
    // the bitmap's opening cell is one long run of zeroes.
    var amica: [UInt8] = [0x00, 0x40]
    amica += [0b00_01_10_11]
    var left = 10001 - 1
    while left > 0 {
        let run = min(left, 255)
        amica += [0xC2, UInt8(run), 0x00]
        left -= run
    }
    amica += [0xC2, 0x00]
    check(C64Picture.unpackAmica(amica)?.count == 10001, "an Amica Paint file unpacks to a picture")
    check(C64Picture.detect(name: "PIC", bytes: amica)?.name == "Amica Paint",
          "and is recognised by unpacking rather than by its size")
    check(C64Picture.unpackAmica([0x00, 0x40, 0x41, 0x42]) == nil,
          "a short file at the same address is not claimed")

    // Nothing else is. The sizes are exact and the addresses with them.
    check(C64Picture.detect(name: "PIC", bytes: [UInt8](repeating: 0, count: 10003)) == nil,
          "10003 bytes at $0000 is not a Koala")
    check(C64Picture.detect(name: "HELLO", bytes: [0x01, 0x08] + [UInt8](repeating: 0x41, count: 2000)) == nil,
          "an ordinary PRG is not claimed")
    var short = koala
    short.removeLast(3)
    check(C64Picture.detect(name: "SUNSET", bytes: short) == nil,
          "and neither is a Koala three bytes short of one")
}

// --- 8SVX -------------------------------------------------------------------
print("\n=== IFF 8SVX")
do {
    func svx(rate: Int, oneShot: Int, repeatLength: Int, octaves: Int = 1,
             compression: UInt8 = 0, body: [UInt8], name: String? = nil) -> [UInt8] {
        func be32(_ v: Int) -> [UInt8] {
            [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
        }
        func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            [UInt8](id.utf8) + be32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
        }
        let vhdr = be32(oneShot) + be32(repeatLength) + be32(0)
            + [UInt8(rate >> 8 & 0xFF), UInt8(rate & 0xFF), UInt8(octaves), compression]
            + be32(0x10000)
        var payload = [UInt8]("8SVX".utf8) + chunk("VHDR", vhdr)
        if let name { payload += chunk("NAME", [UInt8](name.utf8)) }
        payload += chunk("BODY", body)
        return [UInt8]("FORM".utf8) + be32(payload.count) + payload
    }

    let wave: [UInt8] = (0..<64).map { UInt8(bitPattern: Int8(truncatingIfNeeded: $0 * 4 - 128)) }
    let oneShot = svx(rate: 16726, oneShot: 64, repeatLength: 0, body: wave, name: "test tone")
    check(IFFLoader.detect(oneShot) != nil, "a hand built 8SVX is recognised")
    do {
        let sound = try EightSVXDecoder.decode(oneShot)
        check(sound.frames.count == 64, "\(sound.frames.count) frames from the VHDR lengths")
        check(sound.sampleRate == 16726, "\(Int(sound.sampleRate)) Hz from the header")
        check(sound.name == "test tone", "the NAME chunk becomes the title")
        check(sound.loop == nil, "a one-shot has no loop")
        check(sound.frames[0] == Int16(Int8(bitPattern: 128)) << 8, "eight bit samples widen to sixteen")
        check(abs(sound.duration - 64.0 / 16726.0) < 0.0001, "and the duration follows from both")
    } catch { check(false, "hand built 8SVX: \(error)") }

    do {
        let looped = try EightSVXDecoder.decode(
            svx(rate: 8363, oneShot: 16, repeatLength: 48, body: wave))
        check(looped.loop == 16..<64, "an instrument's loop is the tail after the attack")
    } catch { check(false, "looping 8SVX: \(error)") }

    // A rate of zero is not silence, it is a writer that left the field out.
    do {
        let odd = try EightSVXDecoder.decode(svx(rate: 0, oneShot: 64, repeatLength: 0, body: wave))
        check(odd.sampleRate == 8363, "a missing rate falls back to the tracker default")
    } catch { check(false, "rateless 8SVX: \(error)") }

    // Fibonacci-delta is refused rather than played as noise.
    do {
        _ = try EightSVXDecoder.decode(
            svx(rate: 16726, oneShot: 64, repeatLength: 0, compression: 1, body: wave))
        check(false, "a compressed sample should have been refused")
    } catch {
        check("\((error as? LocalizedError)?.errorDescription ?? "")".contains("Fibonacci"),
              "a Fibonacci-delta sample is refused by name")
    }

    // And the collection, which is loose files on the Mac rather than inside
    // any disk: 8SVX is what a sampler wrote straight to a floppy.
    let samples = NSString(string: "~/Emulation/Amiga/Music/SAMPLES").expandingTildeInPath
    if let walk = FileManager.default.enumerator(atPath: samples) {
        var found = 0, decoded = 0, looping = 0, longest = 0.0
        var refused: [String] = []
        var rates: Set<Int> = []
        for case let rel as String in walk {
            guard let data = FileManager.default.contents(atPath: "\(samples)/\(rel)") else { continue }
            let bytes = [UInt8](data)
            guard case .eightSVX? = IFFLoader.detect(bytes) else { continue }
            found += 1
            do {
                let sound = try EightSVXDecoder.decode(bytes)
                decoded += 1
                rates.insert(Int(sound.sampleRate))
                if sound.loop != nil { looping += 1 }
                longest = max(longest, sound.duration)
                if sound.frames.isEmpty { refused.append("\(rel): decoded to nothing") }
            } catch {
                refused.append("\(rel): "
                               + ((error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
        if found == 0 {
            print("  --   no 8SVX collection on this machine, skipping the sweep")
        } else {
            check(decoded == found, "\(decoded) of \(found) samples decoded")
            check(refused.isEmpty, "none was refused\(refused.isEmpty ? "" : ": \(refused.prefix(3))")")
            check(looping > 0, "\(looping) of them carry a loop point")
            print(String(format: "      longest %.1fs, %d distinct rates", longest, rates.count))
        }
    }
} catch {
    print("  FAIL 8SVX: \(error)"); failures += 1
}


// --- The notice at the start -------------------------------------------------
print("\n=== the backup notice")
do {
    // A settings store reads the defaults domain this tool writes into, which
    // the drag section clears at the end, so start from a known state.
    UserDefaults.standard.removeObject(forKey: "theme.v1")

    let first = SettingsStore()
    check(!first.splashSeen, "on a fresh install the notice has not been read")
    check(!first.splashAtEveryStart, "and showing it every time is off to begin with")

    let model = AppModel(settings: first)
    model.showSplashIfNeeded()
    check(model.sheet?.id == "splash", "so the first start shows it")
    model.showSplashIfNeeded()
    check(model.sheet?.id == "splash", "and asking twice in one launch shows one, not two")
    model.dismissSplash()
    check(model.sheet == nil, "continuing puts it away")
    check(first.splashSeen, "and remembers that it was read")

    // A second launch: same stored settings, a new object to read them.
    let second = SettingsStore()
    check(second.splashSeen, "which survives into the next launch")
    let later = AppModel(settings: second)
    later.showSplashIfNeeded()
    check(later.sheet == nil, "so it does not come back")

    second.splashAtEveryStart = true
    let asked = AppModel(settings: SettingsStore())
    asked.showSplashIfNeeded()
    check(asked.sheet?.id == "splash", "unless it has been asked for at every start")
    asked.dismissSplash()

    // Something already on screen is not elbowed aside by it.
    let busy = AppModel(settings: SettingsStore())
    busy.sheet = .help
    busy.showSplashIfNeeded()
    check(busy.sheet?.id == "help", "and it never takes the place of a dialog already up")
    busy.sheet = nil

    UserDefaults.standard.removeObject(forKey: "theme.v1")
}

// --- Folder sync -------------------------------------------------------------
print("\n=== folder sync")
do {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: scratch).appendingPathComponent("sync-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let cancel = SyncCancel()

    /// A file, made where it is asked for, with the folders it needs.
    @discardableResult
    func put(_ text: String, _ path: String, in side: URL) throws -> URL {
        let url = path.split(separator: "/").reduce(side) { $0.appendingPathComponent(String($1)) }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func scan(_ side: URL, baseline: [String: SyncEntry] = [:],
              hidden: Bool = false) throws -> SyncScan {
        try SyncScanner.scan(root: side, includeHidden: hidden, baseline: baseline, cancel: cancel)
    }
    func entry(_ path: String, _ hash: String, size: Int64 = 10,
               dir: Bool = false) -> SyncEntry {
        SyncEntry(path: path, isDirectory: dir, isPackage: false, size: size,
                  modified: 1_000_000, hash: hash)
    }

    // --- the walk
    let left = root.appendingPathComponent("left")
    let right = root.appendingPathComponent("right")
    try put("alpha", "a.txt", in: left)
    try put("deep", "sub/deep.txt", in: left)
    try put("image", "disk.d64", in: left)
    try put("secret", ".hidden", in: left)
    try fm.createDirectory(at: left.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: left.appendingPathComponent("link"),
                              withDestinationURL: left.appendingPathComponent("a.txt"))

    var walked = try scan(left)
    check(walked.entries["sub/deep.txt"] != nil, "the walk reaches into subfolders and keys by relative path")
    check(walked.entries["disk.d64"]?.isDirectory == false, "a disk image is one leaf, not a folder to walk into")
    check(walked.entries["empty"]?.isDirectory == true, "an empty folder is an entry of its own")
    check(walked.entries[".hidden"] == nil, "hidden files stay out when the panels are hiding them")
    check(walked.problems.contains { $0.path == "link" }, "a symbolic link is skipped and said so")
    check(walked.entries["link"] == nil, "and never followed")
    walked = try scan(left, hidden: true)
    check(walked.entries[".hidden"] != nil, "and come back in when the panels show them")

    // --- the hash
    try put("same", "x.txt", in: right)
    try put("same", "y.txt", in: right)
    try put("other", "z.txt", in: right)
    let rightScan = try scan(right)
    check(rightScan.entries["x.txt"]?.hash == rightScan.entries["y.txt"]?.hash,
          "two files with the same bytes hash the same")
    check(rightScan.entries["x.txt"]?.hash != rightScan.entries["z.txt"]?.hash,
          "and one byte different hashes differently")

    // A file past the chunk size, which is what catches a streaming bug.
    let big = root.appendingPathComponent("big.bin")
    var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024)
    for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 13) }
    let blob = Data(bytes)
    try blob.write(to: big)
    let whole: String = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
    let streamed: String = try SyncScanner.fileHash(big, cancel: cancel)
    check(streamed == whole,
          "a 3 MB file streamed in chunks hashes the same as hashing it whole")

    // --- the fast path
    let seeded = try scan(left).entries
    let again = try SyncScanner.scan(root: left, includeHidden: false,
                                     baseline: seeded, cancel: cancel)
    check(again.bytesHashed == 0, "size and date matching the record means no file is read again")
    check(again.entries["a.txt"]?.hash == seeded["a.txt"]?.hash, "and the recorded hash is carried over")
    try put("alpha changed", "a.txt", in: left)
    let touched = try SyncScanner.scan(root: left, includeHidden: false,
                                       baseline: seeded, cancel: cancel)
    check(touched.bytesHashed > 0, "a file that has moved on is read again")
    check(touched.entries["a.txt"]?.hash != seeded["a.txt"]?.hash, "and hashes differently")
    let forced = try SyncScanner.scan(root: left, includeHidden: false,
                                      baseline: seeded, hashEverything: true, cancel: cancel)
    check(forced.bytesHashed > 0, "and asking for every file to be hashed ignores the record")

    // --- the table, on hand-built dictionaries: no file system, no waiting
    func verdict(_ b: SyncEntry?, _ l: SyncEntry?, _ r: SyncEntry?,
                 deletions: Bool = true, hasBaseline: Bool = true) -> SyncEngine.Verdict? {
        SyncEngine.classify(baseline: b, left: l, right: r,
                            propagateDeletions: deletions, hasBaseline: hasBaseline)
    }
    let A = entry("f", "aaa"), B = entry("f", "bbb"), C = entry("f", "ccc")

    check(verdict(A, A, A) == nil, "a file none of the three disagree about has nothing to report")
    check(verdict(nil, A, nil)?.kind == .newOnLeft, "present on the left alone is new there")
    check(verdict(nil, A, nil)?.action == .copyToRight, "and the suggestion is to send it across")
    check(verdict(nil, nil, A)?.kind == .newOnRight, "and the mirror holds")
    check(verdict(nil, A, A) == nil, "the same file appearing on both sides needs nothing")
    check(verdict(nil, A, B)?.kind == .conflictBothAdded, "two different files at one new path is a conflict")
    check(verdict(A, B, A)?.kind == .changedOnLeft, "the side that moved away from the record is the one that changed")
    check(verdict(A, B, A)?.action == .copyToRight, "and its version is the one to send")
    check(verdict(A, A, B)?.kind == .changedOnRight, "and the mirror holds")
    check(verdict(A, B, B) == nil, "the same edit made on both sides is nothing to do")
    check(verdict(A, B, C)?.kind == .conflictBothChanged, "different edits on both sides is a conflict")
    check(verdict(A, B, C)?.action == .skip, "and a conflict suggests doing nothing")
    check(verdict(A, A, nil)?.kind == .deletedOnRight, "gone from one side, unchanged on the other, is a deletion")
    check(verdict(A, A, nil)?.action == .deleteLeft, "which is carried over")
    check(verdict(A, nil, A)?.action == .deleteRight, "and the mirror holds")
    check(verdict(A, B, nil)?.kind == .conflictChangedAndDeleted(changed: .left),
          "changed here and deleted there is a conflict, not a deletion")
    check(verdict(A, nil, nil) == nil, "gone from both sides is simply gone")
    check(verdict(nil, A, entry("f", "", dir: true))?.kind == .conflictTypeMismatch(folderOn: .right),
          "a folder on one side and a file on the other is never resolved on its own")
    check(verdict(nil, entry("f", "", dir: true), A)?.kind == .conflictTypeMismatch(folderOn: .left),
          "and the verdict says which side holds the folder")

    // Deletions switched off change the suggestion and nothing else.
    check(verdict(A, A, nil, deletions: false)?.kind == .deletedOnRight,
          "with deletions off the verdict is unchanged")
    check(verdict(A, A, nil, deletions: false)?.action == .skip, "but nothing is suggested")
    check(verdict(A, A, nil, deletions: false)?.allowed.allMatch { !$0.isDestructive } == true,
          "and the row will not even offer one")

    // --- every verdict says which side the change was made on
    //
    // The report exists to answer "which of these two folders moved", so a
    // verdict that leaves the side to be worked out from the suggested action
    // is asking the reader to reason backwards from the fix to the fact.
    let everyKind: [SyncKind] = [
        .newOnLeft, .newOnRight, .changedOnLeft, .changedOnRight,
        .deletedOnLeft, .deletedOnRight, .renamedOnLeft, .renamedOnRight,
        .conflictBothChanged, .conflictBothAdded, .conflictBothRenamed,
        .conflictChangedAndDeleted(changed: .left),
        .conflictChangedAndDeleted(changed: .right),
        .conflictCaseOnly(side: .left), .conflictTypeMismatch(folderOn: .left),
        .possibleRename, .unreadable(side: .left), .unreadable(side: nil),
    ]
    let sideless = everyKind.filter { kind in
        let l = kind.label.lowercased()
        return !l.contains("left") && !l.contains("right") && !l.contains("both")
    }
    check(sideless.map(\.label) == ["Maybe renamed"],
          "every verdict but the one that genuinely cannot know names a side — \(sideless.map(\.label))")
    check(SyncKind.renamedOnLeft.label != SyncKind.renamedOnRight.label,
          "a rename says which side it happened on")
    check(SyncKind.conflictChangedAndDeleted(changed: .left).label
          != SyncKind.conflictChangedAndDeleted(changed: .right).label,
          "and so does a file changed on one side and deleted on the other")
    check(SyncKind.conflictTypeMismatch(folderOn: .left).label
          != SyncKind.conflictTypeMismatch(folderOn: .right).label,
          "and so does a folder meeting a file")
    check(SyncKind.unreadable(side: .left).label != SyncKind.unreadable(side: .right).label,
          "and so does something that could not be read")
    check(SyncProblem(side: .right, path: "x", cause: .symbolicLink).text.contains("right"),
          "and the list of what was left alone says which folder each path was in")

    // "Maybe renamed" cannot name a side — that is what makes it a maybe — so
    // its note has to carry both names and say where each one is.
    var maybeL = SyncScan(root: left), maybeR = SyncScan(root: right)
    maybeL.entries = ["here.txt": entry("here.txt", "aaa")]
    maybeR.entries = ["there.txt": entry("there.txt", "aaa")]
    let maybe = SyncEngine.plan(left: maybeL, right: maybeR, baseline: nil,
                                propagateDeletions: true)
    let maybeRow = maybe.rows.first { $0.kind == .possibleRename }
    check(maybeRow != nil, "the same content under two names with no record is a maybe")
    check(maybeRow?.note?.contains("here.txt on the left") == true
          && maybeRow?.note?.contains("there.txt on the right") == true,
          "and its note says which name is on which side")
    check(maybeRow?.leftName == "here.txt" && maybeRow?.rightName == "there.txt",
          "with both names recorded against their sides, so renaming either way works")

    // --- a first run proposes no deletion anywhere
    let freshLeft = root.appendingPathComponent("fresh-left")
    let freshRight = root.appendingPathComponent("fresh-right")
    try put("only here", "mine.txt", in: freshLeft)
    try put("only there", "theirs.txt", in: freshRight)
    try put("shared", "both.txt", in: freshLeft)
    try put("shared", "both.txt", in: freshRight)
    let first = SyncEngine.plan(left: try scan(freshLeft), right: try scan(freshRight),
                                baseline: nil, propagateDeletions: true)
    check(!first.hasBaseline, "with no record of an earlier sync the plan says so")
    check(first.rows.allMatch { !$0.action.isDestructive },
          "and a first run proposes no deletion at all, whatever the setting says")
    check(first.settled["both.txt"] != nil, "a file already matching seeds the record")
    check(!first.rows.contains { $0.path == "both.txt" }, "and is not reported as a difference")

    // --- renames
    var base: [String: SyncEntry] = ["old.txt": entry("old.txt", "aaa")]
    var l = SyncScan(root: left), r = SyncScan(root: right)
    l.entries = ["new.txt": entry("new.txt", "aaa")]
    r.entries = ["old.txt": entry("old.txt", "aaa")]
    var renamed = SyncEngine.plan(left: l, right: r, baseline: base, propagateDeletions: true)
    check(renamed.rows.count == 1, "a rename is one row, not an add and a delete")
    check(renamed.rows.first?.kind == .renamedOnLeft, "and reads as a rename")
    check(renamed.rows.first?.renamedFrom == "old.txt" && renamed.rows.first?.path == "new.txt",
          "naming both ends of it")
    check(renamed.rows.first?.action == .renameOnRight, "to be applied as a move on the other side")

    // One file gone and one arrived is still unambiguous even when a third
    // file shares their content, because the third one never moved.
    base = ["one.txt": entry("one.txt", "aaa"), "still.txt": entry("still.txt", "aaa")]
    l.entries = ["new.txt": entry("new.txt", "aaa"), "still.txt": entry("still.txt", "aaa")]
    r.entries = base
    let oneMoved = SyncEngine.plan(left: l, right: r, baseline: base, propagateDeletions: true)
    check(oneMoved.rows.first(where: { $0.kind == .renamedOnLeft })?.renamedFrom == "one.txt",
          "a file that shares its content with one that never moved still pairs")

    // Two gone and two arrived is the real ambiguity: nothing anywhere says
    // which of them became which.
    base = ["one.txt": entry("one.txt", "aaa"), "two.txt": entry("two.txt", "aaa")]
    l.entries = ["newA.txt": entry("newA.txt", "aaa"), "newB.txt": entry("newB.txt", "aaa")]
    r.entries = base
    let ambiguous = SyncEngine.plan(left: l, right: r, baseline: base, propagateDeletions: true)
    check(ambiguous.rows.allMatch { $0.renamedFrom == nil },
          "two files with the same content give no evidence of which was renamed, so neither is")
    check(ambiguous.rows.contains { $0.kind == .newOnLeft } &&
          ambiguous.rows.contains { $0.kind == .deletedOnLeft },
          "and they stay reported as plain arrivals and departures")

    // Every empty file shares one hash, so none of them may ever pair.
    let emptyHash = try SyncScanner.fileHash({ let u = root.appendingPathComponent("e");
                                               try! Data().write(to: u); return u }(), cancel: cancel)
    base = ["gone.txt": entry("gone.txt", emptyHash, size: 0)]
    l.entries = ["added.txt": entry("added.txt", emptyHash, size: 0)]
    r.entries = ["gone.txt": entry("gone.txt", emptyHash, size: 0)]
    let empties = SyncEngine.plan(left: l, right: r, baseline: base, propagateDeletions: true)
    check(empties.rows.allMatch { $0.renamedFrom == nil },
          "empty files never pair as renames: they all hash alike")

    // --- a folder that will not open makes no claim about what is inside it
    let blindLeft = root.appendingPathComponent("blind-left")
    let blindRight = root.appendingPathComponent("blind-right")
    try put("one", "locked/a.txt", in: blindLeft)
    try put("two", "locked/b.txt", in: blindLeft)
    try put("keep", "open.txt", in: blindLeft)
    try put("keep", "open.txt", in: blindRight)
    let lockedDir = blindRight.appendingPathComponent("locked")
    try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
    try put("two", "locked/b.txt", in: blindRight)
    try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedDir.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path) }

    let blindScan = try scan(blindRight)
    check(!blindScan.blindDirectories.isEmpty, "a folder that will not open is recorded as such")
    let blindPlan = SyncEngine.plan(left: try scan(blindLeft), right: blindScan,
                                    baseline: ["locked/a.txt": entry("locked/a.txt", "aaa")],
                                    propagateDeletions: true)
    check(blindPlan.blind, "and the report says it is incomplete")
    check(blindPlan.rows.filter { $0.path.hasPrefix("locked/") }
              .allMatch { if case .unreadable = $0.kind { return true } else { return false } },
          "nothing under it is given a verdict")
    check(blindPlan.rows.first(where: { $0.path.hasPrefix("locked/") })?.kind
          == .unreadable(side: .right), "and the verdict says which side could not be read")
    check(blindPlan.rows.allMatch { !$0.action.isDestructive },
          "and nothing under it is proposed for deletion")
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)

    // --- applying, for real
    let doLeft = root.appendingPathComponent("do-left")
    let doRight = root.appendingPathComponent("do-right")
    try put("new file", "fresh.txt", in: doLeft)
    try put("deep new", "a/b/c/deep.txt", in: doLeft)
    try put("agreed", "same.txt", in: doLeft)
    try put("agreed", "same.txt", in: doRight)
    try put("doomed", "old-name.txt", in: doRight)
    let renameSource = try put("doomed", "new-name.txt", in: doLeft)
    let inode = try fm.attributesOfItem(atPath: renameSource.path)[.systemFileNumber] as? Int

    var doBase = try scan(doLeft).entries.filter { $0.key == "same.txt" }
    doBase["old-name.txt"] = try scan(doRight).entries["old-name.txt"]
    let doPlan = SyncEngine.plan(left: try scan(doLeft, baseline: doBase),
                                 right: try scan(doRight, baseline: doBase),
                                 baseline: doBase, propagateDeletions: true)
    let outcome = SyncRunner.apply(doPlan.rows, leftRoot: doLeft, rightRoot: doRight,
                                   settled: doPlan.settled, carried: doPlan.carried,
                                   baseline: doBase, toTrash: false, cancel: cancel)
    check(outcome.failures.isEmpty, "applying a plan reports no failures\(outcome.failures.map { " — \($0.error)" }.joined())")
    check(fm.fileExists(atPath: doRight.appendingPathComponent("fresh.txt").path),
          "a new file lands on the other side")
    check(fm.fileExists(atPath: doRight.appendingPathComponent("a/b/c/deep.txt").path),
          "and a copy makes the folders it needs on the way")
    let movedTo = doRight.appendingPathComponent("new-name.txt")
    check(fm.fileExists(atPath: movedTo.path)
          && !fm.fileExists(atPath: doRight.appendingPathComponent("old-name.txt").path),
          "a rename is carried over as a rename")
    let afterLeft = try scan(doLeft), afterRight = try scan(doRight)
    check(Set(afterLeft.entries.keys) == Set(afterRight.entries.keys),
          "and afterwards the two sides hold the same paths")
    check(outcome.baseline["fresh.txt"] != nil, "what was applied is written down as agreed")
    check(inode != nil, "the rename source had an inode to compare")

    // --- renaming across, when the two names are on opposite sides
    for direction in [SyncAction.renameOnRight, SyncAction.renameOnLeft] {
        let mL = root.appendingPathComponent("maybe-l-\(direction.rawValue)")
        let mR = root.appendingPathComponent("maybe-r-\(direction.rawValue)")
        try put("twinned", "left-name.txt", in: mL)
        try put("twinned", "right-name.txt", in: mR)
        var mPlan = SyncEngine.plan(left: try scan(mL), right: try scan(mR),
                                    baseline: nil, propagateDeletions: false)
        check(mPlan.rows.count == 1, "two names for one content is one row")
        mPlan.rows[0].action = direction
        let outcome = SyncRunner.apply(mPlan.rows, leftRoot: mL, rightRoot: mR,
                                       settled: mPlan.settled, carried: mPlan.carried,
                                       baseline: [:], toTrash: false, cancel: cancel)
        let wanted = direction == .renameOnRight ? "left-name.txt" : "right-name.txt"
        let renamedSide = direction == .renameOnRight ? mR : mL
        check(outcome.failures.isEmpty,
              "renaming \(direction == .renameOnRight ? "the right" : "the left") succeeds"
              + outcome.failures.map { " — \($0.error)" }.joined())
        check(fm.fileExists(atPath: renamedSide.appendingPathComponent(wanted).path),
              "and the side that was renamed takes the other's name")
        let finalLeft = try scan(mL).entries.keys.sorted()
        let finalRight = try scan(mR).entries.keys.sorted()
        check(finalLeft == finalRight, "leaving both sides holding the same one name")
    }

    // --- deletions, and the checkbox that governs them
    let delLeft = root.appendingPathComponent("del-left")
    let delRight = root.appendingPathComponent("del-right")
    try put("doomed", "bye.txt", in: delLeft)
    let delBase = try scan(delLeft).entries
    let offPlan = SyncEngine.plan(left: try scan(delLeft), right: try scan(delRight),
                                  baseline: delBase, propagateDeletions: false)
    check(offPlan.rows.first?.kind == .deletedOnRight, "a file gone from one side is still reported")
    check(offPlan.rows.allMatch { $0.action == .skip }, "but with deletions off nothing is proposed")
    _ = SyncRunner.apply(offPlan.rows, leftRoot: delLeft, rightRoot: delRight,
                         settled: offPlan.settled, carried: offPlan.carried,
                         baseline: delBase, toTrash: false, cancel: cancel)
    check(fm.fileExists(atPath: delLeft.appendingPathComponent("bye.txt").path),
          "and applying it leaves the file alone")

    let onPlan = SyncEngine.plan(left: try scan(delLeft), right: try scan(delRight),
                                 baseline: delBase, propagateDeletions: true)
    check(onPlan.rows.first?.action == .deleteLeft, "with deletions on the removal is proposed")
    _ = SyncRunner.apply(onPlan.rows, leftRoot: delLeft, rightRoot: delRight,
                         settled: onPlan.settled, carried: onPlan.carried,
                         baseline: delBase, toTrash: false, cancel: cancel)
    check(!fm.fileExists(atPath: delLeft.appendingPathComponent("bye.txt").path),
          "and applying it carries the deletion over")

    // --- a file that moved on while the report was open is left alone
    let raceLeft = root.appendingPathComponent("race-left")
    let raceRight = root.appendingPathComponent("race-right")
    try put("first", "moving.txt", in: raceLeft)
    let racePlan = SyncEngine.plan(left: try scan(raceLeft), right: try scan(raceRight),
                                   baseline: nil, propagateDeletions: true)
    try put("edited since the report was made, and longer", "moving.txt", in: raceLeft)
    let raced = SyncRunner.apply(racePlan.rows, leftRoot: raceLeft, rightRoot: raceRight,
                                 settled: [:], carried: [:], baseline: [:],
                                 toTrash: false, cancel: cancel)
    check(raced.failures.count == 1, "a file changed after the report was made is not copied blind")
    check(raced.baseline["moving.txt"] == nil, "and is dropped from the record so it is looked at again")

    // --- a skipped row is never recorded as agreed
    var skipping = racePlan
    skipping.rows[0].action = .skip
    let skipped = SyncRunner.apply(skipping.rows, leftRoot: raceLeft, rightRoot: raceRight,
                                   settled: [:], carried: [:],
                                   baseline: ["moving.txt": entry("moving.txt", "aaa")],
                                   toTrash: false, cancel: cancel)
    check(skipped.baseline["moving.txt"] == nil,
          "a row the user skipped is dropped from the record rather than called agreed")

    // --- the baseline on disk
    let store = SyncBaselineStore(root: root.appendingPathComponent("baselines"))
    try store.save(["a.txt": entry("a.txt", "aaa")], left: left, right: right, includesHidden: false)
    check(store.load(left: left, right: right)?.entries.count == 1, "the record round trips")
    check(store.load(left: left, right: right)?.byPath["a.txt"]?.hash == "aaa", "with its hashes intact")
    check(store.url(forLeft: left, right: right) == store.url(forLeft: right, right: left),
          "and is found whichever way round the panels are")
    try Data("{ not json".utf8).write(to: store.url(forLeft: left, right: right))
    check(store.load(left: left, right: right) == nil, "a damaged record reads as no record")
    check(store.load(left: left, right: root.appendingPathComponent("elsewhere")) == nil,
          "and a record for other folders is not borrowed")

    // --- the guards
    check(SyncEngine.isAncestor(left, of: left.appendingPathComponent("sub")),
          "a folder inside another is recognised")
    check(!SyncEngine.isAncestor(URL(fileURLWithPath: "/a/b"), of: URL(fileURLWithPath: "/a/bc")),
          "and a name that merely starts the same is not")

    // --- the whole thing, through the app object
    let settings = SettingsStore()
    settings.syncPropagatesDeletes = false
    let model = AppModel(settings: settings)

    /// The scan runs on another queue and answers on the main one, so the
    /// tool has to let the main queue run for the answer to arrive.
    func settle(_ seconds: TimeInterval = 10, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    model.left.navigate(to: .volumes)
    model.right.navigate(to: .directory(right))
    model.alertMessage = nil
    model.beginSyncFolders()
    check(model.sheet == nil, "the volume list is not a folder, so it cannot be synced")
    check(model.alertMessage?.contains("folder") == true, "and it says so")

    let liveLeft = root.appendingPathComponent("live-left")
    let liveRight = root.appendingPathComponent("live-right")
    try put("shared", "keep.txt", in: liveLeft)
    try put("shared", "keep.txt", in: liveRight)
    try put("only mine", "mine.txt", in: liveLeft)

    model.alertMessage = nil
    model.left.navigate(to: .directory(liveLeft))
    model.right.navigate(to: .directory(liveLeft))
    model.beginSyncFolders()
    check(model.sheet == nil && model.alertMessage?.contains("same folder") == true,
          "and neither can one folder against itself")

    model.alertMessage = nil
    model.left.navigate(to: .directory(liveLeft))
    model.right.navigate(to: .directory(liveLeft.appendingPathComponent("nested")))
    try fm.createDirectory(at: liveLeft.appendingPathComponent("nested"),
                           withIntermediateDirectories: true)
    model.beginSyncFolders()
    check(model.alertMessage?.contains("inside the other") == true,
          "nor a folder against something inside itself")
    try? fm.removeItem(at: liveLeft.appendingPathComponent("nested"))

    model.alertMessage = nil
    model.right.navigate(to: .directory(liveRight))
    model.beginSyncFolders()
    check(model.sheet != nil, "two ordinary folders open the report")
    settle { !model.isSyncing && model.syncPlan != nil }
    check(model.syncPlan != nil, "which fills itself in from a scan on another thread")
    check(model.syncPlan?.rows.count == 1, "finding the one file that differs")
    check(model.syncPlan?.rows.first?.path == "mine.txt", "and naming it")
    model.performSync(model.syncPlan?.rows ?? [], propagateDeletions: false)
    check(fm.fileExists(atPath: liveRight.appendingPathComponent("mine.txt").path),
          "and applying it copies the file across")

    // Second time round there is a record, so nothing is left to do.
    model.beginSyncFolders()
    settle { !model.isSyncing && model.syncPlan != nil }
    check(model.syncPlan?.rows.isEmpty == true, "run again, the two sides agree and nothing is proposed")
    check(model.syncPlan?.hasBaseline == true, "and the record written last time is found")
    model.sheet = nil
    SyncBaselineStore.applicationSupport().deleteRecord(left: liveLeft, right: liveRight)
}

// --- BAM repair -------------------------------------------------------------
print("\n=== BAM repair")
do {
    // A 35 track D64, so every offset here is computed the way the drive would.
    func at(_ t: Int, _ s: Int) -> Int {
        var base = 0
        for tt in 1..<t { base += CBMDiskImage.sectorsPerTrack(tt, format: .d64(tracks: 35)) }
        return (base + s) * 256
    }
    /// Flips one bit of the BAM in a raw image, keeping that track's free count
    /// in step — the same invariant the drive keeps.
    func setFree(_ d: inout Data, _ t: Int, _ s: Int, _ free: Bool) {
        let group = at(18, 0) + 4 * t
        let idx = group + 1 + s / 8
        let mask = UInt8(1 << (s % 8))
        let wasFree = d[idx] & mask != 0
        if free, !wasFree { d[idx] |= mask; d[group] += 1 }
        if !free, wasFree { d[idx] &= ~mask; d[group] -= 1 }
    }
    /// Writes a directory entry by hand into slot `i` of the first directory
    /// sector, which is how a disk with two entries pointing at one file is
    /// made — nothing in the browser will produce one.
    func putEntry(_ d: inout Data, slot i: Int, type: UInt8, name: String, t: UInt8, s: UInt8, blocks: Int) {
        let e = at(18, 1) + i * 32
        for j in 2..<32 { d[e + j] = 0 }
        d[e + 2] = type; d[e + 3] = t; d[e + 4] = s
        let padded = PETSCII.padded16(PETSCII.petscii(fromASCII: name))
        for j in 0..<16 { d[e + 5 + j] = padded[j] }
        d[e + 30] = UInt8(blocks & 0xFF); d[e + 31] = UInt8((blocks >> 8) & 0xFF)
    }
    func blank(_ path: String, _ files: [(String, Int)]) throws -> URL {
        try? FileManager.default.removeItem(atPath: path)
        let url = URL(fileURLWithPath: path)
        try CBMDiskImage.createBlank(.d64, name: PETSCII.petscii(fromASCII: "repair"),
                                     id: PETSCII.petscii(fromASCII: "01"), at: url)
        let img = try CBMDiskImage(url: url)
        for (name, size) in files {
            try img.write(name: PETSCII.petscii(fromASCII: name), type: .prg,
                          data: Data(repeating: 0x41, count: size), at: [])
        }
        try img.save()
        return url
    }

    // A disk damaged three ways at once, each of which a repair must find.
    do {
        let url = try blank("\(scratch)/repair1.d64", [("one", 600), ("two", 100)])
        let before = try CBMDiskImage(url: url)
        check(before.integrityNote == nil, "a freshly written disk has nothing wrong with it")
        let firstTrack = Int(before.entries[0].startTrack), firstSector = Int(before.entries[0].startSector)
        let trueFree = before.blocksFree
        let trueBlocks = before.entries[0].blocks
        let originals = try before.entries.map { try before.read($0) }

        var raw = try Data(contentsOf: url)
        setFree(&raw, 20, 5, false)                 // allocated, used by nothing
        setFree(&raw, firstTrack, firstSector, true) // in use, marked free
        let entry = at(18, 1)
        raw[entry + 30] = 99; raw[entry + 31] = 0    // a block count that is a lie
        try raw.write(to: url)

        let img = try CBMDiskImage(url: url)
        check(img.integrityNote != nil, "the damage shows in the header: \(img.integrityNote ?? "-")")
        let plan = img.analyseForRepair()
        check(plan.canRepair, "a disk with only BAM damage can be repaired")
        check(plan.toFree == 1, "\(plan.toFree) sector allocated and unused")
        check(plan.toAllocate == 1, "\(plan.toAllocate) sector in use and marked free")
        check(plan.wrongCounts.count == 1 && plan.wrongCounts[0].statedBlocks == 99
              && plan.wrongCounts[0].actualBlocks == trueBlocks,
              "the block count is caught: says 99, is \(plan.wrongCounts.first?.actualBlocks ?? -1)")
        check(plan.blocksFreeAfter == trueFree, "and it works out \(plan.blocksFreeAfter) blocks free")

        try img.applyRepair()
        check(img.integrityNote == nil, "after repair the BAM agrees with the directory")
        check(img.blocksFree == trueFree, "\(img.blocksFree) blocks free, as before the damage")
        check(img.entries[0].blocks == trueBlocks, "the block count is put right")
        let after = try img.entries.map { try img.read($0) }
        check(after == originals, "and both files still read back byte for byte")
        check(img.hasUnsavedChanges, "the repair is held in memory until it is saved")
    }

    // An unclosed file pointing into a live one: what a drive leaves behind,
    // and the reason most real disks look unrepairable until it is handled.
    do {
        let url = try blank("\(scratch)/repair2.d64", [("good", 600)])
        let before = try CBMDiskImage(url: url)
        let good = try before.read(before.entries[0])
        var raw = try Data(contentsOf: url)
        putEntry(&raw, slot: 1, type: 0x02, name: "splat",           // no closed bit
                 t: before.entries[0].startTrack, s: before.entries[0].startSector, blocks: 0)
        try raw.write(to: url)

        let img = try CBMDiskImage(url: url)
        check(img.entries.count == 2, "the disk lists the unclosed file")
        let plan = img.analyseForRepair()
        check(plan.splatToScratch.count == 1, "the unclosed file is listed for scratching")
        check(plan.collisions.isEmpty && plan.canRepair,
              "and setting it aside first leaves nothing sharing a sector")
        try img.applyRepair()
        check(img.entries.count == 1, "it is gone after the repair")
        check((try? img.read(img.entries[0])) == good, "and the file it pointed into is untouched")
        check(img.integrityNote == nil, "with a BAM that agrees")
    }

    // Two closed files pointing at one chain. Nothing may be written.
    do {
        let url = try blank("\(scratch)/repair3.d64", [("one", 600)])
        let before = try CBMDiskImage(url: url)
        var raw = try Data(contentsOf: url)
        putEntry(&raw, slot: 1, type: 0x82, name: "two",
                 t: before.entries[0].startTrack, s: before.entries[0].startSector, blocks: 3)
        try raw.write(to: url)
        let bytesBefore = try Data(contentsOf: url)

        let img = try CBMDiskImage(url: url)
        let plan = img.analyseForRepair()
        check(!plan.canRepair, "two files sharing a chain cannot be repaired")
        check(plan.collisions.count > 0 && plan.collisions[0].claimedBy.count == 2,
              "and the report names both: \(plan.collisions.first?.claimedBy ?? [])")
        var threw = false
        do { try img.applyRepair() } catch { threw = true }
        check(threw, "repairing it is refused")
        check(!img.hasUnsavedChanges, "nothing was changed in memory")
        check((try? Data(contentsOf: url)) == bytesBefore, "and nothing on disk either")
    }

    // A chain that walks off the end of the disk.
    do {
        let url = try blank("\(scratch)/repair4.d64", [("one", 600)])
        let before = try CBMDiskImage(url: url)
        var raw = try Data(contentsOf: url)
        raw[at(Int(before.entries[0].startTrack), Int(before.entries[0].startSector))] = 40
        try raw.write(to: url)
        let img = try CBMDiskImage(url: url)
        let plan = img.analyseForRepair()
        check(!plan.canRepair && plan.brokenChains.count == 1,
              "a chain leaving the disk cannot be repaired")
    }

    // Deleting the way past a blocker: both claimants of a shared sector go,
    // and the repair that was refused above then runs.
    do {
        let url = try blank("\(scratch)/repair6.d64", [("one", 600), ("keep", 400)])
        let before = try CBMDiskImage(url: url)
        let freeWithBoth = before.blocksFree
        var raw = try Data(contentsOf: url)
        putEntry(&raw, slot: 2, type: 0x82, name: "two",
                 t: before.entries[0].startTrack, s: before.entries[0].startSector, blocks: 3)
        try raw.write(to: url)

        let img = try CBMDiskImage(url: url)
        let plan = img.analyseForRepair()
        check(!plan.canRepair, "a shared sector still blocks the repair")
        check(plan.blockingFiles.sorted() == ["one", "two"],
              "and both claimants are offered up: \(plan.blockingFiles)")

        let gone = try img.deleteBlockingFiles()
        check(gone.sorted() == ["one", "two"], "deleting takes both: \(gone)")
        check(img.entries.map(\.displayName) == ["keep"], "the uninvolved file stays")

        let after = img.analyseForRepair()
        check(after.canRepair, "with them gone the repair is no longer blocked")
        try img.applyRepair()
        check(img.integrityNote == nil, "and it leaves the BAM agreeing with the directory")
        check(img.blocksFree > freeWithBoth,
              "the deleted file's blocks came back: \(img.blocksFree) free, was \(freeWithBoth)")
        check(img.blocksFree == 664 - 2, "which is every block but \"keep\"'s: \(img.blocksFree)")
    }

    // The same for a chain that leaves the disk. One file to name, and the
    // repair runs once it is gone.
    do {
        let url = try blank("\(scratch)/repair7.d64", [("one", 600), ("keep", 400)])
        let before = try CBMDiskImage(url: url)
        var raw = try Data(contentsOf: url)
        raw[at(Int(before.entries[0].startTrack), Int(before.entries[0].startSector))] = 40
        try raw.write(to: url)

        let img = try CBMDiskImage(url: url)
        check(img.analyseForRepair().blockingFiles == ["one"],
              "a broken chain names its one file")
        check(try img.deleteBlockingFiles() == ["one"], "which is the one deleted")
        check(img.analyseForRepair().canRepair, "and the repair is unblocked")
        try img.applyRepair()
        check(img.blocksFree == 664 - 2, "with the runaway chain's blocks free again")
    }

    // A disk with nothing in the way is left alone: the button that calls this
    // is never offered, and calling it anyway must not scratch a healthy file.
    do {
        let url = try blank("\(scratch)/repair8.d64", [("one", 600)])
        let img = try CBMDiskImage(url: url)
        check(img.analyseForRepair().blockingFiles.isEmpty, "a sound disk blocks nothing")
        check(try img.deleteBlockingFiles().isEmpty, "so nothing is deleted")
        check(img.entries.count == 1 && !img.hasUnsavedChanges, "and the disk is untouched")
    }

    // The repo's own mismatching disk: hand made directory art, ten entries all
    // pointing at the same sector on the directory track.
    if let img = try? CBMDiskImage(url: URL(fileURLWithPath: "sample_images/o-tech-people.d64")) {
        check(img.integrityNote != nil, "o-tech-people.d64 still reports a mismatch")
        let plan = img.analyseForRepair()
        check(true, "and it surveys without complaint: "
              + "\(plan.filesChecked) files, \(plan.collisions.count) shared sectors, "
              + "\(plan.canRepair ? "repairable" : "not repairable")")
    }

    // A track whose free count is nonsense. The map can be perfectly good and
    // the disk still report more blocks free than it physically holds, because
    // the header's mismatch check compares which blocks are allocated and not
    // how many each track claims.
    do {
        let url = try blank("\(scratch)/repair5.d64", [("one", 600)])
        let trueFree = try CBMDiskImage(url: url).blocksFree
        var raw = try Data(contentsOf: url)
        raw[at(18, 0) + 4 * 3] = 193        // track 3 holds 21 sectors
        raw[at(18, 0) + 4 * 5] = 202
        try raw.write(to: url)

        let img = try CBMDiskImage(url: url)
        check(img.blocksFree > 664, "the damaged disk claims \(img.blocksFree) blocks free")
        check(img.integrityNote == nil, "and the map itself is fine, so the header says nothing")
        let plan = img.analyseForRepair()
        check(plan.badFreeCounts == 2, "the survey finds \(plan.badFreeCounts) tracks miscounting")
        check(!plan.isClean, "so the disk is not called clean")
        try img.applyRepair()
        check(img.blocksFree == trueFree,
              "after repair it is back to \(img.blocksFree) blocks free (want \(trueFree))")
    }

    // The disk that found the bug above: a good map, but 27 tracks counting
    // free sectors they do not have, adding up to 3106 free on a disk that
    // holds 664. Named rather than left to the sweep because it is the case
    // that showed a repair could report success and leave nonsense behind.
    for place in ["~/Emulation/c64/disks/macc/MACDISKS/MMUSIC00.D64",
                  "~/Emulation/c64/SD_backup/macc/maccdisks/MMUSIC00.D64"] {
        let path = NSString(string: place).expandingTildeInPath
        guard let source = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("  --   MMUSIC00.D64 is not on this machine, skipping")
            continue
        }
        let copy = URL(fileURLWithPath: "\(scratch)/mmusic00.d64")
        try source.write(to: copy)
        let img = try CBMDiskImage(url: copy)
        let claimed = img.blocksFree
        let plan = img.analyseForRepair()
        // Tolerant of its own subject: this disk can be repaired and saved from
        // the app, and a check that needs a file to stay broken is a check that
        // will one day fail for the right reason. The synthetic case above is
        // what actually holds the line.
        guard claimed > 664 else {
            print("  --   MMUSIC00.D64 has been repaired since (\(claimed) blocks free), "
                  + "so there is nothing left to catch here")
            continue
        }
        check(plan.badFreeCounts > 0, "MMUSIC00.D64 claims \(claimed) blocks free on a 664 "
              + "block disk, with \(plan.badFreeCounts) tracks miscounting")
        try img.applyRepair()
        check(img.blocksFree <= 664 && img.blocksFree == plan.blocksFreeAfter,
              "after repair: \(img.blocksFree) blocks free, as the report promised")
        check(img.integrityNote == nil, "and a BAM that agrees with the directory")
    }

    // Then every real disk on this machine. The survey must never throw, and a
    // disk it calls repairable must actually come out clean.
    var places = ["sample_images"]
    for extra in ["~/Emulation/c64/SD_backup/macc/maccdisks", "~/Emulation/c64/SD_backup/macc/music"] {
        places.append(NSString(string: extra).expandingTildeInPath)
    }
    var seen = 0, repairable = 0, refused = 0, cleaned = 0, broke = 0
    var reasons: [String] = []
    for place in places {
        guard let walk = FileManager.default.enumerator(atPath: place) else { continue }
        for case let rel as String in walk where rel.lowercased().hasSuffix(".d64") {
            guard let source = try? Data(contentsOf: URL(fileURLWithPath: "\(place)/\(rel)")) else { continue }
            let copy = URL(fileURLWithPath: "\(scratch)/sweep.d64")
            try? source.write(to: copy)
            guard let img = try? CBMDiskImage(url: copy) else { continue }
            seen += 1
            let plan = img.analyseForRepair()
            guard plan.canRepair else { refused += 1; continue }
            repairable += 1
            let lengths = img.entries.filter { $0.type != .del }.map { (try? img.read($0))?.count ?? -1 }
            guard (try? img.applyRepair()) != nil else {
                broke += 1; reasons.append("\(rel): applyRepair threw"); continue
            }
            if let note = img.integrityNote {
                broke += 1; reasons.append("\(rel): still \(note)"); continue
            }
            // The report promised a figure; the disk has to agree with it.
            if img.blocksFree != plan.blocksFreeAfter {
                broke += 1
                reasons.append("\(rel): says \(img.blocksFree) free, report promised \(plan.blocksFreeAfter)")
                continue
            }
            if img.analyseForRepair().isClean == false {
                broke += 1; reasons.append("\(rel): a second repair still finds work"); continue
            }
            let after = img.entries.filter { $0.type != .del }.map { (try? img.read($0))?.count ?? -1 }
            // Scratching the unclosed files shortens the list, so compare what
            // survived rather than the whole of it.
            if after.count == lengths.count, after != lengths {
                broke += 1; reasons.append("\(rel): a file changed length"); continue
            }
            cleaned += 1
        }
    }
    check(seen > 0, "\(seen) real D64 images surveyed")
    check(broke == 0, "\(cleaned) of \(repairable) repairable disks came out clean"
          + (reasons.isEmpty ? "" : " - \(reasons.prefix(4))"))
    print("      \(refused) refused as beyond repair, \(repairable) repairable")
} catch {
    print("  FAIL BAM repair: \(error)"); failures += 1
}

// MARK: - Drag and drop

// The rules a drop is decided by, and the transfer it ends in. The pointer
// itself cannot be driven from here, so what is checked is everything behind
// it: which of move and copy two places imply, which drops are refused, and
// that the files land where they were dropped.
print("\n=== drag and drop")
do {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: scratch)
        .appendingPathComponent("cfb-drag-\(UUID().uuidString)", isDirectory: true)
    let dirA = root.appendingPathComponent("A", isDirectory: true)
    let dirB = root.appendingPathComponent("B", isDirectory: true)
    let dirC = root.appendingPathComponent("C", isDirectory: true)
    let dirD = root.appendingPathComponent("D", isDirectory: true)
    let nested = dirA.appendingPathComponent("sub", isDirectory: true)
    for dir in [nested, dirB, dirC, dirD] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    defer { try? fm.removeItem(at: root) }

    @discardableResult
    func put(_ name: String, _ text: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    let hello = try put("HELLO.PRG", "\u{01}\u{08}hello world", in: dirA)
    try put("second.txt", "second", in: dirA)
    try put("deep.txt", "deep", in: nested)

    let imageURL = root.appendingPathComponent("drag.d64")
    try CBMDiskImage.createBlank(.d64, tracks: 35,
                                 name: PETSCII.cbmName(fromASCII: "DRAG"),
                                 id: PETSCII.petscii(fromASCII: "01"), at: imageURL)

    let settings = SettingsStore()
    let model = AppModel(settings: settings)
    model.left.navigate(to: .directory(dirA))
    model.right.navigate(to: .directory(dirB))
    func row(_ panel: PanelModel, _ name: String) -> PanelItem? {
        panel.items.first { $0.title == name }
    }

    // Which volume a place belongs to, which is the whole of the question.
    let volumeA = PanelDropDelegate.volumeIdentity(of: .directory(dirA))
    check(volumeA == PanelDropDelegate.volumeIdentity(of: .directory(dirB)),
          "two folders on one volume share an identity")
    check(PanelDropDelegate.volumeIdentity(of: .image(imageURL)) != volumeA,
          "the inside of an image is a volume of its own")
    check(PanelDropDelegate.volumeIdentity(of: .volumes) == nil, "the volume list is nowhere")

    // The status line belongs to where it was made. Checked here because this
    // is the one place with a live AppModel and two panels to move between.
    do {
        model.statusMessage = "Saved something"
        model.left.reload()
        check(model.statusMessage == "Saved something", "a plain refresh keeps the status line")
        model.left.navigate(to: .directory(dirB))
        check(model.statusMessage.isEmpty, "walking to another directory clears it")

        model.statusMessage = "Saved something"
        model.activeSide = .right
        check(model.statusMessage.isEmpty, "and so does switching column")

        // The inactive panel counts too: it is redrawn under the same line.
        model.statusMessage = "Saved something"
        model.left.navigate(to: .directory(dirA))
        check(model.statusMessage.isEmpty, "the other column moving clears it as well")

        // The handful of actions that navigate and then report still do, since
        // the message is set after the move rather than before it.
        model.left.navigate(to: .directory(nested))
        model.statusMessage = "Discarded the changes to DRAG"
        check(model.statusMessage == "Discarded the changes to DRAG",
              "a message set after a move survives it")

        // Put the panels back where the drop tests below expect them.
        model.left.navigate(to: .directory(dirA))
        model.right.navigate(to: .directory(dirB))
        model.activeSide = .left
        model.statusMessage = ""
    }

    // ⌘R is the browser's own; every other Command chord belongs to the menu,
    // where ⌥⌘R reveals in Finder and ⇧⌘R repairs the disk. The monitor sees
    // the key first, so swallowing one of those would take the menu item away.
    do {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: code)!
        }
        check(model.handleKey(key("r", [.command], 15)), "⌘R is handled here, as rename")
        model.sheet = nil
        check(!model.handleKey(key("r", [.command, .shift], 15)),
              "⇧⌘R falls through to the Repair Disk menu item")
        check(!model.handleKey(key("r", [.command, .option], 15)),
              "and ⌥⌘R to Show in Finder")
        check(model.sheet == nil, "neither opened the rename sheet")
    }

    let fileSource = DropSource(location: .directory(dirA), urls: [hello], hasFolder: false)
    let folderSource = DropSource(location: .directory(root), urls: [dirA], hasFolder: true)
    func plan(_ source: DropSource, _ destination: PanelLocation, option: Bool = false) -> DropPlan? {
        PanelDropDelegate.plan(dropping: source, onto: destination,
                               highlight: .panel, optionHeld: option)
    }

    check(plan(fileSource, .directory(dirB))?.isMove == true, "same volume moves by default")
    check(plan(fileSource, .directory(dirB), option: true)?.isMove == false,
          "and Option turns that into a copy")
    check(plan(fileSource, .image(imageURL))?.isMove == false, "into an image copies by default")
    check(plan(fileSource, .image(imageURL), option: true)?.isMove == true,
          "and Option turns that into a move")
    check(plan(DropSource(location: .image(imageURL)), .directory(dirB))?.isMove == false,
          "out of an image copies by default")
    check(plan(DropSource(location: .image(imageURL)), .image(imageURL, path: ["sub"]))?.isMove == true,
          "one image into a folder of its own moves")

    check(plan(fileSource, .directory(dirA)) == nil, "dropping where the files already are is refused")
    check(plan(folderSource, .directory(nested)) == nil, "a folder cannot be dropped inside itself")
    check(plan(folderSource, .image(imageURL)) == nil, "a folder cannot be dropped into an image")

    // Between two folders, which the file system itself carries.
    model.performDrop(items: [row(model.left, "HELLO.PRG")!], from: .left, to: .right,
                      destination: .directory(dirB), isMove: false)
    check(fm.fileExists(atPath: dirB.appendingPathComponent("HELLO.PRG").path)
          && fm.fileExists(atPath: hello.path), "a copy between two folders leaves the original")
    model.performDrop(items: [row(model.left, "second.txt")!], from: .left, to: .right,
                      destination: .directory(dirB), isMove: true)
    check(fm.fileExists(atPath: dirB.appendingPathComponent("second.txt").path)
          && !fm.fileExists(atPath: dirA.appendingPathComponent("second.txt").path),
          "a move between two folders leaves nothing behind")
    model.performDrop(items: [row(model.left, "sub")!], from: .left, to: .right,
                      destination: .directory(dirB), isMove: false)
    check(fm.fileExists(atPath: dirB.appendingPathComponent("sub/deep.txt").path),
          "a folder arrives with what is inside it")

    // Into an image and back out, where the bytes are rewritten on the way.
    model.right.navigate(to: .image(imageURL))
    model.performDrop(items: [row(model.left, "HELLO.PRG")!], from: .left, to: .right,
                      destination: .image(imageURL), isMove: false)
    check(model.right.image?.entries.contains { $0.displayName == "HELLO" } == true,
          "a file dropped into an image is written as HELLO")
    check(fm.fileExists(atPath: hello.path), "and is still on the Mac")

    settings.addHostExtension = true
    model.performDrop(items: [row(model.right, "HELLO")!], from: .right, to: .left,
                      destination: .directory(dirC), isMove: false)
    check(fm.fileExists(atPath: dirC.appendingPathComponent("HELLO.prg").path),
          "and comes back out as HELLO.prg")

    // A name already taken on the far side is left alone: a drag asks no
    // questions, so it may not answer this one either.
    model.performDrop(items: [row(model.right, "HELLO")!], from: .right, to: .left,
                      destination: .directory(dirC), isMove: true)
    check(model.right.image?.entries.contains { $0.displayName == "HELLO" } == true
          && model.statusMessage.contains("skipped"),
          "a name already taken skips the move: \(model.statusMessage)")

    let free = model.right.image!.blocksFree
    model.performDrop(items: [row(model.right, "HELLO")!], from: .right, to: .left,
                      destination: .directory(dirD), isMove: true)
    check(fm.fileExists(atPath: dirD.appendingPathComponent("HELLO.prg").path),
          "a move out of an image lands on the Mac")
    check(model.right.image?.entries.contains { $0.displayName == "HELLO" } == false
          && model.right.image!.blocksFree > free,
          "and scratches the entry, giving the blocks back")

    // A path dropped in from another application, which has no panel behind it.
    let outside = try put("OUTSIDE.PRG", "\u{01}\u{08}from the finder", in: dirC)
    check(PanelDropDelegate.item(for: outside, id: 0).kind == .file
          && PanelDropDelegate.item(for: dirC, id: 0).kind == .folder
          && PanelDropDelegate.item(for: imageURL, id: 0).kind == .diskImage,
          "a dropped path becomes a row of the right kind")
    model.performDrop(items: [PanelDropDelegate.item(for: outside, id: 0)], from: nil, to: .right,
                      destination: .image(imageURL), isMove: false)
    check(model.right.image?.entries.contains { $0.displayName == "OUTSIDE" } == true,
          "a file dropped in from outside reaches the image")

    // A drag that is over leaves its files on the drag pasteboard, and SwiftUI
    // asks a drop target one more time after the mouse is up. Answering that
    // from the finished drag is what used to leave a panel outlined with
    // nothing over it, so the pasteboard is retired when the drag ends.
    let dragBoard = NSPasteboard(name: .drag)
    dragBoard.clearContents()
    dragBoard.writeObjects([outside as NSURL])
    let coordinator = model.dragCoordinator
    check(coordinator.externalURLs() == [outside], "a drag in flight reads its files off the pasteboard")
    coordinator.retireDrag()
    check(coordinator.externalURLs().isEmpty, "and reads nothing off it once the drag is over")
    check(PanelDropDelegate(model: model, panel: model.right, row: nil).plan() == nil,
          "so a drop target asked again after the drop offers nothing")

    // A move made by another application happens after the drag has already
    // ended, so the files are still there when the session reports finished.
    // The panel follows the ones it let go of until one of them disappears.
    let goodbye = try put("goodbye.txt", "bye", in: dirD)
    model.left.navigate(to: .directory(dirD))
    check(model.left.items.contains { $0.title == "goodbye.txt" }, "the panel lists a file it is about to lose")
    coordinator.watchForDeparture(of: [goodbye])
    try fm.removeItem(at: goodbye)
    let until = Date().addingTimeInterval(2)
    while Date() < until, model.left.items.contains(where: { $0.title == "goodbye.txt" }) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(!model.left.items.contains { $0.title == "goodbye.txt" },
          "and redraws itself once the file has gone, without being asked")

    // --- Stepping through tunes with a player sheet up ------------------
    //
    // An alert cannot be seen while a sheet is up, and one pending swallows
    // every key, so a failure raised here used to leave ⌘↑ and ⌘↓ dead and
    // the message waiting to spring out when the sheet was closed.
    do {
        let tunes = root.appendingPathComponent("tunes")
        try fm.createDirectory(at: tunes, withIntermediateDirectories: true)
        // Enough of a PSID for the player to open on, then a file recognisable
        // as nothing, then one too short to be a tune at all.
        var psid = Data("PSID".utf8)
        psid.append(contentsOf: [0x00, 0x02, 0x00, 0x7C, 0x00, 0x76,
                                 0x10, 0x00, 0x10, 0x00, 0x10, 0x03,
                                 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        psid.append(Data(repeating: 0x20, count: 96))
        psid.append(Data(repeating: 0xEA, count: 2048))
        try psid.write(to: tunes.appendingPathComponent("a.sid"))
        try Data((0..<4096).map { UInt8($0 & 0x7F) })
            .write(to: tunes.appendingPathComponent("m.bin"))
        try Data([0x41]).write(to: tunes.appendingPathComponent("z.txt"))

        model.left.navigate(to: .directory(tunes))
        model.activeSide = .left
        model.left.moveCursor(to: 1)
        model.beginPlay(manual: false)
        check(model.sheet != nil && model.alertMessage == nil, "the player opens on a tune")

        model.playNeighbour(1)
        check(model.activePanel.currentItem?.title == "m.bin" && model.alertMessage == nil,
              "stepping onto a file it cannot recognise opens the player on it")

        // Past the last one: the file after it is too short to play, so the
        // step runs off the end.
        model.playNeighbour(1)
        check(model.alertMessage == nil, "stepping past the end raises no alert behind the sheet")
        check(model.statusMessage == "Nothing below this to play", "and says why it did nothing")
        check(model.activePanel.currentItem?.title == "m.bin", "leaving the cursor where it was")

        model.playNeighbour(-1)
        check(model.activePanel.currentItem?.title == "a.sid", "and stepping back up still works")
        check(model.statusMessage.isEmpty, "clearing what the failed step said")
        model.player.stop()
        model.sheet = nil
    }

    // The panels wrote their folder memory into this tool's own preferences
    // domain — not the app's, since the tool has no bundle — so it is cleared
    // rather than left behind in ~/Library/Preferences.
    UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
} catch {
    print("  FAIL drag and drop: \(error)"); failures += 1
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
