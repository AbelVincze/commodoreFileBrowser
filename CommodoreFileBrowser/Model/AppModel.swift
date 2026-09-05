import SwiftUI
import AppKit

/// A copy or move waiting for the user to confirm it.
struct TransferPlan {
    var isMove: Bool
    var items: [PanelItem]
    var destination: PanelLocation
    var destinationLabel: String
    /// Editable when exactly one item is being transferred.
    var targetName: String
    var overwrite: Bool = false

    var verb: String { isMove ? "Move" : "Copy" }
    var summary: String {
        items.count == 1 ? "\"\(items[0].title)\"" : "\(items.count) items"
    }
}

struct ViewerContent: Identifiable {
    let id = UUID()
    var title: String
    var data: Data
    var isPRG: Bool
    /// Shift+F3 opens straight into the bitmap view.
    var startInBitmap: Bool = false
}

enum AppSheet: Identifiable {
    case transfer(TransferPlan)
    case delete([PanelItem])
    case rename(PanelItem)
    case makeFolder
    case newImage
    case diskHeader
    case viewer(ViewerContent)
    case addDecoration
    case discardChanges
    case help

    var id: String {
        switch self {
        case .transfer(let p): return "transfer-\(p.isMove)"
        case .delete: return "delete"
        case .rename: return "rename"
        case .makeFolder: return "mkdir"
        case .newImage: return "newimage"
        case .diskHeader: return "header"
        case .viewer(let v): return "viewer-\(v.id)"
        case .addDecoration: return "decorate"
        case .discardChanges: return "discard"
        case .help: return "help"
        }
    }
}

final class AppModel: ObservableObject {

    let left = PanelModel(side: .left)
    let right = PanelModel(side: .right)
    let settings: SettingsStore

    @Published var activeSide: PanelSide = .left
    @Published var sheet: AppSheet?
    @Published var alertMessage: String?
    @Published var statusMessage: String = ""

    var activePanel: PanelModel { activeSide == .left ? left : right }
    var inactivePanel: PanelModel { activeSide == .left ? right : left }

    init(settings: SettingsStore) {
        self.settings = settings
        applyHiddenSetting()
        left.restoreLocation()
        right.restoreLocation()
    }

    func applyHiddenSetting() {
        left.showHidden = settings.showHiddenFiles
        right.showHidden = settings.showHiddenFiles
    }

    func refreshBoth() {
        left.refresh()
        right.refresh()
    }

    func saveState() {
        left.saveLocation()
        right.saveLocation()
        try? left.image?.save()
        try? right.image?.save()
    }

    private func fail(_ error: Error) {
        alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Character set chord

    /// True while Control+Shift is being held, so the chord fires once per press.
    private var charsetChordHeld = false

    /// Control+Shift flips between the upper and lower case halves of the
    /// character ROM, the way Commodore+Shift does on a real machine. It is a
    /// modifier-only chord, so it arrives as a flagsChanged event rather than
    /// a key press.
    func handleFlags(_ event: NSEvent) {
        guard sheet == nil else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isChord = flags.contains(.control) && flags.contains(.shift)
            && !flags.contains(.command) && !flags.contains(.option)
        if isChord {
            if !charsetChordHeld {
                charsetChordHeld = true
                toggleCharacterSet()
            }
        } else {
            charsetChordHeld = false
        }
    }

    func toggleCharacterSet() {
        settings.font.set = settings.font.set == .uppercase ? .lowercase : .uppercase
        statusMessage = settings.font.set.label
    }

    // MARK: - Key handling

    /// Returns true when the key was consumed by the browser.
    func handleKey(_ event: NSEvent) -> Bool {
        guard sheet == nil else { return false }
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        if command, event.charactersIgnoringModifiers?.lowercased() != "r" { return false }

        switch Int(event.keyCode) {
        case 126: activePanel.moveCursor(by: shift ? -10 : -1)          // up
        case 125: activePanel.moveCursor(by: shift ? 10 : 1)            // down
        case 116: activePanel.moveCursor(by: -20)                        // page up
        case 121: activePanel.moveCursor(by: 20)                         // page down
        case 115: activePanel.moveCursor(to: 0)                          // home
        case 119: activePanel.moveCursor(to: Int.max)                    // end
        case 48:  activeSide = activeSide == .left ? .right : .left      // tab
        case 49:  activePanel.toggleMark()                               // space
        case 36, 76: activePanel.open()                                  // return / enter
        case 51, 123: activePanel.goUp()                                 // backspace / left
        case 124: activePanel.open(allowParent: false)                   // right
        case 53: leaveDiscardingChanges()                                // escape
        case 122: sheet = .help                                          // F1
        case 120: beginNewImage()                                        // F2
        case 99:  beginView(bitmap: shift)                               // F3 / shift F3
        case 118: beginEditHeader()                                      // F4
        case 96:  beginTransfer(isMove: false)                           // F5
        case 97:  shift ? beginRename() : beginTransfer(isMove: true)    // F6
        case 98:  beginMakeFolder()                                      // F7
        case 100: beginDelete()                                          // F8
        case 101: beginRename()                                          // F9
        case 109: NSApp.terminate(nil)                                   // F10
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r" where command: beginRename()
            case "*": activePanel.invertMarks()
            case "+": activePanel.markAll()
            case "-": activePanel.unmarkAll()
            default: return false
            }
        }
        return true
    }

    // MARK: - Leaving an image

    /// Escape walks up without committing anything. Edits to an image live in
    /// memory until the panel leaves it normally, so the user is warned first.
    func leaveDiscardingChanges() {
        guard activePanel.hasUnsavedChanges else {
            activePanel.goUp(keepChanges: false)
            return
        }
        sheet = .discardChanges
    }

    func performDiscard() {
        let name = activePanel.headerTitle
        activePanel.goUp(keepChanges: false)
        statusMessage = "Discarded the changes to \(name)"
    }

    /// The escape hatch out of the discard prompt: commit, then leave.
    func performSaveAndLeave() {
        let name = activePanel.headerTitle
        activePanel.goUp(keepChanges: true)
        statusMessage = "Saved \(name)"
    }

    /// Write the open image out without leaving it.
    func saveActiveImage() {
        guard activePanel.image != nil else { return }
        guard activePanel.hasUnsavedChanges else {
            statusMessage = "No changes to save"
            return
        }
        let name = activePanel.headerTitle
        if let error = activePanel.saveImage() {
            fail(error)
        } else {
            statusMessage = "Saved \(name)"
            activePanel.objectWillChange.send()
        }
    }

    // MARK: - Reading and writing items

    private struct Payload {
        var data: Data
        var hostName: String
        var cbmName: [UInt8]
        var type: CBMFileType
    }

    private func read(_ item: PanelItem, from panel: PanelModel) throws -> Payload {
        switch item.kind {
        case .cbmFile:
            guard let image = panel.image, let entry = item.cbm else { throw DiskImageError.fileNotFound }
            let data = try image.read(entry)
            return Payload(data: data,
                           hostName: PETSCII.hostFileName(entry.name, type: entry.type),
                           cbmName: entry.name,
                           type: entry.type)
        default:
            guard let url = item.url else { throw DiskImageError.fileNotFound }
            let data = try Data(contentsOf: url)
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.lowercased()
            let known = ["prg", "seq", "usr", "rel", "del"].contains(ext)
            return Payload(data: data,
                           hostName: url.lastPathComponent,
                           cbmName: PETSCII.cbmName(fromASCII: known ? base : url.lastPathComponent),
                           type: known ? CBMFileType.from(fileExtension: ext) : .prg)
        }
    }

    // MARK: - Copy / move

    func beginTransfer(isMove: Bool) {
        let items = activePanel.actionItems
        guard !items.isEmpty else { return }
        let destination = inactivePanel.location
        if case .volumes = destination {
            alertMessage = "Choose a folder or an image on the other side first."
            return
        }
        var name = items.count == 1 ? items[0].title : ""
        if items.count == 1, case .directory = destination, items[0].kind == .cbmFile,
           let entry = items[0].cbm {
            name = PETSCII.hostFileName(entry.name, type: entry.type)
        }
        sheet = .transfer(TransferPlan(isMove: isMove, items: items, destination: destination,
                                       destinationLabel: inactivePanel.headerTitle, targetName: name))
    }

    func perform(_ plan: TransferPlan) {
        let source = activePanel
        let target = inactivePanel
        var copied = 0, skipped = 0
        var firstError: Error?

        for item in plan.items {
            do {
                let renameTo = plan.items.count == 1 ? plan.targetName : nil
                if item.kind == .folder {
                    guard case .directory(let destURL) = plan.destination else {
                        throw TransferError.folderIntoImage
                    }
                    guard let src = item.url else { continue }
                    let dst = destURL.appendingPathComponent(renameTo ?? item.title)
                    if FileManager.default.fileExists(atPath: dst.path) {
                        if plan.overwrite { try FileManager.default.removeItem(at: dst) }
                        else { skipped += 1; continue }
                    }
                    try FileManager.default.copyItem(at: src, to: dst)
                    if plan.isMove { try FileManager.default.removeItem(at: src) }
                    copied += 1
                    continue
                }

                let payload = try read(item, from: source)
                switch plan.destination {
                case .volumes:
                    throw TransferError.noDestination

                case .directory(let destURL):
                    let name = renameTo ?? payload.hostName
                    let dst = destURL.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: dst.path) {
                        if plan.overwrite { try FileManager.default.removeItem(at: dst) }
                        else { skipped += 1; continue }
                    }
                    try payload.data.write(to: dst, options: .atomic)
                    copied += 1

                case .image:
                    guard let image = target.image else { throw TransferError.noDestination }
                    guard image.canWrite else { throw DiskImageError.readOnly }
                    let name = renameTo.map { PETSCII.cbmName(fromASCII: ($0 as NSString).deletingPathExtension) }
                        ?? payload.cbmName
                    if let existing = image.entries.first(where: { $0.name == PETSCII.trimPadding(name) }) {
                        if plan.overwrite { try image.delete(existing) }
                        else { skipped += 1; continue }
                    }
                    try image.write(name: name, type: payload.type, data: payload.data)
                    copied += 1
                }

                if plan.isMove { try delete(item, in: source, toTrash: false) }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        finishOperation(verb: plan.isMove ? "Moved" : "Copied", count: copied, skipped: skipped, error: firstError)
    }

    enum TransferError: LocalizedError {
        case folderIntoImage, noDestination
        var errorDescription: String? {
            switch self {
            case .folderIntoImage: return "Folders cannot be copied into a disk image."
            case .noDestination: return "The other panel is not a folder or an image."
            }
        }
    }

    // MARK: - Delete

    func beginDelete() {
        let items = activePanel.actionItems
        guard !items.isEmpty else { return }
        sheet = .delete(items)
    }

    func performDelete(_ items: [PanelItem]) {
        let panel = activePanel
        var removed = 0
        var firstError: Error?
        for item in items {
            do {
                try delete(item, in: panel, toTrash: settings.deleteToTrash)
                removed += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        finishOperation(verb: "Deleted", count: removed, skipped: 0, error: firstError)
    }

    private func delete(_ item: PanelItem, in panel: PanelModel, toTrash: Bool) throws {
        switch item.kind {
        case .cbmFile:
            guard let image = panel.image, let entry = item.cbm else { throw DiskImageError.fileNotFound }
            try image.delete(entry)
        case .file, .folder, .diskImage:
            guard let url = item.url else { throw DiskImageError.fileNotFound }
            if toTrash {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        case .parent, .volume:
            break
        }
    }

    // MARK: - Rename

    func beginRename() {
        guard let item = activePanel.currentItem, item.isSelectable else { return }
        sheet = .rename(item)
    }

    func performRename(_ item: PanelItem, to newName: String) {
        let panel = activePanel
        do {
            switch item.kind {
            case .cbmFile:
                guard let image = panel.image, let entry = item.cbm else { throw DiskImageError.fileNotFound }
                try image.rename(entry, to: PETSCII.cbmName(fromASCII: newName))
            default:
                guard let url = item.url else { throw DiskImageError.fileNotFound }
                let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
                try FileManager.default.moveItem(at: url, to: dst)
            }
            finishOperation(verb: "Renamed", count: 1, skipped: 0, error: nil)
        } catch {
            fail(error)
        }
    }

    // MARK: - New folder / image / header

    func beginMakeFolder() {
        guard case .directory = activePanel.location else {
            alertMessage = "Folders can only be created on the file system."
            return
        }
        sheet = .makeFolder
    }

    func performMakeFolder(named name: String) {
        guard case .directory(let url) = activePanel.location else { return }
        do {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(name),
                                                    withIntermediateDirectories: false)
            finishOperation(verb: "Created", count: 1, skipped: 0, error: nil)
        } catch { fail(error) }
    }

    func beginNewImage() {
        guard case .directory = activePanel.location else {
            alertMessage = "Open a folder in the active panel to create an image in it."
            return
        }
        sheet = .newImage
    }

    func performNewImage(kind: CBMDiskImage.BlankFormat, fileName: String, diskName: String, diskID: String) {
        guard case .directory(let dir) = activePanel.location else { return }
        var name = fileName
        if !name.lowercased().hasSuffix(".\(kind.fileExtension)") { name += ".\(kind.fileExtension)" }
        do {
            try CBMDiskImage.createBlank(kind,
                                         name: PETSCII.cbmName(fromASCII: diskName),
                                         id: PETSCII.petscii(fromASCII: diskID.isEmpty ? "01" : diskID),
                                         at: dir.appendingPathComponent(name))
            finishOperation(verb: "Created", count: 1, skipped: 0, error: nil)
        } catch { fail(error) }
    }

    func beginEditHeader() {
        guard activePanel.image != nil else {
            alertMessage = "Open a disk image to edit its header."
            return
        }
        sheet = .diskHeader
    }

    func performEditHeader(name: String, id: String) {
        guard let image = activePanel.image else { return }
        do {
            try image.setDiskHeader(name: PETSCII.cbmName(fromASCII: name),
                                    id: PETSCII.petscii(fromASCII: id))
            activePanel.refreshImage()
            statusMessage = "Disk header updated"
        } catch { fail(error) }
    }

    // MARK: - Directory decoration

    func moveEntry(by delta: Int) {
        guard let image = activePanel.image, let entry = activePanel.currentItem?.cbm else { return }
        do {
            try image.moveEntry(entry, by: delta)
            let newCursor = activePanel.cursor + delta
            activePanel.refreshImage()
            activePanel.moveCursor(to: newCursor)
        } catch { fail(error) }
    }

    func addDecorativeEntry(named name: String) {
        guard let image = activePanel.image else { return }
        do {
            try image.addDecorativeEntry(name: PETSCII.cbmName(fromASCII: name),
                                         after: activePanel.currentItem?.cbm)
            activePanel.refreshImage()
            statusMessage = "Added DEL entry"
        } catch { fail(error) }
    }

    func toggleLock() {
        guard let image = activePanel.image, let entry = activePanel.currentItem?.cbm else { return }
        do {
            try image.setLocked(entry, locked: !entry.isLocked)
            activePanel.refreshImage()
        } catch { fail(error) }
    }

    // MARK: - Viewer

    func beginView(bitmap: Bool = false) {
        guard let item = activePanel.currentItem, item.isSelectable, item.kind != .folder else { return }
        do {
            let payload = try read(item, from: activePanel)
            let isPRG = item.kind == .cbmFile ? item.cbm?.type == .prg
                                              : item.url?.pathExtension.lowercased() == "prg"
            sheet = .viewer(ViewerContent(title: item.title, data: payload.data,
                                          isPRG: isPRG, startInBitmap: bitmap))
        } catch { fail(error) }
    }

    // MARK: - Completion

    private func finishOperation(verb: String, count: Int, skipped: Int, error: Error?) {
        // Both sides are rebuilt: they may show the same folder or image.
        // refresh() redraws a modified image from memory - reload() would go
        // back to the untouched file on disk and lose the pending edits.
        activePanel.refresh()
        inactivePanel.refresh()

        var message = "\(verb) \(count) item\(count == 1 ? "" : "s")"
        if skipped > 0 { message += " · \(skipped) skipped (already exists)" }
        statusMessage = message
        if let error { fail(error) }
    }
}
