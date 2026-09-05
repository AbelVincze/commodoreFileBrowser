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
            }
        }
        .onAppear { focused = true }
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
        let insideImage = items.contains { $0.kind == .cbmFile }
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
    let onConfirm: (CBMDiskImage.BlankFormat, String, String, String) -> Void

    @State private var kind: CBMDiskImage.BlankFormat = .d64
    @State private var fileName = "NEW"
    @State private var diskName = "NEW DISK"
    @State private var diskID = "01"
    @FocusState private var focused: Bool

    var body: some View {
        DialogFrame(title: "New disk image",
                    palette: palette,
                    confirmTitle: "Create",
                    confirmDisabled: fileName.trimmingCharacters(in: .whitespaces).isEmpty,
                    onCancel: onCancel,
                    onConfirm: { onConfirm(kind, fileName, diskName, diskID) }) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Format", selection: $kind) {
                    ForEach(CBMDiskImage.BlankFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(kind.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.dim))
                LabeledContent("File name") {
                    TextField("NEW", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                }
                LabeledContent("Disk name") {
                    TextField("NEW DISK", text: $diskName).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Disk ID") {
                    TextField("01", text: $diskID).textFieldStyle(.roundedBorder).frame(width: 60)
                }
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Disk header

struct DiskHeaderSheet: View {
    let palette: Palette
    @State var name: String
    @State var id: String
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
                LabeledContent("Disk ID") {
                    TextField("", text: $id).textFieldStyle(.roundedBorder).frame(width: 60)
                }
                Text("The name appears in the reverse-video line at the top of a directory listing.")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.dim))
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: - Viewer

enum ViewerMode: String, CaseIterable, Identifiable {
    case hex, bitmap, basic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hex: return "Hex"
        case .bitmap: return "Bitmap"
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

    init(content: ViewerContent, palette: Palette, settings: SettingsStore,
         onClose: @escaping () -> Void) {
        self.content = content
        self.palette = palette
        _settings = ObservedObject(wrappedValue: settings)
        self.onClose = onClose
        _mode = State(initialValue: content.startInBitmap ? .bitmap : .hex)
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
    }

    private var sheetSize: CGSize {
        switch mode {
        case .hex: return CGSize(width: sheetWidth, height: 520)
        case .bitmap: return CGSize(width: 900, height: 620)
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
                .frame(width: 176)
                if loadAddress != nil, mode != .basic {
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

    private let bindings: [(String, String)] = [
        ("↑ ↓", "Move the cursor"),
        ("⇧↑ ⇧↓", "Move ten rows"),
        ("Page ↑ / ↓, Home, End", "Jump through the listing"),
        ("Tab", "Switch to the other panel"),
        ("Space", "Mark the file under the cursor"),
        ("+ / - / *", "Mark all, unmark all, invert marks"),
        ("Return", "Enter a folder or an image, or play a file as music"),
        ("⇧Return", "Play, entering the addresses by hand"),
        ("← or Delete", "Go up, saving the disk image on the way out"),
        ("", "The cursor returns to where it was in each folder"),
        ("Esc", "Go up without saving the disk image"),
        ("⌘S", "Save the open disk image without leaving it"),
        ("F1", "This help"),
        ("F2", "New disk image (D64 / D71 / D81)"),
        ("F3", "View the file under the cursor"),
        ("⇧F3", "View it as a bitmap"),
        ("", "The viewer also lists tokenised BASIC in the Commodore font"),
        ("F4", "Edit the disk header of the open image"),
        ("F5", "Copy to the other panel"),
        ("F6", "Move to the other panel"),
        ("⇧F6 or ⌘R", "Rename"),
        ("F7", "New folder"),
        ("F8", "Delete"),
        ("F9", "Rename"),
        ("F10", "Quit"),
        ("⌘D", "Jump to the list of volumes"),
        ("Ctrl-Shift", "Switch the Commodore font between upper and lower case"),
        ("⌘H", "Show or hide hidden files"),
        ("⌘↑ / ⌘↓", "Rearrange an entry inside a disk image")
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(bindings, id: \.0) { key, description in
                        HStack(alignment: .top, spacing: 12) {
                            Text(key)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.color(.accent))
                                .frame(width: 170, alignment: .leading)
                            Text(description)
                                .font(.system(size: 11))
                                .foregroundStyle(palette.color(.text))
                        }
                    }
                    Divider().padding(.vertical, 6)
                    Text("If macOS uses F1-F12 for screen brightness and media, hold Fn, or turn on “Use F1, F2, etc. keys as standard function keys” in System Settings › Keyboard.")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.color(.dim))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
        .frame(width: 480, height: 520)
        .background(palette.color(.window))
    }
}
