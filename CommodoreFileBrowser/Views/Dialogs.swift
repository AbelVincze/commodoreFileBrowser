import SwiftUI

// MARK: - Shared chrome

private struct DialogFrame<Content: View>: View {
    let title: String
    let palette: Palette
    let confirmTitle: String
    var confirmDisabled: Bool = false
    var destructive: Bool = false
    /// A third, destructive button, set apart on the left the way the system
    /// places an alternative to the two the dialog is really asking about.
    var alternative: (title: String, action: () -> Void)?
    /// Dialogs are one width apart from the ones that expand to show a
    /// directory field byte by byte, which needs the room.
    var width: CGFloat = 420
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content()
            HStack {
                if let alternative {
                    Button(alternative.title, role: .destructive, action: alternative.action)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: destructive ? .destructive : nil, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmDisabled)
            }
        }
        .padding(20)
        .frame(width: width)
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

// MARK: - Advanced directory editing

/// What the advanced half of the header dialog starts from: the printed field
/// as the disk holds it, and the figure the listing ends on.
struct DiskHeaderDraft {
    var header: [UInt8]
    var blocksFree: Int
    var maximumBlocksFree: Int
}

/// What the header dialog comes back with — a name and an ID typed the
/// ordinary way, or the bytes of the line itself.
enum DiskHeaderEdit {
    case simple(name: String, id: String)
    case raw(header: [UInt8], blocksFree: Int?)
}

/// The same for one directory row: its 16 byte name field and the block count
/// printed in front of it.
struct DirectoryEntryDraft {
    var name: [UInt8]
    var blocks: Int
}

enum DirectoryEntryEdit {
    case name(String)
    case raw(name: [UInt8], blocks: Int)
}

// MARK: - Disk header

struct DiskHeaderSheet: View {
    let palette: Palette
    @State var name: String
    @State var id: String
    /// An Amiga volume has a name and nowhere to put an ID.
    var wantsID: Bool = true
    /// The bytes behind the line, on a writable Commodore image. Nil where
    /// there is no such field to take apart, and the Advanced half stays away.
    var advanced: DiskHeaderDraft?
    @Binding var font: PETSCIIFont
    let onCancel: () -> Void
    let onConfirm: (DiskHeaderEdit) -> Void
    @FocusState private var focused: Bool

    @State private var expanded = false
    @State private var header: [UInt8] = []
    @State private var caret = 0
    @State private var setsBlocksFree = false
    @State private var blocksFree = 0
    /// What the two text fields held when the sheet opened, so that expanding
    /// carries over what was typed without overwriting bytes nobody touched.
    @State private var initialName = ""
    @State private var initialID = ""

    var body: some View {
        DialogFrame(title: "Disk header",
                    palette: palette,
                    confirmTitle: "Apply",
                    width: expanded ? 580 : 420,
                    onCancel: onCancel,
                    onConfirm: confirm) {
            VStack(alignment: .leading, spacing: 10) {
                if !expanded {
                    LabeledContent("Disk name") {
                        TextField("", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(confirm)
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
                if advanced != nil {
                    DisclosureGroup("Advanced", isExpanded: expansion) {
                        advancedContent
                            .padding(.top, 8)
                    }
                }
            }
        }
        .onAppear {
            initialName = name
            initialID = id
            focused = true
        }
    }

    @ViewBuilder
    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            PETSCIIFieldEditor(bytes: $header, caret: $caret, font: $font,
                               groups: [.init(label: "Disk name", range: 0..<16),
                                        .init(label: "Pad", range: 16..<18),
                                        .init(label: "ID", range: 18..<20),
                                        .init(label: "Pad", range: 20..<21),
                                        .init(label: "DOS", range: 21..<23)],
                               palette: palette)
            Text("The whole reverse-video line, byte for byte. The first pad byte is where the drive puts the closing quote, so it never prints; everything after it does.")
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Toggle("Blocks free", isOn: $setsBlocksFree)
                    .toggleStyle(.checkbox)
                TextField("", value: $blocksFree, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .disabled(!setsBlocksFree)
                Text("0–\(advanced?.maximumBlocksFree ?? 0)")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.dim))
            }
            Text("Only the free counters move; the block map is left as it is. Repair Disk counts the map, so it would put the figure back.")
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var expansion: Binding<Bool> {
        Binding(get: { expanded }, set: { open in
            if open { expand() } else { collapse() }
            expanded = open
        })
    }

    /// Take the bytes off the disk, and lay over them anything typed into the
    /// two fields before Advanced was opened.
    private func expand() {
        guard let advanced else { return }
        var raw = PETSCIIFieldEditor.padded(advanced.header, to: CBMDiskImage.headerFieldLength)
        if name != initialName {
            let typed = PETSCII.padded16(PETSCII.cbmName(fromASCII: name))
            for i in 0..<16 { raw[i] = typed[i] }
        }
        if id != initialID {
            let typed = PETSCII.petscii(fromASCII: id)
            raw[18] = typed.count > 0 ? typed[0] : 0x20
            raw[19] = typed.count > 1 ? typed[1] : 0x20
        }
        header = raw
        caret = 0
        blocksFree = advanced.blocksFree
    }

    /// And back: the fields catch up with the bytes, so closing Advanced does
    /// not quietly throw the editing away.
    private func collapse() {
        guard header.count == CBMDiskImage.headerFieldLength else { return }
        name = PETSCII.ascii(PETSCII.trimPadding(Array(header[0..<16])))
        id = PETSCII.ascii(Array(header[18..<20]))
        initialName = name
        initialID = id
    }

    private func confirm() {
        if expanded {
            onConfirm(.raw(header: header, blocksFree: setsBlocksFree ? blocksFree : nil))
        } else {
            onConfirm(.simple(name: name, id: id))
        }
    }
}

// MARK: - One directory row

/// Rename, and Add DEL entry: the same dialog, since a decorated directory is
/// written the same way whether the row started as a file or as a spacer.
struct DirectoryEntrySheet: View {
    let title: String
    let label: String
    let confirmTitle: String
    let palette: Palette
    @State var text: String
    /// The row as the directory holds it, on a writable Commodore image.
    var advanced: DirectoryEntryDraft?
    @Binding var font: PETSCIIFont
    let onCancel: () -> Void
    let onConfirm: (DirectoryEntryEdit) -> Void
    @FocusState private var focused: Bool

    @State private var expanded = false
    @State private var name: [UInt8] = []
    @State private var caret = 0
    @State private var blocks = 0
    @State private var initialText = ""

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        DialogFrame(title: title,
                    palette: palette,
                    confirmTitle: confirmTitle,
                    confirmDisabled: !expanded && isEmpty,
                    width: expanded ? 580 : 420,
                    onCancel: onCancel,
                    onConfirm: confirm) {
            VStack(alignment: .leading, spacing: 10) {
                if !expanded {
                    LabeledContent(label) {
                        TextField("", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit { if !isEmpty { confirm() } }
                    }
                }
                if advanced != nil {
                    DisclosureGroup("Advanced", isExpanded: expansion) {
                        advancedContent
                            .padding(.top, 8)
                    }
                }
            }
        }
        .onAppear {
            initialText = text
            focused = true
        }
    }

    @ViewBuilder
    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            PETSCIIFieldEditor(bytes: $name, caret: $caret, font: $font,
                               groups: [.init(label: "Name field", range: 0..<16)],
                               palette: palette)
            Text("All sixteen bytes of the name. The drive closes the quote on the first shifted space and prints the rest of the field after it, which is where a decorated row keeps its graphics.")
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                LabeledContent("Blocks") {
                    TextField("", value: $blocks, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                .fixedSize()
                Spacer()
            }
            Text("The number the listing prints. Nothing checks it against the file, which is what lets a directory count in pictures.")
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var expansion: Binding<Bool> {
        Binding(get: { expanded }, set: { open in
            if open { expand() } else { collapse() }
            expanded = open
        })
    }

    private func expand() {
        guard let advanced else { return }
        name = text == initialText
            ? PETSCIIFieldEditor.padded(advanced.name, to: 16)
            : PETSCII.padded16(PETSCII.cbmName(fromASCII: text))
        caret = 0
        blocks = advanced.blocks
    }

    private func collapse() {
        text = PETSCII.ascii(PETSCII.trimPadding(name))
        initialText = text
    }

    private func confirm() {
        if expanded {
            onConfirm(.raw(name: name, blocks: blocks))
        } else {
            onConfirm(.name(text))
        }
    }
}

// MARK: - Repair

/// The report a repair shows before it writes anything: what is wrong, and
/// then what it is about to do about it. A disk it cannot put entirely right
/// gets the first half and a reason, and the button stays out of reach.
struct RepairSheet: View {
    let plan: DiskRepairPlan
    let diskName: String
    let palette: Palette
    let onCancel: () -> Void
    let onConfirm: () -> Void
    /// Scratch the damaged files and survey again. The sheet stays up on the
    /// new plan, so the repair this clears the way for is still read before
    /// it is agreed to.
    let onDeleteBlockers: () -> Void

    private var blockers: [String] { plan.blockingFiles }

    /// Offered only when there is damage to clear. A disk that can already be
    /// repaired has nothing to delete, and the button would be an invitation
    /// to lose a file for no reason.
    private var deleteButton: (title: String, action: () -> Void)? {
        guard !blockers.isEmpty else { return nil }
        let noun = blockers.count == 1 ? "File" : "Files"
        return (title: "Delete \(blockers.count) Damaged \(noun)", action: onDeleteBlockers)
    }

    var body: some View {
        DialogFrame(title: "Repair \(diskName)",
                    palette: palette,
                    confirmTitle: "Repair",
                    confirmDisabled: !plan.canRepair || plan.isClean,
                    alternative: deleteButton,
                    onCancel: onCancel,
                    onConfirm: onConfirm) {
            VStack(alignment: .leading, spacing: 12) {
                if plan.isClean {
                    line("\(plan.filesChecked) file\(plan.filesChecked == 1 ? "" : "s") checked. "
                         + "The BAM agrees with them and every block count is right.")
                    line("\(plan.blocksFreeBefore) blocks free.", dim: true)
                } else {
                    section("Found")
                    findings
                    if plan.canRepair {
                        section("Will change")
                        changes
                    } else if !blockers.isEmpty {
                        section("Deleting would")
                        blockingFiles
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: What is wrong

    @ViewBuilder
    private var findings: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("\(plan.filesChecked) file\(plan.filesChecked == 1 ? "" : "s") checked.", dim: true)

            // The two that stop a repair come first, since they are the reason
            // the button is disabled and everything below them is moot.
            // Two claimants named, however many there are. A disk with ten
            // entries pointing at one sector is real — hand made directory art
            // does it — and spelling out all ten on every line buries the rest
            // of the report. The full list is under "Deleting would" below.
            ForEach(Array(plan.collisions.prefix(4).enumerated()), id: \.offset) { _, clash in
                line("Track \(clash.track) sector \(clash.sector) is claimed by "
                     + clash.claimedBy.prefix(2).map { "\"\($0)\"" }.joined(separator: " and ")
                     + (clash.claimedBy.count > 2
                        ? " and \(clash.claimedBy.count - 2) others" : "") + ".", bad: true)
            }
            if plan.collisions.count > 4 {
                line("\(plan.collisions.count - 4) more shared sectors.", bad: true)
            }
            ForEach(Array(plan.brokenChains.prefix(4).enumerated()), id: \.offset) { _, name in
                line("\"\(name)\" has a block chain that leaves the disk or turns back on itself.",
                     bad: true)
            }

            if !plan.splatToScratch.isEmpty {
                line("\(plan.splatToScratch.count) unclosed file\(plan.splatToScratch.count == 1 ? "" : "s"): "
                     + plan.splatToScratch.prefix(4).map { "\"\($0)\"" }.joined(separator: ", ")
                     + (plan.splatToScratch.count > 4 ? " and more" : "") + ".")
            }
            if !plan.wrongCounts.isEmpty {
                line("\(plan.wrongCounts.count) block count\(plan.wrongCounts.count == 1 ? "" : "s") "
                     + "disagree with the file: "
                     + plan.wrongCounts.prefix(3)
                        .map { "\"\($0.name)\" says \($0.statedBlocks), is \($0.actualBlocks)" }
                        .joined(separator: ", ") + ".")
            }
            if plan.toFree > 0 {
                line("\(plan.toFree) sector\(plan.toFree == 1 ? " is" : "s are") allocated and used by nothing.")
            }
            if plan.toAllocate > 0 {
                line("\(plan.toAllocate) sector\(plan.toAllocate == 1 ? " is" : "s are") in use and marked free.")
            }
            if plan.badFreeCounts > 0 {
                line("\(plan.badFreeCounts) track\(plan.badFreeCounts == 1 ? "" : "s") "
                     + "count free sectors they do not have, which is why this disk "
                     + "claims \(plan.blocksFreeBefore) blocks free.")
            }
            if !plan.canRepair {
                line("A shared sector or a broken chain is damage the BAM cannot describe, "
                     + "and guessing at it would lose a file rather than save one. Nothing "
                     + "will be written while these files are on the disk.", dim: true)
            }
        }
    }

    // MARK: The way past a blocker

    /// Both claimants of a shared sector are named here, not one of them:
    /// the sector belongs to a single file and nothing on the disk says
    /// which, so keeping either would be the guess the repair refuses to make.
    @ViewBuilder
    private var blockingFiles: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("Scratch \(blockers.count) file\(blockers.count == 1 ? "" : "s"): "
                 + blockers.prefix(6).map { "\"\($0)\"" }.joined(separator: ", ")
                 + (blockers.count > 6 ? " and \(blockers.count - 6) more" : "") + ".")
            line("The entries go; their blocks are left for the repair to work out afresh. "
                 + "Nothing is written to the file until the image is saved, so this can "
                 + "still be undone by leaving the image without saving.", dim: true)
        }
    }

    // MARK: What it will do

    @ViewBuilder
    private var changes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !plan.splatToScratch.isEmpty {
                line("Scratch \(plan.splatToScratch.count) unclosed file"
                     + "\(plan.splatToScratch.count == 1 ? "" : "s"), as VALIDATE does.")
            }
            if !plan.wrongCounts.isEmpty {
                line("Correct \(plan.wrongCounts.count) block count\(plan.wrongCounts.count == 1 ? "" : "s").")
            }
            if plan.toFree > 0 || plan.toAllocate > 0 || plan.badFreeCounts > 0 {
                line("Rebuild the BAM: free \(plan.toFree), allocate \(plan.toAllocate)"
                     + (plan.badFreeCounts > 0 ? ", and write every track's free count afresh" : "")
                     + ".")
            }
            line("Blocks free: \(plan.blocksFreeBefore) → \(plan.blocksFreeAfter).", dim: true)
            line("The image is only changed in memory until it is saved.", dim: true)
        }
    }

    // MARK: Pieces

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(palette.color(.dim))
    }

    private func line(_ text: String, dim: Bool = false, bad: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(bad ? palette.color(.marked)
                                 : (dim ? palette.color(.dim) : palette.color(.text)))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            ("Drag", "Between the panels, or to and from the Finder"),
            ("", "One volume moves, two copy; an image counts as its own"),
            ("⌥ Drag", "Copy where it would move, and move where it would copy"),
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
            ("", "Advanced, in the header, rename and DEL dialogs: PETSCII byte by byte"),
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
