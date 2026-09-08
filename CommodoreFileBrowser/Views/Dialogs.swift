import SwiftUI

// MARK: - Shared chrome

private struct DialogFrame<Content: View>: View {
    let title: String
    let palette: Palette
    let confirmTitle: String
    var confirmDisabled: Bool = false
    var destructive: Bool = false
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: destructive ? .destructive : nil, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(palette.color(.window))
    }
}

// MARK: - Copy / Move

struct TransferSheet: View {
    @State var plan: TransferPlan
    let palette: Palette
    let onCancel: () -> Void
    let onConfirm: (TransferPlan) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        DialogFrame(title: "\(plan.verb) \(plan.summary)",
                    palette: palette,
                    confirmTitle: plan.verb,
                    onCancel: onCancel,
                    onConfirm: { onConfirm(plan) }) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("To") {
                    Text(plan.destinationLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if plan.items.count == 1 {
                    LabeledContent("Name") {
                        TextField("", text: $plan.targetName)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit { onConfirm(plan) }
                    }
                } else {
                    Text(plan.items.prefix(6).map(\.title).joined(separator: ", ")
                         + (plan.items.count > 6 ? " …" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.color(.dim))
                        .lineLimit(3)
                }
                Toggle("Overwrite files that already exist", isOn: $plan.overwrite)
                    .font(.system(size: 11))
                if plan.canAddHostExtension {
                    Toggle(extensionLabel, isOn: $plan.addsHostExtension)
                        .font(.system(size: 11))
                        .onChange(of: plan.addsHostExtension) { _, adds in
                            // The field follows the checkbox: the name in it is
                            // the one that will be written, so leaving a stale
                            // spelling there would say the opposite.
                            plan.targetName = adds ? plan.nameWithExtension
                                                   : plan.nameWithoutExtension
                        }
                }
            }
        }
        .onAppear { focused = true }
    }

    /// Names the extension itself when there is one file and so one answer;
    /// stays general when a whole selection is going out at once.
    private var extensionLabel: String {
        let suffix = (plan.nameWithExtension as NSString).pathExtension
        guard plan.items.count == 1, !suffix.isEmpty else {
            return "Add the Commodore file type as an extension"
        }
        return "Add the Commodore file type as an extension (.\(suffix))"
    }
}

// MARK: - Delete

struct DeleteSheet: View {
    let items: [PanelItem]
    let toTrash: Bool
    let palette: Palette
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var summary: String {
        items.count == 1 ? "\"\(items[0].title)\"" : "\(items.count) items"
    }

    private var explanation: String {
        let insideImage = items.contains { $0.kind.isInsideImage }
        if insideImage { return "The files will be scratched from the disk image." }
        return toTrash ? "The items will be moved to the Trash."
                       : "The items will be deleted permanently."
    }

    var body: some View {
        DialogFrame(title: "Delete \(summary)?",
                    palette: palette,
                    confirmTitle: "Delete",
                    destructive: true,
                    onCancel: onCancel,
                    onConfirm: onConfirm) {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.color(.dim))
                if items.count > 1 {
                    Text(items.prefix(8).map(\.title).joined(separator: ", ")
                         + (items.count > 8 ? " …" : ""))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.color(.dim))
                        .lineLimit(3)
                }
            }
        }
    }
}

// MARK: - Discard image changes

struct DiscardChangesSheet: View {
    let imageName: String
    let palette: Palette
    let onCancel: () -> Void
    let onSave: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Discard the changes to “\(imageName)”?")
                .font(.system(size: 14, weight: .semibold))
            Text("The image was edited but nothing has been written to the file yet. Leaving with Esc throws those changes away.")
                .font(.system(size: 11))
                .foregroundStyle(palette.color(.dim))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Save and Leave", action: onSave)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Discard", role: .destructive, action: onDiscard)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(palette.color(.window))
    }
}

// MARK: - Single text field dialogs

struct TextPromptSheet: View {
    let title: String
    let label: String
    let confirmTitle: String
    @State var text: String
    let palette: Palette
    let onCancel: () -> Void
    let onConfirm: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        DialogFrame(title: title,
                    palette: palette,
                    confirmTitle: confirmTitle,
                    confirmDisabled: text.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: onCancel,
                    onConfirm: { onConfirm(text) }) {
            LabeledContent(label) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { onConfirm(text) } }
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - New image

struct NewImageSheet: View {
    let palette: Palette
    let onCancel: () -> Void
    let onConfirm: (NewImageFormat, String, String, String, String) -> Void

    @State private var kind: NewImageFormat = .d64
    @State private var option = NewImageFormat.d64.defaultOption
    @State private var fileName = "new"
    @State private var diskName = "new disk"
    @State private var diskID = "01"
    @FocusState private var focused: Bool

    var body: some View {
        DialogFrame(title: "New disk image",
                    palette: palette,
                    confirmTitle: "Create",
                    confirmDisabled: fileName.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: onCancel,
                    onConfirm: { onConfirm(kind, option, fileName, diskName, diskID) }) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Format", selection: $kind) {
                    ForEach(NewImageFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                // Only two formats have a second choice to make — track counts
                // on a D64, file systems on an ADF — and the others would be a
                // picker with one option in it. Six file systems are more than
                // a row of segments can hold, so those go in a menu.
                if !kind.options.isEmpty {
                    let picker = Picker(kind.optionLabel, selection: $option) {
                        ForEach(kind.options, id: \.self) { Text($0).tag($0) }
                    }
                    if kind.options.count > 3 { picker.pickerStyle(.menu) }
                    else { picker.pickerStyle(.segmented) }
                }
                Text(kind.subtitle(option: option))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.dim))
                LabeledContent("File name") {
                    TextField("new", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                }
                LabeledContent("Disk name") {
                    TextField("new disk", text: $diskName).textFieldStyle(.roundedBorder)
                }
                if kind.wantsDiskID {
                    LabeledContent("Disk ID") {
                        TextField("01", text: $diskID).textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                }
            }
        }
        .onAppear { focused = true }
        // Each format has its own second choice, so one made under a different
        // format cannot be carried over.
        .onChange(of: kind) { _, new in option = new.defaultOption }
    }
}

// MARK: - Disk header

struct DiskHeaderSheet: View {
    let palette: Palette
    @State var name: String
    @State var id: String
    /// An Amiga volume has a name and nowhere to put an ID.
    var wantsID: Bool = true
    let onCancel: () -> Void
    let onConfirm: (String, String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        DialogFrame(title: "Disk header",
                    palette: palette,
                    confirmTitle: "Apply",
                    onCancel: onCancel,
                    onConfirm: { onConfirm(name, id) }) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Disk name") {
                    TextField("", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { onConfirm(name, id) }
                }
                if wantsID {
                    LabeledContent("Disk ID") {
                        TextField("", text: $id).textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                }
                Text(wantsID
                     ? "The name appears in the reverse-video line at the top of a directory listing."
                     : "The name appears at the top of the panel, the way a volume is named.")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.dim))
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Viewer

enum ViewerMode: String, CaseIterable, Identifiable {
    case hex, bitmap, image, basic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hex: return "Hex"
        case .bitmap: return "Bitmap"
        case .image: return "Image"
        case .basic: return "Basic"
        }
    }
}

struct ViewerSheet: View {
    let content: ViewerContent
    let palette: Palette
    @ObservedObject var settings: SettingsStore
    let onClose: () -> Void

    /// C64 view: the first two bytes are read as the load address and become
    /// the first offset, and the dump starts at the third byte.
    @State private var c64View: Bool
    @State private var mode: ViewerMode
    /// Block geometry is seeded from the file's size, since it depends on what
    /// the file is; zoom and invert come from the remembered preferences.
    @State private var layout: BitmapLayout
    /// Lives here rather than in the pane so it survives a Raw/C64 switch.
    @State private var displayOffset = 0
    /// The same for the picture pane, which is rebuilt on every mode switch.
    @State private var imageZoom: Int
    @State private var correctAspect: Bool

    init(content: ViewerContent, palette: Palette, settings: SettingsStore,
         onClose: @escaping () -> Void) {
        self.content = content
        self.palette = palette
        _settings = ObservedObject(wrappedValue: settings)
        self.onClose = onClose
        _mode = State(initialValue: content.startMode)
        _imageZoom = State(initialValue: settings.imageZoom)
        _correctAspect = State(initialValue: settings.imageCorrectAspect)
        // C64 offsets are the useful default here, and the choice is remembered.
        _c64View = State(initialValue: settings.viewerUsesC64Offsets && content.data.count >= 2)
        // Only a PRG spends two bytes on a load address; anything else is all data.
        let payload = content.isPRG ? max(0, content.data.count - 2) : content.data.count
        var seed = BitmapPreset.suggested(forByteCount: payload).layout(basedOn: BitmapLayout())
        seed.magnification = settings.bitmapMagnification
        seed.invert = settings.bitmapInvert
        _layout = State(initialValue: seed.normalized)
    }

    // MARK: - Layout
    //
    // The columns are sized from the actual glyph width so the sheet is only
    // as wide as the dump, rather than a guessed constant with slack around it.

    private static let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private static let charWidth = ("0" as NSString)
        .size(withAttributes: [.font: mono]).width

    private var glyphZoom: Int { max(1, settings.zoom - 1) }
    private var offsetWidth: CGFloat { Self.charWidth * 4 }          // "0801"
    private var hexWidth: CGFloat { Self.charWidth * 47 }            // 16 x "FF" + 15 gaps
    private var textWidth: CGFloat { CGFloat(16 * CharacterROM.glyphWidth * glyphZoom) }
    private let columnGap: CGFloat = 14
    private let edge: CGFloat = 14

    private var sheetWidth: CGFloat {
        let columns = offsetWidth + columnGap + hexWidth + columnGap + textWidth
        // The header needs a sensible minimum of its own.
        return max(columns + edge * 2, 430)
    }

    // MARK: - Content

    /// The load address held in the first two bytes, if there are two.
    private var loadAddress: Int? {
        let bytes = [UInt8](content.data.prefix(2))
        guard bytes.count == 2 else { return nil }
        return Int(bytes[0]) | (Int(bytes[1]) << 8)
    }

    private struct Line: Identifiable {
        let id: Int
        let offset: Int
        /// nil is a slot that sits before the load address, left blank so the
        /// row can still start on a $10 boundary.
        let cells: [UInt8?]
    }

    private var lines: [Line] {
        let skip = c64View ? 2 : 0
        let body = [UInt8](content.data.dropFirst(skip).prefix(65536))
        let base = c64View ? (loadAddress ?? 0) : 0

        // Rows always begin on a $10 boundary, so a load address of $0801
        // starts the dump at $0800 with one blank slot. That keeps every
        // column under the same address digit all the way down.
        let lead = base % 16
        var cells: [UInt8?] = Array(repeating: nil, count: lead)
        cells.append(contentsOf: body.map { Optional($0) })
        let start = base - lead

        return stride(from: 0, to: cells.count, by: 16).enumerated().map { index, offset in
            // Addresses wrap at $FFFF, the way they would on the machine.
            Line(id: index,
                 offset: (start + offset) & 0xFFFF,
                 cells: Array(cells[offset..<min(offset + 16, cells.count)]))
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if content.isPRG {
            parts.append("PRG")
            if let loadAddress { parts.append(String(format: "load $%04X", loadAddress)) }
        }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(content.data.count), countStyle: .file))
        if content.data.count > 65536 { parts.append("first 64 KB shown") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.color(.border))
            switch mode {
            case .hex:
                hexDump
            case .bitmap:
                BitmapPane(bytes: [UInt8](content.data.dropFirst(c64View ? 2 : 0)),
                           baseAddress: c64View ? (loadAddress ?? 0) : 0,
                           fileName: content.title,
                           palette: palette,
                           layout: $layout,
                           displayOffset: $displayOffset)
            case .image:
                // An IFF carries no load address either, and its own header
                // says where the pixels start.
                IFFImagePane(bytes: [UInt8](content.data),
                             fileName: content.title,
                             palette: palette,
                             zoom: $imageZoom,
                             correctAspect: $correctAspect)
            case .basic:
                // A listing always starts after the load address, so the
                // Raw/C64 switch has nothing to say about it.
                BasicPane(bytes: [UInt8](content.data), palette: palette, settings: settings)
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(palette.color(.window))
        .onChange(of: layout) { _, new in
            // Only the display preferences are remembered between files.
            settings.bitmapMagnification = new.magnification
            settings.bitmapInvert = new.invert
        }
        .onChange(of: c64View) { _, new in settings.viewerUsesC64Offsets = new }
        .onChange(of: imageZoom) { _, new in settings.imageZoom = new }
        .onChange(of: correctAspect) { _, new in settings.imageCorrectAspect = new }
    }

    private var sheetSize: CGSize {
        switch mode {
        case .hex: return CGSize(width: sheetWidth, height: 520)
        case .bitmap: return CGSize(width: 900, height: 620)
        case .image: return CGSize(width: 900, height: 620)
        case .basic: return CGSize(width: 720, height: 620)
        }
    }

    private var hexDump: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(lines) { line in
                        HStack(spacing: columnGap) {
                            Text(String(format: "%04X", line.offset))
                                .foregroundStyle(palette.color(.dim))
                                .frame(width: offsetWidth, alignment: .leading)
                            Text(line.cells
                                .map { cell in cell.map { String(format: "%02X", $0) } ?? "  " }
                                .joined(separator: " "))
                                .foregroundStyle(palette.color(.text))
                                .frame(width: hexWidth, alignment: .leading)
                            PETSCIIText(petscii: line.cells.map { cell in
                                            cell.map { $0 == 0 ? 0x20 : $0 } ?? 0x20
                                        },
                                        color: palette.color(.image),
                                        zoom: glyphZoom,
                                        font: settings.font)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10, design: .monospaced))
                    }
                }
                .padding(.horizontal, edge)
                .padding(.vertical, 10)
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Picker("", selection: $mode) {
                    ForEach(ViewerMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 232)
                if loadAddress != nil, mode != .basic, mode != .image {
                    Picker("", selection: $c64View) {
                        Text("Raw").tag(false)
                        Text("C64").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 96)
                    .help("Raw starts at 0000 and includes the load address bytes. C64 starts at the load address and skips them.")
                }
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
            Text(subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.color(.dim))
                .lineLimit(1)
        }
        .padding(.horizontal, edge)
        .padding(.vertical, 10)
    }
}

// MARK: - Help

struct HelpSheet: View {
    let palette: Palette
    let onClose: () -> Void

    private struct Section: Identifiable {
        let title: String
        let rows: [(key: String, what: String)]
        var id: String { title }
    }

    /// Grouped the way the keys are reached for rather than by which key they
    /// happen to be, so the table can be read down a column.
    private let sections: [Section] = [
        Section(title: "Moving around", rows: [
            ("↑ ↓", "Move the cursor"),
            ("⇧↑ ⇧↓", "Move ten rows"),
            ("Page ↑ ↓", "Move a screen"),
            ("Home / End", "First or last row"),
            ("Tab", "Switch to the other panel"),
            ("→", "Enter a folder or an image — never goes up"),
            ("← / Delete / ⌘←", "Go up, saving the disk image on the way out"),
            ("Esc", "Go up without saving the disk image"),
            ("⌘D", "Jump to the list of volumes"),
            ("⌘U", "Re-read the panels from disk"),
        ]),
        Section(title: "Marking", rows: [
            ("Space", "Mark the file under the cursor"),
            ("+ / −", "Mark all, unmark all"),
            ("*", "Invert the marks"),
        ]),
        Section(title: "Files", rows: [
            ("Return", "Enter a folder or an image, or play a tune or a module"),
            ("F5", "Copy to the other panel"),
            ("F6", "Move to the other panel"),
            ("F7", "New folder"),
            ("F8", "Delete"),
            ("F9 / ⇧F6 / ⌘R", "Rename"),
            ("⌘O", "Open with the app macOS uses for it"),
            ("⌥⌘R", "Show in Finder"),
            ("⇧⌘.", "Show or hide hidden files"),
            ("Right click", "All of these, plus Open With"),
        ]),
        Section(title: "Viewing", rows: [
            ("F3", "View the file under the cursor"),
            ("⇧F3", "View it as a bitmap"),
            ("", "Tokenised BASIC is listed in the Commodore font"),
        ]),
        Section(title: "Disk images", rows: [
            ("F2", "New image (D64, D67, D71, D81, D80, D82, ADF)"),
            ("F4", "Edit the disk header"),
            ("⌘S", "Save the open image without leaving it"),
            ("⌘↑ ⌘↓", "Move an entry within an image directory"),
            ("", "Commodore menu: DEL entries, lock, unpack a DMS to ADF"),
        ]),
        Section(title: "Music", rows: [
            ("Return", "Play a SID tune or a tracker module"),
            ("⇧Return", "Force the SID player on, entering addresses by hand"),
            ("Space", "Play or pause, in either player"),
            ("⌘↑ ⌘↓", "Previous or next file, without leaving the player"),
            ("⌘← ⌘→", "Step the song: the SID byte, or a module's subsong"),
            ("", "Either player has a scope, and exports it as video"),
        ]),
        Section(title: "Appearance", rows: [
            ("Ctrl-Shift / ⇧⌘C", "Switch the Commodore font between upper and lower case"),
            ("⌘,", "Settings: theme, palette, character ROM"),
        ]),
        Section(title: "The app", rows: [
            ("F1", "This help"),
            ("F10 / ⌘Q", "Quit"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider().overlay(palette.color(.border))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        table(section)
                    }
                    footnote
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 620)
        .background(palette.color(.window))
    }

    private func table(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(palette.color(.dim))
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        // An empty key marks a note about the row above it, so
                        // it lines up under the descriptions rather than
                        // leaving a gap where a key would be.
                        Text(row.key)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.color(.accent))
                            .frame(width: 150, alignment: .leading)
                        Text(row.what)
                            .font(.system(size: 11))
                            .foregroundStyle(palette.color(row.key.isEmpty ? .dim : .text))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    // Banded rows, so the eye can cross the gap between a key
                    // and what it does without losing the line.
                    .background(index.isMultiple(of: 2)
                                ? palette.color(.panel).opacity(0.5) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(palette.color(.border).opacity(0.5)))
        }
    }

    private var footnote: some View {
        Text("If macOS uses F1–F12 for screen brightness and media, hold Fn, or turn on \u{201C}Use F1, F2, etc. keys as standard function keys\u{201D} in System Settings › Keyboard. Every function key also has a button in the bar along the bottom and an entry in the menus.")
            .font(.system(size: 10))
            .foregroundStyle(palette.color(.dim))
            .fixedSize(horizontal: false, vertical: true)
    }
}
