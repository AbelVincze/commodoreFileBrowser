import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Draws arbitrary data as a 1 bit per pixel image, with the block controls
/// that decide how the bytes are folded into a picture.
struct BitmapPane: View {
    let bytes: [UInt8]
    /// Address of byte 0, used by the readout. Zero in Raw, the load address in C64.
    let baseAddress: Int
    let fileName: String
    let palette: Palette
    @Binding var layout: BitmapLayout

    /// Byte under the pointer, if any.
    @State private var hovered: Int?

    private var shown: [UInt8] { Array(bytes.prefix(BitmapRenderer.byteLimit)) }
    private var image: NSImage? { BitmapRenderer.shared.image(bytes: shown, layout: layout) }

    var body: some View {
        HStack(spacing: 0) {
            canvas
            Divider().overlay(palette.color(.border))
            controls
                .frame(width: 200)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ScrollView([.vertical, .horizontal]) {
            if let image {
                let scale = CGFloat(layout.magnification)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .renderingMode(.template)
                        .frame(width: image.size.width * scale,
                               height: image.size.height * scale)
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
        if let hovered {
            let p = layout.position(ofByte: hovered)
            VStack(alignment: .leading, spacing: 2) {
                line("offset", String(format: "$%04X", hovered))
                line("address", String(format: "$%04X", (baseAddress + hovered) & 0xFFFF))
                line("byte", String(format: "$%02X", shown[hovered]))
                line("pixel", "\(p.x), \(p.y)")
                line("block", "\(Int(layout.blockRect(forByte: hovered).minX) / layout.blockWidth), "
                     + "\(Int(layout.blockRect(forByte: hovered).minY) / layout.blockHeight)")
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
