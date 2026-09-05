import Foundation
import AppKit
setbuf(stdout, nil)

let scratch = NSTemporaryDirectory()
var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
    if !cond { failures += 1 }
}

func dump(_ path: String) {
    let url = URL(fileURLWithPath: path)
    do {
        let img = try DiskImageFactory.open(url)
        print("\n=== \(url.lastPathComponent) — \(img.formatName)")
        print("  header: \"\(PETSCII.ascii(PETSCII.trimPadding(img.diskName)))\" \(PETSCII.ascii(img.diskID))")
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
        try CBMDiskImage.createBlank(kind, name: PETSCII.petscii(fromASCII: "TEST DISK"),
                                     id: PETSCII.petscii(fromASCII: "01"), at: url)
        let img = try CBMDiskImage(url: url)
        let expected = [CBMDiskImage.BlankFormat.d64: 664, .d71: 1328, .d81: 3160][kind]!
        check(img.blocksFree == expected, "\(kind.rawValue) fresh format: \(img.blocksFree) blocks free (want \(expected))")
        check(img.entries.isEmpty, "\(kind.rawValue) fresh directory is empty")
        check(PETSCII.ascii(PETSCII.trimPadding(img.diskName)) == "TEST DISK", "\(kind.rawValue) disk name")

        // Write a spread of sizes, including ones that cross a block boundary.
        var written: [String: Data] = [:]
        for (i, size) in [1, 253, 254, 255, 508, 20000].enumerated() {
            var payload = Data([0x01, 0x08])
            payload.append(contentsOf: (0..<size).map { UInt8(($0 &* 7 &+ i) & 0xFF) })
            let name = PETSCII.cbmName(fromASCII: "FILE \(i)")
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
        try reread.write(name: PETSCII.cbmName(fromASCII: "AAA"), type: .prg, data: Data([0x01, 0x08, 9, 9]))
        try reread.write(name: PETSCII.cbmName(fromASCII: "BBB"), type: .seq, data: Data([1, 2, 3]))
        try reread.rename(reread.entries[0], to: PETSCII.cbmName(fromASCII: "RENAMED"))
        check(reread.entries[0].displayName == "RENAMED", "\(kind.rawValue) rename")
        try reread.moveEntry(reread.entries[0], by: 1)
        check(reread.entries[0].displayName == "BBB" && reread.entries[1].displayName == "RENAMED",
              "\(kind.rawValue) reorder")
        try reread.addDecorativeEntry(name: PETSCII.cbmName(fromASCII: "---------"), after: reread.entries[0])
        check(reread.entries.count == 3 && reread.entries[1].type == .del, "\(kind.rawValue) decorative DEL entry")
        try reread.setDiskHeader(name: PETSCII.cbmName(fromASCII: "NEW NAME"), id: PETSCII.petscii(fromASCII: "2B"))
        try reread.save()
        let third = try CBMDiskImage(url: url)
        check(PETSCII.ascii(PETSCII.trimPadding(third.diskName)) == "NEW NAME", "\(kind.rawValue) header edit persists")
        check(third.entries.count == 3, "\(kind.rawValue) 3 entries persist")
    } catch {
        print("  FAIL \(kind.rawValue): \(error)")
        failures += 1
    }
}

// --- Fill a disk completely --------------------------------------------------
print("\n=== disk full handling")
do {
    let path = "\(scratch)/full.d64"
    try? FileManager.default.removeItem(atPath: path)
    let url = URL(fileURLWithPath: path)
    try CBMDiskImage.createBlank(.d64, name: PETSCII.petscii(fromASCII: "FULL"), id: [0x30, 0x31], at: url)
    let img = try CBMDiskImage(url: url)
    var count = 0
    while true {
        do {
            try img.write(name: PETSCII.cbmName(fromASCII: "F\(count)"), type: .prg,
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
    try panel.image!.write(name: PETSCII.cbmName(fromASCII: "ADDED"), type: .prg, data: Data([0x01, 0x08, 1, 2, 3]))
    panel.goUp(keepChanges: true)
    let saved = try CBMDiskImage(url: url)
    check(saved.entries.count == originalCount, "walking up to the parent wrote the edits")
    check(saved.entries.contains { $0.displayName == "ADDED" }, "the added file survived the save")

    // A rebuild after an operation must not re-read the untouched file.
    panel = openPanel()
    try panel.image!.write(name: PETSCII.cbmName(fromASCII: "PENDING"), type: .prg, data: Data([0x01, 0x08, 9]))
    panel.refresh()
    check(panel.hasUnsavedChanges, "refresh keeps the pending edits")
    check(panel.items.contains { $0.title == "PENDING" }, "refresh redraws them from memory")
    panel.goUp(keepChanges: false)
    check(try !CBMDiskImage(url: url).entries.contains { $0.displayName == "PENDING" },
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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
