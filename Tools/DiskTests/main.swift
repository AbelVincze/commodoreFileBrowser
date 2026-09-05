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
    check(PETSCII.ascii(lines[0].text) == "PRINT \"HELLO\"", "line 10 detokenised: \(PETSCII.ascii(lines[0].text))")
    // No space: none was stored, and a real C64 lists it exactly this way.
    check(PETSCII.ascii(lines[1].text) == "GOTO10", "line 20 detokenised: \(PETSCII.ascii(lines[1].text))")
    check(PETSCII.ascii(lines[0].petscii) == "10 PRINT \"HELLO\"", "the listing line carries its number")

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
    check(CommodoreBASIC.tokens[0x99 - 0x80] == "PRINT", "$99 is PRINT")
    check(CommodoreBASIC.tokens[0x9E - 0x80] == "SYS", "$9E is SYS")
    check(CommodoreBASIC.tokens[0xCB - 0x80] == "GO", "$CB is GO")

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
    if let entry = img.entries.first(where: { $0.displayName.hasPrefix("Z10 ") }) {
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
} catch {
    print("  FAIL sid: \(error)"); failures += 1
}

// --- The SID engine actually runs -------------------------------------------
print("\n=== sid engine")
do {
    let img = try CBMDiskImage(url: URL(fileURLWithPath:
        "/Users/macc/Emulation/c64/SD_backup/macc/maccdisks/INTROMUSICS_007.D64"))
    guard let entry = img.entries.first(where: { $0.displayName.hasPrefix("Z10 ") }),
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
    guard let three = img.entries.first(where: { $0.displayName.hasPrefix("ZJ0 ") }),
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
        let s1 = ScopeRenderer.triggerOffset(first), s2 = ScopeRenderer.triggerOffset(second)
        check(s1 != s2, "the two phases trigger at different offsets (\(s1) and \(s2))")
        check(Array(first[s1..<(s1 + w)]) == Array(second[s2..<(s2 + w)]),
              "triggered windows are identical despite the phase difference")
        check(Array(first[0..<w]) != Array(second[0..<w]),
              "and untriggered they would not have been")

        // Every trigger must land on a rising crossing.
        for phase in [0, 13, 49, 71, 99] {
            let wave = square(period: 100, phase: phase)
            let start = ScopeRenderer.triggerOffset(wave)
            check(start > 0 && wave[start] > 0 && wave[start - 1] < 0,
                  "phase \(phase) triggers on a rising edge at \(start)")
        }

        check(ScopeRenderer.triggerOffset([Int16](repeating: 0, count: 2048)) == 0,
              "silence triggers at 0")
        check(ScopeRenderer.triggerOffset([Int16](repeating: 0, count: 10)) == 0,
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
            let start = ScopeRenderer.triggerOffset(buf)
            if start > 0 {
                fired += 1
                // The contract is hysteresis, not a sign change on the very
                // previous sample: the signal fell below the threshold at some
                // point before rising back through it. The sample just before
                // the trigger may sit inside the dead band.
                if buf[start] >= 400, buf[0..<start].contains(where: { $0 < -400 }) { rising += 1 }
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

    csid_set_model(6581)            // live
    renderSecond()
    check(UInt(csid_play_call_count()) > afterBack, "changing chip model did not restart either")

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

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
