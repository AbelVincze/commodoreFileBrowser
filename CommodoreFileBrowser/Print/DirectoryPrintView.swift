import AppKit

/// Lays a gathered listing out on paper and draws it.
///
/// The view is as tall as every page stacked one under the other, and hands
/// AppKit one page rectangle at a time. It is flipped, so page one is at the
/// top and a line's origin is its top left corner — which is how both the
/// character ROM and the system's text drawing want to be given a position.
final class DirectoryPrintView: NSView {

    /// The side of one character cell, in points. The dialog's size control.
    var cellPoints: CGFloat = 8 { didSet { needsDisplay = true } }
    /// One or two columns per page.
    var columnCount: Int = 1 { didSet { needsDisplay = true } }

    private let job: DirectoryPrintJob
    private let printedOn = Date()

    /// The imageable area of one sheet, taken from the print info when AppKit
    /// asks how many pages there are.
    private var pageSize = NSSize(width: 540, height: 720)
    private var pageCount = 1

    private let headerHeight: CGFloat = 40
    private let footerHeight: CGFloat = 20
    private let gutter: CGFloat = 20

    private static let black = NSColor(deviceWhite: 0, alpha: 1)
    private static let grey = NSColor(deviceWhite: 0.4, alpha: 1)
    private static let rule = NSColor(deviceWhite: 0.65, alpha: 1)

    init(job: DirectoryPrintJob, cellPoints: CGFloat, columnCount: Int) {
        self.job = job
        self.cellPoints = cellPoints
        self.columnCount = columnCount
        super.init(frame: NSRect(origin: .zero, size: pageSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    override var isFlipped: Bool { true }

    // MARK: - Measurements

    private var lineHeight: CGFloat { cell * 1.2 }

    private var columnWidth: CGFloat {
        (pageSize.width - gutter * CGFloat(columnCount - 1)) / CGFloat(columnCount)
    }

    /// The size a character is actually drawn at.
    ///
    /// The dialog asks for a size; a listing wider than the column it has been
    /// given is drawn smaller so it still fits between the margins. Two columns
    /// of a long Amiga listing is the case this is here for — nothing shrinks
    /// until something would otherwise run off the page.
    private var cell: CGFloat {
        guard job.widestLine > 0 else { return cellPoints }
        let widest = CGFloat(job.widestLine) * advanceRatio
        return min(cellPoints, columnWidth / widest)
    }

    /// Width of one character as a fraction of the cell size. A ROM glyph is
    /// square; the system's monospaced face is narrower than it is tall.
    private lazy var advanceRatio: CGFloat = {
        guard !job.isPETSCII else { return 1 }
        let probe = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        let width = ("0" as NSString).size(withAttributes: [.font: probe]).width
        return width / 100 * textSizeRatio
    }()

    /// The monospaced face is set a little smaller than the cell, so a text
    /// listing and a PETSCII one at the same setting read at the same size.
    private let textSizeRatio: CGFloat = 0.95

    private var rowsPerColumn: Int {
        let usable = pageSize.height - headerHeight - footerHeight
        return max(1, Int(usable / lineHeight))
    }

    private var linesPerPage: Int { rowsPerColumn * columnCount }

    /// How far down a column runs on one page.
    ///
    /// A full page fills its columns to the bottom. The last one — which for a
    /// listing that fits on a single sheet is the only one — divides what is
    /// left between them instead, so two columns of a short directory come out
    /// as two short columns rather than one column and an empty space.
    private func rowsPerColumn(onPage page: Int) -> Int {
        guard columnCount > 1 else { return rowsPerColumn }
        let remaining = job.lines.count - (page - 1) * linesPerPage
        guard remaining > 0, remaining < linesPerPage else { return rowsPerColumn }
        return max(1, Int(ceil(Double(remaining) / Double(columnCount))))
    }

    // MARK: - Pagination

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let info = NSPrintOperation.current?.printInfo {
            pageSize = NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
                              height: info.paperSize.height - info.topMargin - info.bottomMargin)
        }
        pageCount = max(1, Int(ceil(Double(job.lines.count) / Double(linesPerPage))))
        setFrameSize(NSSize(width: pageSize.width,
                            height: pageSize.height * CGFloat(pageCount)))
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * pageSize.height,
               width: pageSize.width, height: pageSize.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, pageSize.height > 0 else { return }
        let first = max(1, Int(dirtyRect.minY / pageSize.height) + 1)
        let last = min(pageCount, Int((dirtyRect.maxY - 0.5) / pageSize.height) + 1)
        guard first <= last else { return }
        for page in first...last { draw(page: page, in: context) }
    }

    private func draw(page: Int, in context: CGContext) {
        let top = CGFloat(page - 1) * pageSize.height
        drawPageHeader(top: top)

        let cell = self.cell
        let start = (page - 1) * linesPerPage
        guard start < job.lines.count else { return }
        context.setFillColor(Self.black.cgColor)

        let rows = rowsPerColumn(onPage: page)
        for offset in 0..<linesPerPage {
            let index = start + offset
            guard index < job.lines.count else { break }
            let column = offset / rows
            let origin = CGPoint(x: (columnWidth + gutter) * CGFloat(column),
                                 y: top + headerHeight
                                    + CGFloat(offset % rows) * lineHeight)
            switch job.lines[index] {
            case .petscii(let codes):
                PETSCIIVectorRenderer.draw(codes: codes, font: job.font,
                                           at: origin, cell: cell, in: context)
            case .text(let string):
                let font = NSFont.monospacedSystemFont(ofSize: cell * textSizeRatio,
                                                       weight: .regular)
                (string as NSString).draw(at: origin,
                                          withAttributes: [.font: font,
                                                           .foregroundColor: Self.black])
            case .blank:
                break
            }
        }

        drawPageFooter(top: top, page: page)
    }

    private func drawPageHeader(top: CGFloat) {
        (job.title as NSString).draw(
            in: NSRect(x: 0, y: top, width: pageSize.width, height: 15),
            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: Self.black])
        (job.subtitle as NSString).draw(
            in: NSRect(x: 0, y: top + 15, width: pageSize.width, height: 12),
            withAttributes: [.font: NSFont.systemFont(ofSize: 9),
                             .foregroundColor: Self.grey])
        Self.rule.setFill()
        NSRect(x: 0, y: top + headerHeight - 12, width: pageSize.width, height: 0.5).fill()
    }

    private func drawPageFooter(top: CGFloat, page: Int) {
        let y = top + pageSize.height - footerHeight + 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8),
            .foregroundColor: Self.grey
        ]
        (Self.stamp.string(from: printedOn) as NSString)
            .draw(at: CGPoint(x: 0, y: y), withAttributes: attributes)

        let number = "Page \(page) of \(pageCount)" as NSString
        let width = number.size(withAttributes: attributes).width
        number.draw(at: CGPoint(x: pageSize.width - width, y: y), withAttributes: attributes)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
