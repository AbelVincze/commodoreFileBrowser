import AppKit
import SwiftUI

/// What a drop would do, worked out fresh on every mouse move because the
/// answer depends on where the pointer is and whether Option is down.
struct DropPlan {
    var destination: PanelLocation
    var isMove: Bool
    var highlight: DropHighlight
}

/// Where the files being dragged are coming from, gathered before the rules
/// are applied so that the rules themselves need nothing but this.
struct DropSource {
    /// The folder they are all in, when they are all in one and it is known.
    var location: PanelLocation?
    /// Their paths on the file system, for the ones that have one. A row
    /// inside an image does not.
    var urls: [URL] = []
    var hasFolder = false
}

/// The drag this app started, for as long as it is in flight.
struct PanelDragSession {
    var side: PanelSide
    /// Where the rows came from, so a drop back into the same folder can be
    /// refused and the move-or-copy question can be answered.
    var location: PanelLocation
    var items: [PanelItem]
}

/// The source end of a drag: it builds the dragging items, holds what is being
/// dragged while the session runs, and answers AppKit's questions about it.
///
/// Rows that live inside an image are written out to the temporary folder
/// first. A directory entry is not a file, so there is nothing to hand another
/// application until one exists; extracting up front rather than promising the
/// bytes later also means the copy is made while the panel is still standing on
/// the image it came from.
final class DragCoordinator: NSObject, NSDraggingSource {

    weak var model: AppModel?
    private(set) var session: PanelDragSession?

    /// The last read of the drag pasteboard, kept per change count: a drop
    /// target asks for the dragged files on every mouse move.
    private var cachedChangeCount = -1
    private var cachedURLs: [URL] = []
    /// A pasteboard whose drag is over. Its files are still on it, and SwiftUI
    /// asks a drop target one more time after the mouse is up, so without this
    /// the answer would come from the drag that has just ended and leave the
    /// panel outlined with nothing over it.
    private var retiredChangeCount = -1

    // MARK: - Starting a drag

    /// Begin dragging `items` out of `panel`. Returns false when there is
    /// nothing to drag or the mouse event that would carry the session has
    /// gone, which leaves the gesture free to try again on the next move.
    @discardableResult
    func begin(items: [PanelItem], from panel: PanelModel) -> Bool {
        guard session == nil, !items.isEmpty else { return false }
        // The gesture only fires with the button down, so the event in hand is
        // part of the same press whichever of the two it turns out to be — and
        // AppKit will carry a session on either.
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDragged || event.type == .leftMouseDown,
              let window = event.window ?? NSApp.keyWindow,
              let view = window.contentView
        else { return false }

        let origin = view.convert(event.locationInWindow, from: nil)
        var dragItems: [NSDraggingItem] = []
        var dragged: [PanelItem] = []

        for item in items {
            guard let url = fileURL(for: item, in: panel) else { continue }
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let picture = Self.dragImage(for: url, title: item.title)
            let offset = CGFloat(dragged.count) * 4
            dragItem.setDraggingFrame(NSRect(x: origin.x - 14,
                                             y: origin.y - picture.size.height / 2 - offset,
                                             width: picture.size.width,
                                             height: picture.size.height),
                                      contents: picture)
            dragItems.append(dragItem)
            dragged.append(item)
        }
        guard !dragItems.isEmpty else { return false }

        session = PanelDragSession(side: panel.side, location: panel.location, items: dragged)
        let dragging = view.beginDraggingSession(with: dragItems, event: event, source: self)
        dragging.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    /// The path behind a row: its own on the file system, or a copy written to
    /// the temporary folder for an entry that only exists inside an image.
    private func fileURL(for item: PanelItem, in panel: PanelModel) -> URL? {
        if let url = item.url { return url }
        guard let image = panel.image, let entry = item.cbm, !entry.isDirectory,
              let data = try? image.read(entry, at: panel.location.imagePath)
        else { return nil }
        let folder = HostHandoff.temporaryFolder(for: image.url)
            .appendingPathComponent("Drag", isDirectory: true)
        let name = entry.hostFileName(addingExtension: model?.settings.addHostExtension ?? true)
        // Writable, unlike the copies made for "Open With": this one is the
        // file the user is putting somewhere, not a look at one.
        return try? HostHandoff.write(data, named: name, in: folder, readOnly: false)
    }

    /// What the pointer carries: the file's own icon with its name beside it.
    private static func dragImage(for url: URL, title: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 20, height: 20)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: min(280, 30 + ceil(textSize.width) + 10), height: 24)

        let picture = NSImage(size: size)
        picture.lockFocus()
        NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 5, yRadius: 5).fill()
        icon.draw(in: NSRect(x: 4, y: 2, width: 20, height: 20))
        text.draw(in: NSRect(x: 30, y: (size.height - textSize.height) / 2,
                             width: size.width - 36, height: textSize.height),
                  withAttributes: attributes)
        picture.unlockFocus()
        return picture
    }

    // MARK: - The files another application is dragging in

    func externalURLs() -> [URL] {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.changeCount == retiredChangeCount { return [] }
        if pasteboard.changeCount != cachedChangeCount {
            cachedChangeCount = pasteboard.changeCount
            cachedURLs = (pasteboard.readObjects(forClasses: [NSURL.self],
                                                 options: [.urlReadingFileURLsOnly: true])
                          as? [URL]) ?? []
        }
        return cachedURLs
    }

    /// Nothing more is being dragged: forget the pasteboard as it stands.
    func retireDrag() {
        retiredChangeCount = NSPasteboard(name: .drag).changeCount
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ dragging: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Both, everywhere: inside the app this side does the work and the
        // destination only says which it wants, and outside it Finder decides
        // for itself the same way it would for any other file.
        [.copy, .move]
    }

    func draggingSession(_ dragging: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        session = nil
        retireDrag()
        model?.left.dropHighlight = nil
        model?.right.dropHighlight = nil
        // A move made by the receiver happens after the drag has ended — the
        // Finder a moment later, on a queue of its own — so there is nothing
        // to redraw yet. The panels watch the folders they are showing and
        // follow the files out on their own.
    }
}

/// The receiving end: one of these on every row, and one on the listing behind
/// them for everywhere that is not a row.
///
/// Where the drop lands and what it does are worked out together in `plan`,
/// which is asked again on every mouse move: the pointer may have crossed onto
/// a folder row, or Option may have gone down since the last one.
struct PanelDropDelegate: DropDelegate {

    let model: AppModel
    let panel: PanelModel
    /// The row this one sits on, or nil for the listing as a whole.
    var row: PanelItem?

    // MARK: - DropDelegate

    func validateDrop(info: DropInfo) -> Bool { plan() != nil }

    func dropEntered(info: DropInfo) { show(plan()) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let plan = plan() else {
            show(nil)
            return DropProposal(operation: .forbidden)
        }
        show(plan)
        return DropProposal(operation: plan.isMove ? .move : .copy)
    }

    func dropExited(info: DropInfo) { show(nil) }

    func performDrop(info: DropInfo) -> Bool {
        show(nil)
        guard let plan = plan() else { return false }

        let items: [PanelItem]
        let source: PanelSide?
        if let session = model.dragCoordinator.session {
            items = session.items
            source = session.side
        } else {
            let urls = model.dragCoordinator.externalURLs()
            guard !urls.isEmpty else { return false }
            items = urls.enumerated().map { PanelDropDelegate.item(for: $1, id: $0) }
            source = nil
        }
        // Read the pasteboard before retiring it, not after.
        model.dragCoordinator.retireDrag()

        // Off the drag's own call stack: the transfer redraws both panels and
        // may put an alert up, neither of which belongs inside the gesture
        // that is still finishing.
        let target = panel.side
        DispatchQueue.main.async {
            model.performDrop(items: items, from: source, to: target,
                              destination: plan.destination, isMove: plan.isMove)
        }
        return true
    }

    private func show(_ plan: DropPlan?) {
        if panel.dropHighlight != plan?.highlight { panel.dropHighlight = plan?.highlight }
    }

    // MARK: - Working out the drop

    /// The folder the drop would go into, and the highlight that says so.
    private func target() -> (destination: PanelLocation, highlight: DropHighlight)? {
        switch panel.location {
        case .volumes:
            // Nothing to drop into but a volume itself.
            guard let row, row.kind == .volume, let url = row.url else { return nil }
            return (.directory(url), .row(row.id))
        case .directory(let url):
            if let row, row.kind == .folder, let folder = row.url {
                return (.directory(folder), .row(row.id))
            }
            return (.directory(url), .panel)
        case .image(let url, let path):
            if let row, row.kind == .imageFolder, panel.image?.supportsDirectories == true {
                return (.image(url, path: path + [row.title]), .row(row.id))
            }
            return (.image(url, path: path), .panel)
        }
    }

    /// What the drop under the pointer would do right now, or nil for one this
    /// row will not take.
    func plan() -> DropPlan? {
        guard let target = target() else { return nil }
        if case .image = target.destination, panel.image?.canWrite != true { return nil }
        guard let source = dragSource() else { return nil }
        return Self.plan(dropping: source, onto: target.destination,
                         highlight: target.highlight,
                         optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    /// Our own drag if there is one, and otherwise whatever another
    /// application is holding over the window.
    private func dragSource() -> DropSource? {
        if let session = model.dragCoordinator.session {
            return DropSource(location: session.location,
                              urls: session.items.compactMap(\.url),
                              hasFolder: session.items.contains { $0.kind == .folder })
        }
        let urls = model.dragCoordinator.externalURLs()
        guard !urls.isEmpty else { return nil }
        // Files dragged in from one folder can be recognised as already being
        // where they would land; a selection gathered from several cannot.
        let parents = Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL })
        return DropSource(location: parents.count == 1 ? .directory(parents.first!) : nil,
                          urls: urls,
                          hasFolder: urls.contains {
                              (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                          })
    }

    /// The rules themselves, with nothing behind them: what a drop of `source`
    /// into `destination` would do, or nil for one that would do nothing.
    static func plan(dropping source: DropSource, onto destination: PanelLocation,
                     highlight: DropHighlight, optionHeld: Bool) -> DropPlan? {
        // Dropping where the files already are does nothing.
        if let from = source.location, from == destination { return nil }
        // A folder has no shape a disk image can hold.
        if case .image = destination, source.hasFolder { return nil }
        // And nothing can be dropped inside itself.
        if case .directory(let folder) = destination {
            let path = folder.standardizedFileURL.path
            for url in source.urls {
                let inside = url.standardizedFileURL.path
                if path == inside || path.hasPrefix(inside + "/") { return nil }
            }
        }

        let from = source.location.flatMap(volumeIdentity(of:))
            ?? source.urls.first.map(volumeIdentity(ofFile:))
        var isMove = from != nil && from == volumeIdentity(of: destination)
        // The same switch the Finder puts on Option: whichever of move and
        // copy the two volumes imply, this asks for the other one.
        if optionHeld { isMove.toggle() }

        return DropPlan(destination: destination, isMove: isMove, highlight: highlight)
    }

    /// Two locations on the same volume move; two on different volumes copy.
    /// The inside of an image counts as a volume of its own, so everything
    /// crossing that boundary is a copy — which is what it has to be, since
    /// the bytes are rewritten in another format on the way.
    static func volumeIdentity(of location: PanelLocation) -> String? {
        switch location {
        case .volumes: return nil
        case .directory(let url): return volumeIdentity(ofFile: url)
        case .image(let url, _): return "image:" + url.standardizedFileURL.path
        }
    }

    static func volumeIdentity(ofFile url: URL) -> String {
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        return "volume:" + (volume?.standardizedFileURL.path ?? "/")
    }

    /// A row standing for a file dragged in from outside, so the transfer sees
    /// the same kind of thing whichever side the drag started on.
    static func item(for url: URL, id: Int) -> PanelItem {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let kind: PanelItem.Kind = isDirectory ? .folder
            : (DiskImageFactory.isImage(url) ? .diskImage : .file)
        return PanelItem(id: id, kind: kind, title: url.lastPathComponent, detail: "", url: url)
    }
}
