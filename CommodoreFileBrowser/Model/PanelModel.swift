import SwiftUI
import UniformTypeIdentifiers

enum PanelSide: String, Codable { case left, right }

/// Where a drop hovering over a panel would land, so it can be drawn before
/// the mouse is let go. `panel` is the folder the listing is showing; `row` is
/// a folder inside it that the pointer is over.
enum DropHighlight: Equatable {
    case panel
    case row(Int)
}

/// What a panel is currently showing.
enum PanelLocation: Codable, Equatable, Hashable {
    case volumes
    case directory(URL)
    /// An image, and the directory inside it: empty at its root, one component
    /// per level on a format that has them.
    case image(URL, path: [String])

    /// The root of an image, which is every format but the Amiga ones.
    static func image(_ url: URL) -> PanelLocation { .image(url, path: []) }

    var url: URL? {
        switch self {
        case .volumes: return nil
        case .directory(let u): return u
        case .image(let u, _): return u
        }
    }

    var imagePath: [String] {
        if case .image(_, let path) = self { return path }
        return []
    }

    var isImage: Bool { if case .image = self { return true }; return false }
}

struct PanelItem: Identifiable {
    enum Kind {
        case parent, volume, folder, diskImage, file, imageFile, imageFolder
        var isNavigable: Bool {
            self == .parent || self == .volume || self == .folder
                || self == .diskImage || self == .imageFolder
        }
        /// A row that lives inside an image rather than on the file system.
        var isInsideImage: Bool { self == .imageFile || self == .imageFolder }
    }

    let id: Int
    var kind: Kind
    var title: String
    var detail: String
    var url: URL?
    var cbm: ImageEntry?
    /// Pre-composed PETSCII row, used when the panel shows the inside of an
    /// image the machine itself would have listed from the character ROM.
    /// Nil elsewhere, which is what puts the row in the system font.
    var petsciiLine: [UInt8]?
    var byteSize: Int64 = 0
    /// Permission bits, where the format keeps them.
    var flags: String = ""
    var modified: Date?
    var isSelectable: Bool { kind != .parent }
}

final class PanelModel: ObservableObject {

    let side: PanelSide

    @Published private(set) var location: PanelLocation = .volumes
    @Published private(set) var items: [PanelItem] = []
    @Published private(set) var image: DiskImage?
    @Published var cursor: Int = 0
    @Published var marked: Set<Int> = []
    @Published var loadError: String?
    /// Where a drag hovering over this panel would land, drawn while it does.
    @Published var dropHighlight: DropHighlight?

    /// Reveal hidden files. Mirrored from the theme store.
    var showHidden = false

    /// Where the cursor sat in each folder we have visited, by item name, so
    /// walking back with the arrow keys lands where you left off. Session only.
    private var cursorMemory: [String: String] = [:]
    /// The folder we were last in on each volume, keyed by the volume's path,
    /// so picking a volume again returns there instead of to its root.
    private var lastFolderByVolume: [String: URL] = [:]

    init(side: PanelSide) {
        self.side = side
    }

    // MARK: - Derived text

    var headerTitle: String {
        switch location {
        case .volumes: return "Volumes"
        case .directory(let url): return url.path
        case .image(let url, let path):
            return ([url.lastPathComponent] + path).joined(separator: "/")
        }
    }

    var isImagePanel: Bool { if case .image = location { return true }; return false }

    var footerText: String {
        if let image {
            let files = items.filter { $0.kind.isInsideImage }.count
            let free = image.freeDescription
            return marked.isEmpty ? "\(files) files · \(free)"
                                  : "\(marked.count) marked · \(files) files · \(free)"
        }
        let files = items.filter { $0.kind != .parent }.count
        let bytes = marked.compactMap { markedItem($0)?.byteSize }.reduce(0, +)
        if marked.isEmpty { return "\(files) items" }
        return "\(marked.count) marked · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private func markedItem(_ id: Int) -> PanelItem? { items.first { $0.id == id } }

    var currentItem: PanelItem? {
        items.indices.contains(cursor) ? items[cursor] : nil
    }

    /// The marked items, or the item under the cursor when nothing is marked.
    var actionItems: [PanelItem] {
        let m = items.filter { marked.contains($0.id) && $0.isSelectable }
        if !m.isEmpty { return m }
        if let c = currentItem, c.isSelectable { return [c] }
        return []
    }

    // MARK: - Navigation

    /// True while the open image holds edits that are not on disk yet.
    var hasUnsavedChanges: Bool { image?.hasUnsavedChanges ?? false }

    /// Commit the open image to disk. Edits live in memory until this runs.
    @discardableResult
    func saveImage() -> Error? {
        guard let image, image.hasUnsavedChanges else { return nil }
        do { try image.save(); return nil } catch { return error }
    }

    /// `keepChanges: false` throws away everything edited since the image was
    /// opened - the file on disk was never touched.
    func navigate(to newLocation: PanelLocation, focusOn name: String? = nil, keepChanges: Bool = true) {
        // Stepping between directories inside one image is not leaving it, so
        // it must not commit: the transaction runs until the panel is somewhere
        // else entirely.
        let staying = newLocation.isImage && location.isImage && newLocation.url == location.url
        if keepChanges && !staying { saveImage() }
        rememberCursor()
        location = newLocation
        rememberVolume()
        reload(focusOn: name, isNavigation: true)
    }

    /// A canonical key for a location. URLs for the same folder can differ by
    /// a trailing slash depending on where they came from, which would make a
    /// URL-keyed dictionary miss.
    private func memoryKey(_ location: PanelLocation) -> String {
        switch location {
        case .volumes: return "volumes"
        case .directory(let url): return "dir:" + url.standardizedFileURL.path
        case .image(let url, let path):
            return (["img:" + url.standardizedFileURL.path] + path).joined(separator: "/")
        }
    }

    /// Note where the cursor is before leaving, so coming back restores it.
    private func rememberCursor() {
        guard let item = currentItem else { return }
        cursorMemory[memoryKey(location)] = item.title
    }

    /// Track the deepest folder visited per volume.
    private func rememberVolume() {
        guard case .directory(let url) = location,
              let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
        else { return }
        lastFolderByVolume[volume.path] = url
        UserDefaults.standard.set(lastFolderByVolume.mapValues(\.path), forKey: volumeKey)
    }

    /// Jump to the list of mounted volumes, with the cursor on the one we are
    /// currently inside.
    func goToVolumes() {
        var focus: String?
        if let url = location.url {
            focus = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        }
        navigate(to: .volumes, focusOn: focus)
    }

    /// Enter whatever is under the cursor. The right arrow passes
    /// `allowParent: false`: it only ever goes deeper, so that landing on the
    /// `..` row does not turn it into a second left arrow. Return and a double
    /// click still walk out from there.
    func open(allowParent: Bool = true) {
        guard let item = currentItem else { return }
        switch item.kind {
        case .parent:
            guard allowParent else { return }
            goUp(keepChanges: true)
        case .volume:
            guard let url = item.url else { return }
            // Pick up where we left off on this volume, if it is still there.
            if let last = lastFolderByVolume[url.path],
               FileManager.default.fileExists(atPath: last.path) {
                navigate(to: .directory(last))
            } else {
                navigate(to: .directory(url))
            }
        case .folder:
            if let url = item.url { navigate(to: .directory(url)) }
        case .diskImage:
            if let url = item.url { navigate(to: .image(url)) }
        case .imageFolder:
            guard case .image(let url, let path) = location else { return }
            navigate(to: .image(url, path: path + [item.title]))
        case .file, .imageFile:
            break
        }
    }

    func goUp(keepChanges: Bool = true) {
        switch location {
        case .volumes:
            break
        case .directory(let url):
            let isVolumeRoot = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            let parent = url.deletingLastPathComponent()
            if isVolumeRoot || parent.path == url.path {
                navigate(to: .volumes, focusOn: url.lastPathComponent, keepChanges: keepChanges)
            } else {
                navigate(to: .directory(parent), focusOn: url.lastPathComponent, keepChanges: keepChanges)
            }
        case .image(let url, let path):
            // Discarding is about the image as a whole, so Esc walks out of it
            // however deep in it we are. Keeping changes climbs one level.
            if keepChanges, let leaf = path.last {
                navigate(to: .image(url, path: path.dropLast()), focusOn: leaf)
            } else {
                navigate(to: .directory(url.deletingLastPathComponent()),
                         focusOn: url.lastPathComponent, keepChanges: keepChanges)
            }
        }
    }

    // MARK: - Loading

    /// `isNavigation` marks a move to a different location, where the cursor
    /// should start on the first row (the parent entry) unless we remember a
    /// position for it. A plain reload instead keeps the current row.
    func reload(focusOn name: String? = nil, isNavigation: Bool = false) {
        let previousName = name
            ?? (isNavigation ? cursorMemory[memoryKey(location)] : currentItem?.title)
        marked.removeAll()
        loadError = nil

        switch location {
        case .volumes:
            image = nil
            items = loadVolumes()
        case .directory(let url):
            image = nil
            items = loadDirectory(url)
        case .image(let url, let path):
            loadImage(url, path: path)
        }

        if let previousName, let index = items.firstIndex(where: { $0.title == previousName }) {
            cursor = index
        } else if isNavigation {
            cursor = 0
        } else {
            cursor = min(cursor, max(0, items.count - 1))
        }
    }

    private func parentRow() -> PanelItem {
        PanelItem(id: 0, kind: .parent, title: "..", detail: "", url: nil)
    }

    private func loadVolumes() -> [PanelItem] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        var out: [PanelItem] = []
        for (i, url) in urls.enumerated() {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? url.lastPathComponent
            var detail = ""
            if let free = values?.volumeAvailableCapacity, let total = values?.volumeTotalCapacity, total > 0 {
                detail = "\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free"
            }
            out.append(PanelItem(id: i, kind: .volume, title: name, detail: detail, url: url))
        }
        return out
    }

    private func loadDirectory(_ url: URL) -> [PanelItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        var contents: [URL] = []
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles])
        } catch {
            loadError = error.localizedDescription
        }

        struct Row { let url: URL; let isDir: Bool; let size: Int64; let date: Date? }
        let rows: [Row] = contents.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Row(url: u, isDir: v?.isDirectory ?? false,
                       size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate)
        }
        .sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }

        var out = [parentRow()]
        for row in rows {
            let kind: PanelItem.Kind = row.isDir ? .folder : (DiskImageFactory.isImage(row.url) ? .diskImage : .file)
            let detail = Self.sizeText(bytes: row.size, isDirectory: row.isDir)
            out.append(PanelItem(id: out.count, kind: kind, title: row.url.lastPathComponent,
                                 detail: detail, url: row.url, byteSize: row.size,
                                 modified: row.date))
        }
        return out
    }

    private func loadImage(_ url: URL, path: [String]) {
        do {
            // Walking into a directory of the image we already have open must
            // reuse it. Opening the file again would read it back from disk and
            // take the pending edits with it.
            let img = try (image?.url == url ? image! : DiskImageFactory.open(url))
            image = img
            items = try Self.rows(for: img, path: path)
        } catch {
            image = nil
            loadError = error.localizedDescription
            items = [parentRow()]
        }
    }

    /// Rebuild after an operation. An image with pending edits is redrawn from
    /// memory; anything else is re-read from disk.
    func refresh() {
        if isImagePanel, image != nil { refreshImage() } else { reload() }
    }

    /// Rebuild the listing from the open image, keeping the cursor in place.
    func refreshImage() {
        guard let image else { return }
        let name = currentItem?.title
        do { items = try Self.rows(for: image, path: location.imagePath) }
        catch { loadError = error.localizedDescription }
        if let name, let index = items.firstIndex(where: { $0.title == name }) { cursor = index }
        cursor = min(cursor, max(0, items.count - 1))
        marked.removeAll()
    }

    static func rows(for image: DiskImage, path: [String]) throws -> [PanelItem] {
        let petscii = image.listingStyle == .petscii
        var out = [PanelItem(id: 0, kind: .parent, title: "..", detail: "", url: nil)]
        for entry in try image.entries(at: path) {
            let bytes = entry.byteSize ?? entry.blocks * image.usableBytesPerBlock
            out.append(PanelItem(id: out.count,
                                 kind: entry.isDirectory ? .imageFolder : .imageFile,
                                 title: entry.displayName,
                                 detail: petscii ? entry.type.name : sizeText(for: entry),
                                 url: nil, cbm: entry,
                                 petsciiLine: petscii ? listingLine(for: entry) : nil,
                                 byteSize: Int64(bytes),
                                 flags: entry.flags,
                                 modified: entry.modified))
        }
        return out
    }

    /// The size column, the same in every listing: an exact byte count, which
    /// is what a machine with a byte count in its directory prints, and `Dir`
    /// for anything that can be walked into.
    ///
    /// The Mac side used to round this off — `1 KB`, `Zero KB` — which reads
    /// well for a disk and badly for a file you are about to write into a
    /// 170K image, where the last hundred bytes are the ones that matter.
    static func sizeText(bytes: Int64?, isDirectory: Bool) -> String {
        if isDirectory { return "Dir" }
        guard let bytes else { return "" }
        return bytes.formatted(.number)
    }

    private static func sizeText(for entry: ImageEntry) -> String {
        if entry.isDirectory { return "Dir" }
        guard let bytes = entry.byteSize else { return "\(entry.blocks)" }
        return sizeText(bytes: Int64(bytes), isDirectory: false)
    }

    /// One directory row the way a 1541 prints it: blocks, "name", type.
    static func listingLine(for entry: ImageEntry) -> [UInt8] {
        var line = PETSCII.petscii(fromASCII: String(format: "%-4d ", entry.blocks))
        line += [0x22] + entry.name + [0x22]
        line += [UInt8](repeating: 0x20, count: max(0, 16 - entry.name.count))
        line += [0x20, entry.isSplat ? 0x2A : 0x20]
        line += PETSCII.petscii(fromASCII: entry.type.name.lowercased())
        line += [entry.isLocked ? 0x3C : 0x20]
        return line
    }

    /// The reverse-video header line of a directory listing.
    static func headerLine(for image: DiskImage) -> [UInt8] {
        var line = PETSCII.petscii(fromASCII: "0 ")
        line += [0x22] + PETSCII.padded16(PETSCII.trimPadding(image.diskName)).map { $0 == 0xA0 ? 0x20 : $0 } + [0x22]
        if let id = image.diskID { line += [0x20] + id }
        return line
    }

    // MARK: - Marking

    func toggleMark() {
        guard let item = currentItem, item.isSelectable else { return }
        if marked.contains(item.id) { marked.remove(item.id) } else { marked.insert(item.id) }
        moveCursor(by: 1)
    }

    func markAll() { marked = Set(items.filter(\.isSelectable).map(\.id)) }
    func unmarkAll() { marked.removeAll() }
    func invertMarks() {
        let all = Set(items.filter(\.isSelectable).map(\.id))
        marked = all.subtracting(marked)
    }

    // MARK: - Cursor

    func moveCursor(by delta: Int) {
        guard !items.isEmpty else { return }
        cursor = min(max(0, cursor + delta), items.count - 1)
    }

    func moveCursor(to index: Int) {
        guard !items.isEmpty else { return }
        cursor = min(max(0, index), items.count - 1)
    }

    // MARK: - Persistence

    private var defaultsKey: String { "panel.\(side.rawValue).location" }
    private var volumeKey: String { "panel.\(side.rawValue).volumeFolders" }

    func saveLocation() {
        if let data = try? JSONEncoder().encode(location) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func restoreLocation() {
        if let stored = UserDefaults.standard.dictionary(forKey: volumeKey) as? [String: String] {
            lastFolderByVolume = stored.mapValues { URL(fileURLWithPath: $0) }
        }
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(PanelLocation.self, from: data)
        else {
            location = .volumes
            reload(isNavigation: true)
            return
        }
        // Fall back gracefully if the folder or image has gone away.
        switch stored {
        case .volumes:
            location = .volumes
        case .directory(let url):
            location = FileManager.default.fileExists(atPath: url.path) ? stored : .volumes
        case .image(let url, _):
            location = FileManager.default.fileExists(atPath: url.path) ? stored : .volumes
        }
        reload(isNavigation: true)
    }
}
