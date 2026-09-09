import SwiftUI
import AppKit
import Combine

/// A copy or move waiting for the user to confirm it.
struct TransferPlan {
    var isMove: Bool
    var items: [PanelItem]
    var destination: PanelLocation
    var destinationLabel: String
    /// Editable when exactly one item is being transferred.
    var targetName: String
    var overwrite: Bool = false
    /// Copying out of a Commodore image, the name picks up the file type as an
    /// extension — `.prg`, `.seq`, `.usr`, `.rel` — since that is the only
    /// place the type survives. Off writes the plain Commodore name.
    var addsHostExtension: Bool = true
    /// Whether that choice means anything here: only on the way out of a
    /// Commodore image, since an Amiga name carries no type and a name going
    /// into an image loses its extension anyway.
    var canAddHostExtension: Bool = false
    /// The two spellings of a single item's name, so the field can follow the
    /// checkbox without having to work out the extension a second time.
    var nameWithExtension: String = ""
    var nameWithoutExtension: String = ""
    /// Which panel the rows come from, and which one they are going to. Nil on
    /// the source side means they came from outside the app, dropped in from
    /// the Finder, and there is no panel behind them to read or scratch from.
    var sourceSide: PanelSide?
    var targetSide: PanelSide = .right
    /// Whether `targetName` is a name the user typed. A drag says no: it puts
    /// the files down under the names they already have.
    var renamesSingleItem = true

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
    /// Which pane the sheet opens on: ⇧F3 asks for the bitmap, and an Amiga
    /// picture opens on itself rather than on a hex dump of itself.
    var startMode: ViewerMode = .hex
}

enum AppSheet: Identifiable {
    case transfer(TransferPlan)
    case delete([PanelItem])
    case rename(PanelItem)
    case makeFolder
    case newImage
    case diskHeader
    case repairDisk
    case viewer(ViewerContent)
    case addDecoration
    case player
    case module
    case sample
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
        case .repairDisk: return "repair"
        case .viewer(let v): return "viewer-\(v.id)"
        case .addDecoration: return "decorate"
        case .player: return "player"
        case .module: return "module"
        case .sample: return "sample"
        case .discardChanges: return "discard"
        case .help: return "help"
        }
    }
}

final class AppModel: ObservableObject {

    let left = PanelModel(side: .left)
    let right = PanelModel(side: .right)
    let settings: SettingsStore
    let player = SIDPlayer()
    let modulePlayer = ModulePlayer()
    let samplePlayer = SamplePlayer()
    /// The source end of every drag started in this window, and the state that
    /// tells a drop it came from one of our own panels.
    let dragCoordinator = DragCoordinator()

    @Published var activeSide: PanelSide = .left
    @Published var sheet: AppSheet?
    @Published var alertMessage: String?
    @Published var statusMessage: String = ""
    /// The tune the player sheet is showing. Held apart from `sheet` so it can
    /// change while the sheet stays up.
    @Published var playerRequest: SIDRequest?
    /// The module the tracker sheet is showing, held apart from `sheet` for
    /// the same reason.
    @Published var moduleRequest: ModuleRequest?
    /// And the sample the 8SVX sheet is showing.
    @Published var sampleRequest: SampleRequest?
    /// What the repair sheet is reporting, held apart from `sheet` the same
    /// way, since it is a value the sheet reads rather than one it owns.
    @Published var repairPlan: DiskRepairPlan?
    /// The open image, when it is a Commodore one that could be repaired.
    /// An Amiga volume keeps a bitmap of its own and knows nothing of a BAM.
    var repairableImage: CBMDiskImage? {
        guard let image = activePanel.image as? CBMDiskImage, image.canWrite else { return nil }
        return image
    }

    /// Whether the open image has a directory whose order can be rearranged.
    /// Kept here rather than read off the panel when the menu is drawn: the
    /// menu is rebuilt from what it observes on this object, and the panels
    /// are objects of their own.
    @Published private(set) var canReorderEntries = false

    /// True while anything modal is on screen. The error alert is not an
    /// `AppSheet` case, so "is a dialog up" has to name both of them.
    var isPresentingModal: Bool { sheet != nil || alertMessage != nil }

    private var panelWatch: Set<AnyCancellable> = []

    var activePanel: PanelModel { activeSide == .left ? left : right }
    var inactivePanel: PanelModel { activeSide == .left ? right : left }
    var inactiveSide: PanelSide { activeSide == .left ? .right : .left }

    func panel(_ side: PanelSide) -> PanelModel { side == .left ? left : right }

    init(settings: SettingsStore) {
        self.settings = settings
        applyHiddenSetting()
        dragCoordinator.model = self
        left.restoreLocation()
        right.restoreLocation()

        for panel in [left, right] {
            panel.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.refreshMenuState() }
                .store(in: &panelWatch)
        }
        $activeSide
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMenuState() }
            .store(in: &panelWatch)

        // A status line reports what just happened, here, in the panel it is
        // drawn under. Switching sides or walking somewhere else leaves it
        // describing a place that is no longer on screen, so it goes as soon
        // as either changes.
        //
        // Delivered as it happens rather than on the next run loop pass: a
        // `@Published` fires before the value lands, so the handful of actions
        // that navigate and then say what they did — leaving an image, and
        // discarding — still get to keep their message.
        for panel in [left, right] {
            panel.$location
                .dropFirst()
                .sink { [weak self] _ in self?.statusMessage = "" }
                .store(in: &panelWatch)
        }
        $activeSide
            .dropFirst()
            .sink { [weak self] _ in self?.statusMessage = "" }
            .store(in: &panelWatch)

        refreshMenuState()
    }

    /// Republished only when the answer changes, so following the panels this
    /// closely costs nothing on a cursor move.
    private func refreshMenuState() {
        let can = activePanel.image?.supportsEntryReordering ?? false
        if can != canReorderEntries { canReorderEntries = can }
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
        report((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    /// Say what went wrong, somewhere it will actually be read.
    ///
    /// An alert raised while a sheet is up is worse than useless. SwiftUI holds
    /// it back until the sheet goes, so nothing appears; and `handleKey`
    /// swallows every key while one is pending, so the keyboard goes dead with
    /// no sign of why. That is how stepping through tunes onto a file the
    /// player could not read left ⌘↑ and ⌘↓ doing nothing, and the message
    /// waiting to spring out once the sheet was closed. Behind a sheet the
    /// panel footer is the one thing still in view, so it goes there instead.
    private func report(_ message: String) {
        if sheet == nil { alertMessage = message } else { statusMessage = message }
    }

    // MARK: - Character set chord

    /// True while Control+Shift is being held, so the chord fires once per press.
    private var charsetChordHeld = false

    /// Control+Shift flips between the upper and lower case halves of the
    /// character ROM, the way Commodore+Shift does on a real machine. It is a
    /// modifier-only chord, so it arrives as a flagsChanged event rather than
    /// a key press.
    ///
    /// It works with a sheet open too. The character set is a display choice
    /// rather than something a sheet owns, and the file viewer — where a PETSCII
    /// listing is the whole point — is exactly where you want to reach for it.
    func handleFlags(_ event: NSEvent) {
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
        // A sheet disables the menu bar, so ⌘Q never reaches the Quit item
        // while one is up and the app cannot be got out of without dismissing
        // it first. Terminate here instead, which still saves state on the way
        // out. Only the plain chord: ⇧⌘Q is the system's log out.
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "q" {
            NSApp.terminate(nil)
            return true
        }
        // The alert is not a sheet, so it leaves the menu bar alone and never
        // reaches the sheet guard below: a function key would set `sheet` and
        // have SwiftUI hold that sheet until the alert closed, and ⌘D would fall
        // through to the menu and move a panel nobody can see. Swallow the lot.
        if alertMessage != nil { return true }
        if case .player = sheet { return handlePlayerKey(event) }
        if case .module = sheet { return handleModuleKey(event) }
        if case .sample = sheet { return handleSampleKey(event) }
        guard sheet == nil else { return false }
        let shift = event.modifierFlags.contains(.shift)
        // ⌘R renames, and it is the one Command chord the browser answers
        // itself. The test is on the whole set of modifiers rather than on
        // Command alone: ⌥⌘R reveals in Finder and ⇧⌘R repairs the disk, and a
        // looser test swallows both here so the menu never sees the key.
        let command = event.modifierFlags
            .intersection([.command, .option, .control, .shift]) == .command
        if event.modifierFlags.contains(.command),
           !(command && event.charactersIgnoringModifiers?.lowercased() == "r") { return false }

        switch Int(event.keyCode) {
        case 126: activePanel.moveCursor(by: shift ? -10 : -1)          // up
        case 125: activePanel.moveCursor(by: shift ? 10 : 1)            // down
        case 116: activePanel.moveCursor(by: -20)                        // page up
        case 121: activePanel.moveCursor(by: 20)                         // page down
        case 115: activePanel.moveCursor(to: 0)                          // home
        case 119: activePanel.moveCursor(to: Int.max)                    // end
        case 48:  activeSide = activeSide == .left ? .right : .left      // tab
        case 49:  activePanel.toggleMark()                               // space
        case 36, 76:                                                     // return / enter
            if shift { beginPlay(manual: true) } else { activateItem() }
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

    // MARK: - Playing

    /// Command with the arrows drives the player: up and down step through the
    /// files, left and right through the songs inside one.
    ///
    /// Plain arrows cannot be used. The sheet's address fields hold the
    /// keyboard, so the field editor takes them first and the player never sees
    /// them. Requiring Command also makes this deliberate rather than something
    /// that fires while typing an address.
    ///
    /// Consuming the event here keeps it from reaching the menu, where Command
    /// with up or down rearranges entries in the directory behind the sheet.
    private func handlePlayerKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch Int(event.keyCode) {
        case 126: playNeighbour(-1)          // up
        case 125: playNeighbour(1)           // down
        case 123: adjustSelector(-1)         // left
        case 124: adjustSelector(1)          // right
        default: return false
        }
        return true
    }

    /// Return enters a folder, a volume or an image, and plays a tune.
    ///
    /// Only a tune: it used to open the player for anything at all, so a text
    /// file produced a sheet asking for two hex addresses that were never going
    /// to exist. Handing a file to the system is `⌘O`, and the player can still
    /// be forced onto a file the browser cannot read as one with ⇧Return.
    func activateItem() {
        guard let item = activePanel.currentItem else { return }
        if item.kind.isNavigable { activePanel.open() } else { beginPlay(manual: false, requireTune: true) }
    }

    /// `manual` skips detection, for a raw binary or when a guess is wrong.
    /// `requireTune` backs out instead of opening the player when nothing was
    /// detected, which is what Return wants and ⇧Return does not.
    func beginPlay(manual: Bool, requireTune: Bool = false) {
        guard let item = activePanel.currentItem, item.isSelectable, item.kind != .folder else { return }
        do {
            let payload = try read(item, from: activePanel)
            let bytes = [UInt8](payload.data)
            guard bytes.count > 2 else {
                if requireTune { statusMessage = Self.notATuneHint; return }
                report("That file is too short to be a tune.")
                return
            }
            let detected = manual ? nil : SIDTuneLoader.detect(name: item.title, data: bytes)
            // A tracker module is the other thing Return plays, and the only
            // way to know one is to look inside it — Amiga modules are named
            // mod.something, or nothing at all.
            if !manual, detected == nil, let module = ModuleLoader.detect(bytes) {
                beginModulePlay(module, named: item.title)
                return
            }
            // And an Amiga picture is the third. It is not a tune at all, so
            // Return opens the viewer on it rather than a player — the same
            // key, on the thing the file actually is.
            if !manual, detected == nil, let form = IFFLoader.detect(bytes) {
                if form.isPicture {
                    sheet = .viewer(ViewerContent(title: item.title, data: payload.data,
                                                  isPRG: false, startMode: .image))
                    return
                }
                if case .eightSVX = form { beginSamplePlay(bytes, named: item.title); return }
            }
            // Say what to press instead, since Return otherwise looks as though
            // it did nothing at all.
            if requireTune, detected == nil { statusMessage = Self.notATuneHint; return }
            playerRequest = SIDRequest(
                name: item.title,
                data: bytes,
                detected: detected,
                destination: exportDirectory)
            sheet = .player
        } catch { fail(error) }
    }

    private static let notATuneHint = "Not a recognised tune - ⇧⏎ for the player, ⌘O to open it"

    /// Open the tracker sheet on a module the browser has identified.
    ///
    /// Identifying one and playing it are different questions: the formats are
    /// recognised from their own bytes, and some of those — the Amiga chiptune
    /// players among them — have no engine here yet. Saying so in the status
    /// line is better than a sheet that cannot start, and matches what Return
    /// does when a file is not a tune at all.
    private func beginModulePlay(_ module: Module, named name: String) {
        // The request is made first so the engine can be told which sheet the
        // module belongs to. That is what lets the sheet being taken down tell
        // itself apart from the one arriving when files are stepped through.
        let request = ModuleRequest(name: name, module: module, destination: exportDirectory)
        guard modulePlayer.load(module, owner: request.id) else {
            statusMessage = "\(module.format.name) module - no player for this format yet"
            return
        }
        moduleRequest = request
        sheet = .module
    }

    /// Open the sample sheet on an 8SVX. Same shape as the module above: the
    /// request is made first so the player knows which sheet owns the sound.
    private func beginSamplePlay(_ bytes: [UInt8], named name: String) {
        do {
            let sound = try EightSVXDecoder.decode(bytes)
            let request = SampleRequest(name: name, sound: sound)
            samplePlayer.load(sound, owner: request.id)
            sampleRequest = request
            sheet = .sample
        } catch {
            // A sample this cannot unpack is a status line, not an alert: it is
            // the same "Return found nothing to do here" as a file that is not
            // a tune, and it says which part it could not read.
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Handing a file to the system

    /// What ⌘O acts on: the row the menu was opened on, or the cursor.
    private func target(_ item: PanelItem?) -> PanelItem? {
        let chosen = item ?? activePanel.currentItem
        return chosen?.isSelectable == true ? chosen : nil
    }

    /// Open it the way a double click in Finder would.
    ///
    /// Never navigates, whatever the row is. Walking into a folder or an image
    /// is Return's job, and an image handed to the system is meant to reach the
    /// emulator that opens `.d64` files rather than this listing.
    func openWithSystem(_ item: PanelItem? = nil) {
        guard let item = target(item) else { return }
        do {
            if let url = try hostURL(for: item) { HostOpener.open(url) }
        } catch { fail(error) }
    }

    /// The same, with an application picked from the menu.
    func openWithSystem(_ item: PanelItem? = nil, using application: URL) {
        guard let item = target(item) else { return }
        do {
            if let url = try hostURL(for: item) { HostOpener.open(url, with: application) }
        } catch { fail(error) }
    }

    /// Show it in Finder. An entry inside an image has no file of its own, so
    /// what is revealed is the image holding it — the thing that does exist.
    func revealInFinder(_ item: PanelItem? = nil) {
        let chosen = item ?? activePanel.currentItem
        if let url = chosen?.url, chosen?.kind.isInsideImage != true {
            HostOpener.reveal(url)
        } else if let container = activePanel.location.url {
            HostOpener.reveal(container)
        }
    }

    /// A path the system can open. Rows on the file system have one already;
    /// an entry inside an image is written out to a temporary copy first.
    private func hostURL(for item: PanelItem) throws -> URL? {
        guard item.kind.isInsideImage else { return item.url }
        let payload = try read(item, from: activePanel)
        let folder = HostHandoff.temporaryFolder(for: activePanel.location.url)
        let url = try HostHandoff.write(payload.data, named: payload.hostName, in: folder)
        statusMessage = "Opened a copy of \(item.title) - edits do not go back into the image"
        return url
    }

    /// Applications offered for a row. For an entry inside an image they come
    /// from the name it would be given on the file system, so that building a
    /// menu never writes a copy out.
    func applications(for item: PanelItem) -> [URL] {
        if item.kind.isInsideImage {
            guard let entry = item.cbm else { return [] }
            return HostOpener.applications(forExtension: (entry.hostFileName as NSString).pathExtension)
        }
        guard let url = item.url else { return [] }
        return HostOpener.applications(for: url)
    }

    /// The same for the tracker sheet: up and down step through the files,
    /// left and right through the songs inside the module.
    ///
    /// Stepping goes through `playNeighbour` like the SID sheet's, so walking a
    /// directory of mixed files moves between the two players by itself — the
    /// next file decides which sheet it opens.
    private func handleModuleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch Int(event.keyCode) {
        case 126: playNeighbour(-1)                     // up
        case 125: playNeighbour(1)                      // down
        case 123: adjustSubsong(-1)                     // left
        case 124: adjustSubsong(1)                      // right
        default: return false
        }
        return true
    }

    /// The sample sheet has no songs inside it to step through, so only up and
    /// down do anything — the same walk through the files the other two sheets
    /// make, which is what lets a directory of mixed files be gone through
    /// without going back to the listing between each one.
    private func handleSampleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return false }
        switch Int(event.keyCode) {
        case 126: playNeighbour(-1)                     // up
        case 125: playNeighbour(1)                      // down
        default: return false
        }
        return true
    }

    /// Step to the previous or next song inside the module, which restarts it.
    private func adjustSubsong(_ delta: Int) {
        guard modulePlayer.subsongs > 1 else { return }
        let next = modulePlayer.currentSubsong + delta
        guard next >= 0, next < modulePlayer.subsongs else { return }
        modulePlayer.selectSubsong(next)
    }

    /// Step to the neighbouring playable file and play it, so a disk of tunes
    /// can be walked through without leaving the player.
    func playNeighbour(_ delta: Int) {
        let items = activePanel.items
        var index = activePanel.cursor
        while true {
            index += delta
            // Either end of the list. Silence here reads as the keys having
            // stopped working, so it says which end it is on instead.
            guard items.indices.contains(index) else {
                statusMessage = delta < 0 ? "Nothing above this to play"
                                          : "Nothing below this to play"
                return
            }
            if isPlayable(items[index]) { break }
        }
        activePanel.moveCursor(to: index)
        // A step that works clears whatever the last one said. Set before the
        // play, so anything that one has to report survives.
        statusMessage = ""
        beginPlay(manual: false)
    }

    /// A DEL entry is a rule drawn in a directory listing, not a file, so
    /// stepping through tunes has to pass over it. So is anything too short to
    /// hold a tune: two bytes are a load address and nothing else, and the
    /// player refuses them, so stepping goes over those rather than landing on
    /// a file it can only complain about.
    private func isPlayable(_ item: PanelItem) -> Bool {
        switch item.kind {
        case .file: return item.byteSize > 2
        case .imageFile:
            guard let entry = item.cbm, entry.encoding == .petscii else { return false }
            return entry.type != .del && item.byteSize > 2
        default: return false
        }
    }

    /// Nudge the byte written to A, X and Y, which re-runs init on the new song.
    func adjustSelector(_ delta: Int) {
        let next = Int(player.selector) + delta
        guard (0...255).contains(next) else { return }
        player.selector = UInt8(next)
    }

    /// Where an exported video lands: the folder on show, or the folder holding
    /// the image when the panel is inside one.
    var exportDirectory: URL? {
        switch activePanel.location {
        case .volumes: return nil
        case .directory(let url): return url
        case .image(let url, _): return url.deletingLastPathComponent()
        }
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

    private func read(_ item: PanelItem, from panel: PanelModel?,
                      addingExtension: Bool = true) throws -> Payload {
        switch item.kind {
        case .imageFile:
            guard let panel, let image = panel.image, let entry = item.cbm
            else { throw DiskImageError.fileNotFound }
            let data = try image.read(entry, at: panel.location.imagePath)
            return Payload(data: data,
                           hostName: entry.hostFileName(addingExtension: addingExtension),
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

    /// What to call a file being written into an image. A Commodore disk keeps
    /// the type in the extension, so the name loses it on the way in; an Amiga
    /// volume takes the name as it stands.
    private func imageName(for payload: Payload, renamedTo renameTo: String?,
                           in image: DiskImage) -> [UInt8] {
        if image.listingStyle == .petscii {
            return renameTo.map { image.nameBytes(for: ($0 as NSString).deletingPathExtension) }
                ?? payload.cbmName
        }
        return image.nameBytes(for: renameTo ?? payload.hostName)
    }

    // MARK: - Copy / move

    func beginTransfer(isMove: Bool) {
        let items = activePanel.actionItems
        guard !items.isEmpty else { return }
        let destination = inactivePanel.location
        if case .volumes = destination {
            report("Choose a folder or an image on the other side first.")
            return
        }
        // The extension question only arises coming out of a Commodore image
        // onto the Mac. Everywhere else the checkbox stays off the sheet.
        var canAddExtension = false
        if case .directory = destination {
            canAddExtension = items.contains { $0.kind == .imageFile && $0.cbm?.encoding == .petscii }
        }
        // Where the checkbox is not offered the answer stays yes, so a name
        // crossing from a Commodore image into an Amiga one keeps its type.
        let addsExtension = canAddExtension ? settings.addHostExtension : true

        var withExtension = items.count == 1 ? items[0].title : ""
        var withoutExtension = withExtension
        if items.count == 1, case .directory = destination, items[0].kind == .imageFile,
           let entry = items[0].cbm {
            withExtension = entry.hostFileName(addingExtension: true)
            withoutExtension = entry.hostFileName(addingExtension: false)
        }
        sheet = .transfer(TransferPlan(isMove: isMove, items: items, destination: destination,
                                       destinationLabel: inactivePanel.headerTitle,
                                       targetName: addsExtension ? withExtension : withoutExtension,
                                       addsHostExtension: addsExtension,
                                       canAddHostExtension: canAddExtension,
                                       nameWithExtension: withExtension,
                                       nameWithoutExtension: withoutExtension,
                                       sourceSide: activeSide,
                                       targetSide: inactiveSide))
    }

    func perform(_ plan: TransferPlan) {
        if plan.canAddHostExtension { settings.addHostExtension = plan.addsHostExtension }
        let source = plan.sourceSide.map(panel(_:))
        let target = panel(plan.targetSide)
        let renameTo = plan.renamesSingleItem && plan.items.count == 1 ? plan.targetName : nil
        var copied = 0, skipped = 0
        var firstError: Error?

        for item in plan.items {
            do {
                // File system to file system, which is both sides of a drag
                // between two Mac folders. The file system does the work: a
                // folder keeps everything inside it, a file keeps its dates and
                // its permissions, and nothing is read into memory on the way.
                if !item.kind.isInsideImage, let src = item.url,
                   case .directory(let destURL) = plan.destination {
                    let dst = destURL.appendingPathComponent(renameTo ?? item.title)
                    if dst.standardizedFileURL == src.standardizedFileURL { skipped += 1; continue }
                    if FileManager.default.fileExists(atPath: dst.path) {
                        if plan.overwrite { try FileManager.default.removeItem(at: dst) }
                        else { skipped += 1; continue }
                    }
                    if plan.isMove { try FileManager.default.moveItem(at: src, to: dst) }
                    else { try FileManager.default.copyItem(at: src, to: dst) }
                    copied += 1
                    continue
                }
                if item.kind == .folder { throw TransferError.folderIntoImage }

                let payload = try read(item, from: source,
                                       addingExtension: plan.addsHostExtension)
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
                    // The path comes from the plan rather than from the panel:
                    // a drop can land on a directory row, one level deeper than
                    // the listing the panel is showing.
                    let path = plan.destination.imagePath
                    let name = imageName(for: payload, renamedTo: renameTo, in: image)
                    if let existing = try image.entries(at: path)
                        .first(where: { $0.name == PETSCII.trimPadding(name) }) {
                        if plan.overwrite { try image.delete(existing, at: path) }
                        else { skipped += 1; continue }
                    }
                    try image.write(name: name, type: payload.type, data: payload.data, at: path)
                    copied += 1
                }

                if plan.isMove { try delete(item, in: source, toTrash: false) }
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        finishOperation(verb: plan.isMove ? "Moved" : "Copied", count: copied, skipped: skipped, error: firstError)
    }

    // MARK: - Drag and drop

    /// Start dragging out of `panel`. A row that is marked takes the whole
    /// marked set with it, the way the function keys act on one; an unmarked
    /// row goes on its own and the cursor follows it.
    func beginDrag(from panel: PanelModel, row: PanelItem) {
        guard dragCoordinator.session == nil, row.isSelectable, row.kind != .volume else { return }
        let items: [PanelItem]
        if panel.marked.contains(row.id) {
            items = panel.items.filter { panel.marked.contains($0.id) && $0.isSelectable }
        } else {
            items = [row]
            panel.moveCursor(to: row.id)
        }
        // A directory inside an image is a tree this app cannot yet unpack, so
        // it is left out rather than dragged into a failure.
        let draggable = items.filter { $0.kind != .imageFolder && $0.kind != .volume }
        guard !draggable.isEmpty else { return }
        activeSide = panel.side
        dragCoordinator.begin(items: draggable, from: panel)
    }

    /// Carry out a drop. `sourceSide` is nil when the files were dragged in
    /// from another application, in which case `items` stand for paths on the
    /// file system and there is no panel behind them.
    func performDrop(items: [PanelItem], from sourceSide: PanelSide?, to targetSide: PanelSide,
                     destination: PanelLocation, isMove: Bool) {
        // This runs a moment after the mouse came up, so it is the last word on
        // whether anything is still hovering: nothing is.
        left.dropHighlight = nil
        right.dropHighlight = nil
        guard !items.isEmpty else { return }
        var plan = TransferPlan(isMove: isMove, items: items, destination: destination,
                                destinationLabel: panel(targetSide).headerTitle, targetName: "")
        plan.sourceSide = sourceSide
        plan.targetSide = targetSide
        // A drag asks no questions: the files keep their names, and one that is
        // already there is left alone rather than written over.
        plan.renamesSingleItem = false
        plan.addsHostExtension = settings.addHostExtension
        perform(plan)
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

    private func delete(_ item: PanelItem, in panel: PanelModel?, toTrash: Bool) throws {
        switch item.kind {
        case .imageFile, .imageFolder:
            guard let panel, let image = panel.image, let entry = item.cbm
            else { throw DiskImageError.fileNotFound }
            try image.delete(entry, at: panel.location.imagePath)
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

    func performRename(_ item: PanelItem, edit: DirectoryEntryEdit) {
        let panel = activePanel
        do {
            switch edit {
            // The advanced half writes the printed fields as they are, and
            // only a Commodore directory has fields to write.
            case .raw(let name, let blocks):
                guard let image = cbmImage, let entry = item.cbm else { throw DiskImageError.fileNotFound }
                try image.setEntryFields(entry, name: name, blocks: blocks)
            case .name(let newName):
                switch item.kind {
                case .imageFile, .imageFolder:
                    guard let image = panel.image, let entry = item.cbm else { throw DiskImageError.fileNotFound }
                    try image.rename(entry, at: panel.location.imagePath,
                                     to: entry.encoding == .petscii ? PETSCII.cbmName(fromASCII: newName)
                                                                    : entry.encoding.bytes(newName))
                default:
                    guard let url = item.url else { throw DiskImageError.fileNotFound }
                    let dst = url.deletingLastPathComponent().appendingPathComponent(newName)
                    try FileManager.default.moveItem(at: url, to: dst)
                }
            }
            finishOperation(verb: "Renamed", count: 1, skipped: 0, error: nil)
        } catch {
            fail(error)
        }
    }

    // MARK: - Advanced directory editing

    /// The image in the active panel when it is a Commodore one. The byte
    /// level editors take a CBM directory apart field by field, and no other
    /// format here has those fields.
    var cbmImage: CBMDiskImage? { activePanel.image as? CBMDiskImage }

    /// What the Advanced half of the header dialog opens on, or nil when there
    /// is nothing of the sort to edit and the dialog stays as it was.
    var headerDraft: DiskHeaderDraft? {
        guard let image = cbmImage, image.canWrite,
              image.headerFieldBytes.count == CBMDiskImage.headerFieldLength else { return nil }
        return DiskHeaderDraft(header: image.headerFieldBytes,
                               blocksFree: image.blocksFree,
                               maximumBlocksFree: image.maximumBlocksFree)
    }

    /// The same for a row being renamed.
    func entryDraft(for item: PanelItem) -> DirectoryEntryDraft? {
        guard let image = cbmImage, image.canWrite, item.kind.isInsideImage,
              let entry = item.cbm else { return nil }
        return DirectoryEntryDraft(name: image.rawName(of: entry), blocks: entry.blocks)
    }

    /// And for a DEL entry that does not exist yet, which starts from the
    /// dashes the plain dialog offers.
    func newEntryDraft(named text: String) -> DirectoryEntryDraft? {
        guard let image = cbmImage, image.canWrite else { return nil }
        return DirectoryEntryDraft(name: PETSCII.padded16(PETSCII.cbmName(fromASCII: text)), blocks: 0)
    }

    // MARK: - New folder / image / header

    func beginMakeFolder() {
        switch activePanel.location {
        case .directory:
            sheet = .makeFolder
        case .image where activePanel.image?.supportsDirectories == true:
            sheet = .makeFolder
        default:
            report("This image has no directories, so there is nowhere to put a folder.")
        }
    }

    func performMakeFolder(named name: String) {
        do {
            switch activePanel.location {
            case .directory(let url):
                try FileManager.default.createDirectory(at: url.appendingPathComponent(name),
                                                        withIntermediateDirectories: false)
            case .image(_, let path):
                guard let image = activePanel.image else { return }
                try image.makeDirectory(name: image.nameBytes(for: name), at: path)
            case .volumes:
                return
            }
            finishOperation(verb: "Created", count: 1, skipped: 0, error: nil)
        } catch { fail(error) }
    }

    func beginNewImage() {
        guard case .directory = activePanel.location else {
            report("Open a folder in the active panel to create an image in it.")
            return
        }
        sheet = .newImage
    }

    func performNewImage(kind: NewImageFormat, option: String, fileName: String,
                         diskName: String, diskID: String) {
        guard case .directory(let dir) = activePanel.location else { return }
        var name = fileName
        if !name.lowercased().hasSuffix(".\(kind.fileExtension)") { name += ".\(kind.fileExtension)" }
        let url = dir.appendingPathComponent(name)
        do {
            if let cbm = kind.cbm {
                try CBMDiskImage.createBlank(cbm, tracks: Int(option),
                                             name: PETSCII.cbmName(fromASCII: diskName),
                                             id: PETSCII.petscii(fromASCII: diskID.isEmpty ? "01" : diskID),
                                             at: url)
            } else {
                try ADFImage.createBlank(variant: NewImageFormat.amigaVariant(option),
                                         name: NameEncoding.latin1.bytes(diskName),
                                         at: url)
            }
            finishOperation(verb: "Created", count: 1, skipped: 0, error: nil)
        } catch { fail(error) }
    }

    func beginEditHeader() {
        guard activePanel.image != nil else {
            report("Open a disk image to edit its header.")
            return
        }
        sheet = .diskHeader
    }

    /// Check the disk over and show what a repair would do. Nothing is
    /// written until the sheet is confirmed.
    func beginRepairDisk() {
        guard let image = repairableImage else {
            report(activePanel.image == nil
                   ? "Open a Commodore disk image to repair it."
                   : "Only a writable Commodore image has a BAM to repair.")
            return
        }
        repairPlan = image.analyseForRepair()
        sheet = .repairDisk
    }

    /// Scratch the files a repair cannot see past, then look again.
    ///
    /// The sheet stays up on the new plan rather than repairing straight
    /// through. Deleting is only half the job, and the repair it unblocks is
    /// the half worth reading before it is written.
    func deleteRepairBlockers() {
        guard let image = repairableImage else { return }
        do {
            let scratched = try image.deleteBlockingFiles()
            activePanel.refreshImage()
            repairPlan = image.analyseForRepair()
            statusMessage = scratched.isEmpty
                ? "Nothing to delete"
                : "Deleted \(scratched.count) damaged file\(scratched.count == 1 ? "" : "s"): "
                    + scratched.joined(separator: ", ")
        } catch { fail(error) }
    }

    func performRepair() {
        guard let image = repairableImage else { return }
        do {
            let done = try image.applyRepair()
            activePanel.refreshImage()
            var parts: [String] = []
            if !done.splatToScratch.isEmpty { parts.append("\(done.splatToScratch.count) scratched") }
            if !done.wrongCounts.isEmpty { parts.append("\(done.wrongCounts.count) block counts") }
            if done.toFree > 0 { parts.append("\(done.toFree) freed") }
            if done.toAllocate > 0 { parts.append("\(done.toAllocate) allocated") }
            if done.badFreeCounts > 0 { parts.append("\(done.badFreeCounts) free counts") }
            statusMessage = parts.isEmpty
                ? "Nothing needed repairing"
                : "Repaired: " + parts.joined(separator: ", ") + " - \(done.blocksFreeAfter) blocks free"
        } catch { fail(error) }
    }

    func performEditHeader(_ edit: DiskHeaderEdit) {
        guard let image = activePanel.image else { return }
        do {
            switch edit {
            case .simple(let name, let id):
                try image.setDiskHeader(name: image.nameBytes(for: name),
                                        id: PETSCII.petscii(fromASCII: id))
            case .raw(let header, let free):
                guard let cbm = image as? CBMDiskImage else { return }
                try cbm.setHeaderFieldBytes(header)
                if let free { try cbm.setBlocksFree(free) }
            }
            activePanel.refreshImage()
            statusMessage = "Disk header updated"
        } catch { fail(error) }
    }

    // MARK: - Directory decoration

    func moveEntry(by delta: Int) {
        guard let image = activePanel.image, image.supportsEntryReordering,
              let entry = activePanel.currentItem?.cbm else { return }
        do {
            try image.moveEntry(entry, by: delta)
            let newCursor = activePanel.cursor + delta
            activePanel.refreshImage()
            activePanel.moveCursor(to: newCursor)
        } catch { fail(error) }
    }

    func addDecorativeEntry(_ edit: DirectoryEntryEdit) {
        guard let image = activePanel.image else { return }
        do {
            switch edit {
            case .name(let name):
                try image.addDecorativeEntry(name: PETSCII.cbmName(fromASCII: name),
                                             after: activePanel.currentItem?.cbm)
            case .raw(let name, let blocks):
                guard let cbm = cbmImage else { return }
                try cbm.addDecorativeEntry(name: name, blocks: blocks,
                                           after: activePanel.currentItem?.cbm)
            }
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

    // MARK: - Unpacking an archive

    /// True for a row, or for the panel itself, that is a DMS archive.
    func isArchive(_ item: PanelItem?) -> Bool {
        if let url = item?.url, item?.kind == .diskImage {
            return url.pathExtension.lowercased() == "dms"
        }
        return false
    }

    var isInsideArchive: Bool {
        activePanel.location.url?.pathExtension.lowercased() == "dms"
    }

    /// Write the disk an archive holds out as an ADF, into the folder on the
    /// other side — the same place a copy would go.
    func unpackArchive(_ item: PanelItem? = nil) {
        let source: URL?
        if let item, item.kind == .diskImage { source = item.url }
        else if isInsideArchive { source = activePanel.location.url }
        else if let current = activePanel.currentItem, current.kind == .diskImage { source = current.url }
        else { source = nil }

        guard let source, source.pathExtension.lowercased() == "dms" else {
            report("Choose a DMS archive to unpack.")
            return
        }
        guard case .directory(let destination) = inactivePanel.location else {
            report("Open a folder on the other side to unpack the archive into.")
            return
        }
        let target = destination.appendingPathComponent(
            source.deletingPathExtension().lastPathComponent + ".adf")
        do {
            let image = try ADFImage.unpackedImage(at: source)
            try image.write(to: target, options: .withoutOverwriting)
            inactivePanel.refresh()
            statusMessage = "Unpacked \(target.lastPathComponent)"
        } catch CocoaError.fileWriteFileExists {
            report("\"\(target.lastPathComponent)\" already exists in that folder.")
        } catch { fail(error) }
    }

    // MARK: - Viewer

    func beginView(bitmap: Bool = false) {
        guard let item = activePanel.currentItem, item.isSelectable, item.kind != .folder else { return }
        do {
            let payload = try read(item, from: activePanel)
            let isPRG = item.kind.isInsideImage ? item.cbm?.type == .prg && item.cbm?.encoding == .petscii
                                                : item.url?.pathExtension.lowercased() == "prg"
            // ⇧F3 asked for the bitmap and gets it. Otherwise a file that says
            // it is a picture opens on the picture: a hex dump of an ILBM is
            // not what anyone pressed F3 for.
            var start: ViewerMode = bitmap ? .bitmap : .hex
            if !bitmap, IFFLoader.detect([UInt8](payload.data))?.isPicture == true { start = .image }
            sheet = .viewer(ViewerContent(title: item.title, data: payload.data,
                                          isPRG: isPRG, startMode: start))
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
