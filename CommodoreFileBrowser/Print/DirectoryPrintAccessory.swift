import AppKit

/// The browser's own pane in the system print dialog: how big a character is,
/// and whether the listing runs down the page once or twice.
///
/// It is built from system controls and sits beside the ones the printer
/// provides, so the size and the column count are chosen against the live
/// preview rather than in a dialog of our own beforehand.
final class DirectoryPrintAccessory: NSViewController, NSPrintPanelAccessorizing {

    /// The side of one character cell in points, which is near enough the size
    /// the listing reads at.
    @objc dynamic var cellPoints: Double {
        didSet {
            printView.cellPoints = CGFloat(cellPoints)
            sizeLabel.stringValue = Self.sizeText(cellPoints)
            onChange(cellPoints, columnCount)
        }
    }

    @objc dynamic var columnCount: Int {
        didSet {
            printView.columnCount = columnCount
            onChange(cellPoints, columnCount)
        }
    }

    private let printView: DirectoryPrintView
    /// Remembers the two choices, so the next listing prints the way the last
    /// one did.
    private let onChange: (Double, Int) -> Void
    private let sizeLabel = NSTextField(labelWithString: "")

    static let sizeRange: ClosedRange<Double> = 5...16

    init(printView: DirectoryPrintView, cellPoints: Double, columnCount: Int,
         onChange: @escaping (Double, Int) -> Void) {
        self.printView = printView
        self.cellPoints = cellPoints
        self.columnCount = columnCount
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = "Listing"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: - Controls

    override func loadView() {
        let slider = NSSlider(value: cellPoints,
                              minValue: Self.sizeRange.lowerBound,
                              maxValue: Self.sizeRange.upperBound,
                              target: self, action: #selector(sizeChanged))
        slider.isContinuous = true
        slider.numberOfTickMarks = Int(Self.sizeRange.upperBound - Self.sizeRange.lowerBound) + 1
        slider.allowsTickMarkValuesOnly = true

        sizeLabel.stringValue = Self.sizeText(cellPoints)
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let columns = NSSegmentedControl(labels: ["One", "Two"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(columnsChanged))
        columns.selectedSegment = max(0, min(1, columnCount - 1))

        let note = NSTextField(labelWithString:
            "Two columns fit a long listing on one sheet.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Size:"), slider, sizeLabel],
            [NSTextField(labelWithString: "Columns:"), columns],
            [NSGridCell.emptyContentView, note]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.cell(for: columns)?.row?.mergeCells(in: NSRange(location: 1, length: 2))
        grid.cell(for: note)?.row?.mergeCells(in: NSRange(location: 1, length: 2))
        grid.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 110))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        view = container
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        cellPoints = sender.doubleValue
    }

    @objc private func columnsChanged(_ sender: NSSegmentedControl) {
        columnCount = sender.selectedSegment + 1
    }

    // MARK: - NSPrintPanelAccessorizing

    /// The preview is redrawn when either of these changes, which is what makes
    /// the slider and the segments answer straight away.
    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["cellPoints", "columnCount"]
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [
            [.itemName: "Listing size", .itemDescription: Self.sizeText(cellPoints)],
            [.itemName: "Columns", .itemDescription: columnCount == 2 ? "Two" : "One"]
        ]
    }

    private static func sizeText(_ points: Double) -> String {
        "\(Int(points.rounded())) pt"
    }
}

/// Carries the print sheet's callback back to the model.
///
/// `runModal(for:delegate:didRun:contextInfo:)` calls back through an
/// Objective-C selector, which needs an `NSObject` to send it to — the model is
/// a plain Swift class and cannot be one.
final class PrintCompletion: NSObject {

    private let done: () -> Void

    init(done: @escaping () -> Void) { self.done = done }

    @objc func printOperationDidRun(_ operation: NSPrintOperation,
                                    success: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        done()
    }
}
