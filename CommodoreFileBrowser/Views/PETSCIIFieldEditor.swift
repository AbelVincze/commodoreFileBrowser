import SwiftUI

/// A byte-level editor for a field a Commodore directory prints.
///
/// The dialogs that edit a directory take a name the way the Mac takes one —
/// a text field, in the system font — and that is right for nearly everything.
/// It cannot say the other half of PETSCII, though: the graphics, the reverse
/// video forms and the shifted space that closes the quote early, which is
/// what a decorated directory is written in. This is the other half: a row of
/// cells drawn from the character ROM, a caret that types into them, and a
/// grid of every byte no key reaches.
struct PETSCIIFieldEditor: View {

    /// A named run of the field, so a header can label its parts.
    struct Group: Identifiable {
        let label: String
        let range: Range<Int>
        var id: Int { range.lowerBound }
    }

    @Binding var bytes: [UInt8]
    @Binding var caret: Int
    @Binding var font: PETSCIIFont
    var groups: [Group]
    let palette: Palette

    @State private var showsEveryByte = false
    @FocusState private var focused: Bool

    private let zoom = 2
    private var cellWidth: CGFloat { CGFloat(CharacterROM.glyphWidth * zoom) + 3 }
    private var cellHeight: CGFloat { CGFloat(CharacterROM.glyphHeight * zoom) + 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
            Divider()
            HStack {
                Picker("Character set", selection: $font.set) {
                    ForEach(CharacterROM.CharSet.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
                Spacer()
                Toggle("Every byte", isOn: $showsEveryByte)
                    .toggleStyle(.checkbox)
            }
            characters
        }
    }

    // MARK: - The field itself

    private var field: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.label)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.color(.dim))
                    HStack(spacing: 1) {
                        ForEach(Array(group.range), id: \.self) { index in
                            cell(index)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(palette.color(.panel)))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(focused ? palette.color(.accent) : palette.color(.border),
                              lineWidth: focused ? 2 : 1)
        )
        .focusable()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { handle($0) }
        // The editor is the point of opening Advanced, so it takes the focus
        // and can be typed into straight away. A turn of the run loop first:
        // the sheet hands focus out as it lays itself out, and setting it
        // during that pass is undone again.
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    private func cell(_ index: Int) -> some View {
        let selected = index == caret
        return Button {
            caret = index
            focused = true
        } label: {
            ZStack {
                // Most of a decorated field is blank glyphs, so every cell
                // needs a ground of its own or the row is a picture of nothing.
                RoundedRectangle(cornerRadius: 2)
                    .fill(selected ? palette.color(.cursorBackground) : palette.color(.window))
                if bytes.indices.contains(index) {
                    PETSCIIText(petscii: [bytes[index]],
                                color: selected ? palette.color(.cursorText) : palette.color(.text),
                                zoom: zoom, font: font)
                }
            }
            .frame(width: cellWidth, height: cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var caption: String {
        guard bytes.indices.contains(caret) else { return "" }
        return String(format: "Byte %d of %d — $%02X. Type to write, arrows to move, ⌫ to blank.",
                      caret + 1, bytes.count, Int(bytes[caret]))
    }

    // MARK: - The characters no key types

    private var characters: some View {
        let values = showsEveryByte ? Self.everyByte : Self.unreachableBytes
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(stride(from: 0, to: values.count, by: Self.columns)), id: \.self) { start in
                    HStack(spacing: 1) {
                        ForEach(values[start..<min(start + Self.columns, values.count)], id: \.self) { byte in
                            glyphButton(byte)
                        }
                    }
                }
            }
            .padding(4)
        }
        // Tall enough for every character no key reaches, so the grid this is
        // here for needs no scrolling; asking for all 256 scrolls.
        .frame(height: 8 + CGFloat(Self.unreachableRows) * (cellHeight + 1))
        .background(RoundedRectangle(cornerRadius: 5).fill(palette.color(.panel)))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.color(.border)))
    }

    private func glyphButton(_ byte: UInt8) -> some View {
        Button {
            write(byte)
            focused = true
        } label: {
            PETSCIIText(petscii: [byte], color: palette.color(.text), zoom: zoom, font: font)
                .frame(width: cellWidth, height: cellHeight)
                .background(RoundedRectangle(cornerRadius: 2).fill(palette.color(.window).opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(format: "$%02X", Int(byte)))
    }

    /// Every byte a printable key can put in the field, through the same
    /// conversion the plain text fields use. What is left over is what this
    /// editor exists for, and is what the grid shows until it is asked for
    /// the lot.
    private static let typeableBytes: Set<UInt8> = {
        var out: Set<UInt8> = []
        for scalar in UInt32(0x20)...UInt32(0x7E) {
            let text = String(UnicodeScalar(scalar)!)
            out.formUnion(PETSCII.petscii(fromASCII: text))
        }
        return out
    }()

    private static let everyByte: [UInt8] = (0...255).map { UInt8($0) }
    private static let unreachableBytes: [UInt8] = everyByte.filter { !typeableBytes.contains($0) }
    private static let columns = 24
    private static let unreachableRows = (unreachableBytes.count + columns - 1) / columns

    // MARK: - Editing

    private func write(_ byte: UInt8) {
        guard bytes.indices.contains(caret) else { return }
        bytes[caret] = byte
        caret = min(caret + 1, bytes.count - 1)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !bytes.isEmpty else { return .ignored }
        // Command chords belong to the menu bar, and Return, Tab and Escape to
        // the dialog around this.
        guard !press.modifiers.contains(.command) else { return .ignored }

        switch press.key {
        case .leftArrow: caret = max(0, caret - 1); return .handled
        case .rightArrow: caret = min(bytes.count - 1, caret + 1); return .handled
        case .home, .upArrow: caret = 0; return .handled
        case .end, .downArrow: caret = bytes.count - 1; return .handled
        case .delete:
            caret = max(0, caret - 1)
            bytes[caret] = PETSCII.shiftedSpace
            return .handled
        case .deleteForward:
            bytes[caret] = PETSCII.shiftedSpace
            return .handled
        case .return, .escape, .tab: return .ignored
        default: break
        }

        var wrote = false
        for scalar in press.characters.unicodeScalars where scalar.value >= 0x20 && scalar.value < 0x7F {
            for byte in PETSCII.petscii(fromASCII: String(scalar)) {
                write(byte)
                wrote = true
            }
        }
        return wrote ? .handled : .ignored
    }
}

// MARK: - Field bytes

extension PETSCIIFieldEditor {
    /// A field of exactly `length` bytes: what is there, padded out the way
    /// CBM DOS pads a name.
    static func padded(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        var out = Array(bytes.prefix(length))
        while out.count < length { out.append(PETSCII.shiftedSpace) }
        return out
    }
}
