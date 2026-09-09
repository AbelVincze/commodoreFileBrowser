import AppKit

/// A listing gathered from a panel, ready to be laid out on paper.
///
/// The job is built before the print dialog opens and never changes after
/// that: the two things the dialog can still change — the size of a character
/// and how many columns a page is split into — belong to the view that draws
/// it, so the preview can redraw without reading the panel again.
struct DirectoryPrintJob {

    /// One printed line. A Commodore listing carries screen codes, ready to be
    /// looked up in the character ROM; everything else is text the system font
    /// draws, already padded into columns.
    enum Line {
        case petscii([UInt8])
        case text(String)
        case blank
    }

    /// Named on the page and given to the printer as the job's name.
    var title: String
    /// The second line of the page header: where the listing came from.
    var subtitle: String
    var lines: [Line]
    /// The character ROM and half of it the panel is showing, so the paper
    /// matches the screen — upper case / graphics or lower case / upper case.
    var font: PETSCIIFont
    /// Whether the listing is drawn from the ROM at all. A host folder and an
    /// Amiga volume are not, and are set in the system's monospaced face.
    var isPETSCII: Bool
    /// The longest line in characters, which is what decides whether two
    /// columns will fit across the page.
    var widestLine: Int

    // MARK: - Building

    /// Everything the active panel is showing, in the order it shows it. The
    /// `..` row is chrome rather than part of the directory, so it is left out.
    static func make(panel: PanelModel, font: PETSCIIFont) -> DirectoryPrintJob {
        let rows = panel.items.filter { $0.kind != .parent }
        if let image = panel.image, image.listingStyle == .petscii {
            return commodore(panel: panel, image: image, rows: rows, font: font)
        }
        return text(panel: panel, rows: rows, font: font)
    }

    /// A 1541 listing: the reverse-video header, the entries, and the count of
    /// free blocks the drive prints after them.
    private static func commodore(panel: PanelModel, image: DiskImage,
                                  rows: [PanelItem], font: PETSCIIFont) -> DirectoryPrintJob {
        // Reverse video is the ROM's own $80-$FF forms, the same way the panel
        // draws the header line.
        let header = PETSCII.screenCodes(PanelModel.headerLine(for: image)).map { $0 | 0x80 }
        var lines: [Line] = [.petscii(header)]
        for row in rows {
            guard let petscii = row.petsciiLine else { continue }
            lines.append(.petscii(PETSCII.screenCodes(petscii)))
        }
        lines.append(.blank)
        lines.append(.petscii(PETSCII.screenCodes(ascii: image.freeDescription)))

        // A decorated header spells its name in graphics, which have no text to
        // put at the top of the page: the file's own name stands in, and the
        // subtitle then has no reason to repeat it.
        let name = image.displayDiskName.trimmingCharacters(in: .whitespaces)
        let file = panel.location.url?.lastPathComponent ?? ""
        let title = name.isEmpty ? file : name
        let subtitle = ([file == title ? "" : file, image.formatName]
                        + panel.location.imagePath)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        return DirectoryPrintJob(title: title,
                                 subtitle: subtitle,
                                 lines: lines,
                                 font: font,
                                 isPETSCII: true,
                                 widestLine: lines.map(\.length).max() ?? 0)
    }

    /// A host folder, a list of volumes, or an Amiga volume: name, size, the
    /// permission bits where the format has them, and the date.
    private static func text(panel: PanelModel, rows: [PanelItem],
                             font: PETSCIIFont) -> DirectoryPrintJob {
        // Wide enough for the names actually in this listing, but never so wide
        // that one outlying name pushes the columns off the page.
        let nameWidth = min(38, max(20, rows.map(\.title.count).max() ?? 20))
        let hasFlags = rows.contains { !$0.flags.isEmpty }
        let hasDates = rows.contains { $0.modified != nil }

        func row(name: String, detail: String, flags: String, date: String) -> String {
            var out = name.padded(to: nameWidth) + "  " + detail.aligned(right: 11)
            if hasFlags { out += "  " + flags.padded(to: 8) }
            if hasDates { out += "  " + date.padded(to: 9) }
            return out
        }

        var lines: [Line] = [.text(row(name: "Name", detail: "Size",
                                       flags: "Flags", date: "Modified"))]
        for item in rows {
            lines.append(.text(row(name: item.title,
                                   detail: item.detail,
                                   flags: item.flags,
                                   date: item.modified.map(Self.dateText) ?? "")))
        }
        lines.append(.blank)
        lines.append(.text(panel.footerText))

        let title: String
        let subtitle: String
        switch panel.location {
        case .volumes:
            title = "Volumes"
            subtitle = "Mounted volumes"
        case .directory(let url):
            title = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            subtitle = url.path
        case .image(let url, let path):
            let name = panel.image?.displayDiskName.trimmingCharacters(in: .whitespaces) ?? ""
            title = name.isEmpty ? url.lastPathComponent : name
            subtitle = ([url.lastPathComponent, panel.image?.formatName ?? ""] + path)
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }

        return DirectoryPrintJob(title: title, subtitle: subtitle, lines: lines,
                                 font: font, isPETSCII: false,
                                 widestLine: lines.map(\.length).max() ?? 0)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd-MMM-yy"
        return f
    }()

    private static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
}

extension DirectoryPrintJob.Line {
    /// Length in characters, which is what both faces here are measured in.
    var length: Int {
        switch self {
        case .petscii(let codes): return codes.count
        case .text(let s): return s.count
        case .blank: return 0
        }
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? String(prefix(width)) : self + String(repeating: " ", count: width - count)
    }

    func aligned(right width: Int) -> String {
        count >= width ? String(suffix(width)) : String(repeating: " ", count: width - count) + self
    }
}

/// Draws runs of screen codes as filled rectangles rather than as a scaled
/// bitmap.
///
/// The panel draws PETSCII from a one-pixel-per-pixel image, which is right for
/// a screen whose pixels the glyphs can be lined up with. A printer has no such
/// grid — a 600 dpi page would land an 8 pixel glyph on fractions of a dot — so
/// on paper the same glyphs go down as vectors, and stay square at any size.
enum PETSCIIVectorRenderer {

    /// `origin` is the top left of the run in a flipped context; `cell` is the
    /// side of one character, which is square.
    static func draw(codes: [UInt8], font: PETSCIIFont, at origin: CGPoint,
                     cell: CGFloat, in context: CGContext) {
        let unit = cell / CGFloat(CharacterROM.glyphWidth)
        var rects: [CGRect] = []
        for (index, code) in codes.enumerated() {
            let x0 = origin.x + CGFloat(index) * cell
            for (y, byte) in CharacterROM.shared.rows(screenCode: code, font: font).enumerated()
            where byte != 0 {
                // Neighbouring set pixels go down as one rectangle, which keeps
                // a reverse-video line to a handful of bars rather than sixty.
                var bit = 0
                while bit < 8 {
                    guard byte & (0x80 >> UInt8(bit)) != 0 else { bit += 1; continue }
                    var run = 1
                    while bit + run < 8, byte & (0x80 >> UInt8(bit + run)) != 0 { run += 1 }
                    rects.append(CGRect(x: x0 + CGFloat(bit) * unit,
                                        y: origin.y + CGFloat(y) * unit,
                                        width: CGFloat(run) * unit, height: unit))
                    bit += run
                }
            }
        }
        guard !rects.isEmpty else { return }
        context.fill(rects)
    }
}
