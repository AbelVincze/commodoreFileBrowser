import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Draws arbitrary data as a 1 bit per pixel image, with the block controls
/// that decide how the bytes are folded into a picture.
struct BitmapPane: View {
    let bytes: [UInt8]
    /// Address of byte 0 of `bytes`, before any display offset. Zero in Raw,
    /// the load address in C64.
    let baseAddress: Int
    let fileName: String
    let palette: Palette
    @Binding var layout: BitmapLayout
    /// Added on top of the Raw/C64 offset, so you can scrub into the data.
    @Binding var displayOffset: Int

    /// Byte under the pointer, as an index into `shown`.
    @State private var hovered: Int?
    /// Rendering is kept in state rather than computed from `body`: hovering
    /// re-evaluates the body constantly, and re-slicing and re-hashing a
    /// megabyte of data on every mouse move would make it crawl.
    @State private var shown: [UInt8] = []
    @State private var rendered: NSImage?
    @State private var offsetText = "0"

    var body: some View {
        HStack(spacing: 0) {
            canvas
            Divider().overlay(palette.color(.border))
            controls.frame(width: 200)
        }
        .onAppear(perform: rebuild)
        .onChange(of: layout) { _, _ in rebuild() }
        .onChange(of: displayOffset) { _, _ in rebuild() }
        .onChange(of: bytes.count) { _, _ in rebuild() }   // Raw <-> C64
    }

    private func rebuild() {
        let start = max(0, min(displayOffset, bytes.count))
        shown = Array(bytes.dropFirst(start).prefix(BitmapRenderer.byteLimit))
        rendered = BitmapRenderer.shared.image(bytes: shown, layout: layout)
        hovered = nil
    }

    // MARK: - Canvas

    private var canvas: some View {
        ScrollView([.vertical, .horizontal]) {
            if let rendered {
                let scale = CGFloat(layout.magnification)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: rendered)
                        .resizable()
                        .interpolation(.none)
                        .renderingMode(.template)
                        .frame(width: rendered.size.width * scale,
                               height: rendered.size.height * scale)
                        .foregroundStyle(palette.color(.text))

                    if let hovered {
                        let r = layout.blockRect(forByte: hovered)
                        Rectangle()
                            .fill(palette.color(.accent).opacity(0.35))
                            .frame(width: r.width * scale, height: r.height * scale)
                            .offset(x: r.minX * scale, y: r.minY * scale)
                            .allowsHitTesting(false)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hovered = layout.byteIndex(atX: Int(point.x / scale),
                                                   y: Int(point.y / scale))
                            .flatMap { $0 < shown.count ? $0 : nil }
                    case .ended:
                        hovered = nil
                    }
                }
                .padding(10)
            } else {
                Text("Nothing to draw")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.color(.dim))
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.color(.panel))
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Layout")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(BitmapPreset.allCases) { preset in
                        Button(preset.label) { layout = preset.layout(basedOn: layout) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .help(preset.detail)
                    }
                }

                number("Block width", value: $layout.blockWidth)
                number("Block height", value: $layout.blockHeight)
                number("Display width", value: $layout.displayWidth)

                HStack(spacing: 6) {
                    Text("Align").font(.system(size: 11))
                    Spacer(minLength: 4)
                    Picker("", selection: $layout.blockAlign) {
                        Text("None").tag(0)
                        ForEach([2, 4, 8, 16, 32, 64, 128, 256, 512], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 88)
                }
                .help("Round each block up to this many bytes. Sprites sit on 64 byte boundaries but draw only 63.")
                if layout.blockStride != layout.bytesPerBlock {
                    Text("\(layout.bytesPerBlock) drawn of \(layout.blockStride) bytes per block")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.color(.dim))
                }

                Divider().overlay(palette.color(.border))
                section("Start")
                HStack(spacing: 6) {
                    Text("Offset").font(.system(size: 11))
                    Spacer(minLength: 4)
                    TextField("0", text: $offsetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .font(.system(size: 11, design: .monospaced))
                        .onChange(of: offsetText) { _, new in
                            // Decimal, or hex written as $801 or 0x801.
                            if let v = Self.parse(new) {
                                displayOffset = max(0, min(v, max(0, bytes.count - 1)))
                            }
                        }
                }
                .help("Skipped before drawing, on top of the Raw or C64 start")
                Text(String(format: "starts at $%04X", (baseAddress + displayOffset) & 0xFFFF))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(palette.color(.dim))
                HStack(spacing: 6) {
                    Button("-1") { step(-1) }
                    Button("+1") { step(1) }
                    Button("-blk") { step(-layout.blockStride) }
                    Button("+blk") { step(layout.blockStride) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider().overlay(palette.color(.border))
                Stepper(value: $layout.magnification, in: 1...16) {
                    Text("Zoom  \(layout.magnification)x").font(.system(size: 11))
                }
                Toggle("Invert", isOn: $layout.invert).font(.system(size: 11))

                Divider().overlay(palette.color(.border))
                section("Pointer")
                readout

                Divider().overlay(palette.color(.border))
                Button("Save as PNG…", action: savePNG)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .background(palette.color(.window))
    }

    private func step(_ delta: Int) {
        let next = max(0, min(displayOffset + delta, max(0, bytes.count - 1)))
        displayOffset = next
        offsetText = String(next)
    }

    /// Accepts plain decimal, or hex as `$801` / `0x801`.
    static func parse(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("$") { t.removeFirst(); return Int(t, radix: 16) }
        if t.hasPrefix("0x") { t.removeFirst(2); return Int(t, radix: 16) }
        return Int(t)
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(palette.color(.dim))
    }

    private func number(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.color(.text))
            Spacer(minLength: 4)
            TextField("", value: Binding(
                get: { value.wrappedValue },
                // Normalise on commit, so the grid always divides.
                set: { value.wrappedValue = $0; layout = layout.normalized }
            ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .font(.system(size: 11, design: .monospaced))
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let hovered, hovered < shown.count, let p = layout.position(ofByte: hovered) {
            let absolute = displayOffset + hovered
            VStack(alignment: .leading, spacing: 2) {
                line("offset", String(format: "$%04X", absolute))
                line("address", String(format: "$%04X", (baseAddress + absolute) & 0xFFFF))
                line("byte", String(format: "$%02X", shown[hovered]))
                line("pixel", "\(p.x), \(p.y)")
                line("block", "\(hovered / layout.blockStride)")
            }
        } else {
            Text("Hover the bitmap")
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
        }
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .foregroundStyle(palette.color(.dim))
                .frame(width: 52, alignment: .leading)
            Text(value).foregroundStyle(palette.color(.text))
        }
        .font(.system(size: 10, design: .monospaced))
    }

    // MARK: - Export

    private func savePNG() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
            .replacingOccurrences(of: "/", with: "-")
            .appending(".png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = BitmapRenderer.shared.pngData(
            bytes: shown, layout: layout,
            foreground: NSColor(palette.color(.text)),
            background: NSColor(palette.color(.panel)))
        try? data?.write(to: url)
    }
}
