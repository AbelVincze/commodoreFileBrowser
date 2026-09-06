import SwiftUI
import AppKit

/// The right-click menu on a listing row.
///
/// Two jobs. It is where the browser meets the system — open, open with, show
/// in Finder — and it is where the commands that were only ever on function
/// keys become findable with a mouse.
///
/// Every item acts on the row the menu belongs to, not on the cursor: the
/// commands themselves all read `currentItem` or `actionItems`, so each action
/// puts the cursor on that row before running. SwiftUI gives no hook for the
/// moment a context menu opens, which is why it happens here rather than as a
/// selection change when the menu appears.
struct RowContextMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var panel: PanelModel
    let item: PanelItem

    /// An entry inside an image is a copy once it leaves, and saying so in the
    /// menu is the only warning there is going to be.
    private var isInsideImage: Bool { item.kind.isInsideImage }
    private var openTitle: String { isInsideImage ? "Open Copy" : "Open" }
    private var openWithTitle: String { isInsideImage ? "Open Copy With" : "Open With" }
    private var revealTitle: String { isInsideImage ? "Show Image in Finder" : "Show in Finder" }

    var body: some View {
        // The parent row is a way back up, not a file: nothing here applies.
        if item.isSelectable {
            if item.kind.isNavigable {
                Button("Open in Panel") { run { model.activateItem() } }
                Divider()
            }

            Button(openTitle) { run { model.openWithSystem(item) } }
            openWith
            Button(revealTitle) { run { model.revealInFinder(item) } }

            Divider()

            if item.kind != .folder, item.kind != .volume {
                Button("View") { run { model.beginView() } }
                Button("View as Bitmap") { run { model.beginView(bitmap: true) } }
                Button("Play as SID…") { run { model.beginPlay(manual: true) } }
                Divider()
            }

            // Copy, move and delete work on the marked files when there are
            // any, wherever the menu was opened. Naming the count is what
            // stops that being a surprise: right clicking an unmarked row
            // does not quietly act on it alone.
            Button("Copy \(subject) to Other Panel") { run { model.beginTransfer(isMove: false) } }
            Button("Move \(subject) to Other Panel") { run { model.beginTransfer(isMove: true) } }
            Button("Rename…") { run { model.beginRename() } }
            Button("Delete \(subject)") { run { model.beginDelete() } }
        }
    }

    @ViewBuilder
    private var openWith: some View {
        let applications = model.applications(for: item)
        Menu(openWithTitle) {
            ForEach(applications, id: \.self) { application in
                Button {
                    run { model.openWithSystem(item, using: application) }
                } label: {
                    // The icon makes a list of names scannable, and it is the
                    // one place the menu can look like the system's own.
                    Label {
                        Text(HostOpener.name(of: application))
                    } icon: {
                        Image(nsImage: HostOpener.icon(of: application))
                    }
                }
            }
            if !applications.isEmpty { Divider() }
            Button("Choose Application…") {
                run {
                    if let application = HostOpener.chooseApplication() {
                        model.openWithSystem(item, using: application)
                    }
                }
            }
        }
    }

    /// What copy, move and delete are about to act on.
    private var subject: String {
        let marked = panel.marked.count
        return marked > 0 ? "\(marked) Marked File\(marked == 1 ? "" : "s")" : "“\(item.title)”"
    }

    /// Put the cursor on this row, in this panel, and then run the command.
    private func run(_ action: () -> Void) {
        model.activeSide = panel.side
        panel.moveCursor(to: item.id)
        action()
    }
}
