import Foundation
import AppKit
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
                let why = (error as? LocalizedError)?.errorDescription ?? ""
                if why.contains("no AmigaDOS") { loaders += 1 } else { failures += 1 }
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
            check(tune.songCount >= 1, "\(tune.songCount) song(s), title \"\(tune.title)\"")
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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
