import SwiftUI
import AppKit

/// The viewer's Image mode: a picture drawn in its own colours.
///
/// The only pane in the browser that does not tint a template with a palette
/// role. Everything else here is two colours by design; an Amiga picture
/// brought its own thirty-two and a C64 one the VIC-II's sixteen, and the
/// point of showing either is to see them.
struct PicturePane: View {
    let bytes: [UInt8]
    let fileName: String
    let palette: Palette
    @Binding var zoom: Int
    @Binding var correctAspect: Bool

    /// Decoding is kept in state rather than computed from `body`, which is
    /// re-evaluated on every zoom step; unpacking a 640x400 body each time
    /// would make the stepper crawl.
    @State private var decoded: DecodedPicture?
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 0) {
            canvas
            Divider().overlay(palette.color(.border))
            controls.frame(width: 200)
        }
        // The pane is torn down whenever the viewer switches modes, so this
        // runs again on the way back rather than only once per file.
        .onAppear(perform: rebuild)
        .onChange(of: bytes.count) { _, _ in rebuild() }
    }

    private func rebuild() {
        do {
            decoded = try PictureLoader.decode(name: fileName, bytes: bytes)
            failure = nil
        } catch {
            decoded = nil
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ScrollView([.vertical, .horizontal]) {
            if let decoded {
                let scale = CGFloat(zoom)
                Image(nsImage: PixelImage.image(decoded.image))
                    .resizable()
                    .interpolation(.none)
                    .frame(width: CGFloat(decoded.width) * scale,
                           height: CGFloat(decoded.height) * scale
                                 * (correctAspect ? decoded.heightScale : 1))
                    .padding(12)
            } else {
                VStack(spacing: 6) {
                    Text(failure ?? "Nothing to show")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.color(.dim))
                    Text("Hex and Bitmap still show what is in the file.")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.color(.dim))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.color(.panel))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Picture")
                    if let decoded {
                        readout("Format", decoded.format)
                        readout("Size", "\(decoded.width) × \(decoded.height)")
                        ForEach(Array(decoded.mode.components(separatedBy: " · ").enumerated()),
                                id: \.offset) { _, part in
                            readout("", part)
                        }
                        readout("Pixel", decoded.heightScale == 1
                                ? "square"
                                : String(format: "1 : %.2f", decoded.heightScale))
                    } else {
                        readout("Size", "—")
                    }

                    Divider().overlay(palette.color(.border))
                    section("Display")
                    Stepper(value: $zoom, in: 1...16) {
                        Text("Zoom \(zoom)x")
                            .font(.system(size: 11))
                            .fixedSize()
                    }
                    .fixedSize()
                    Toggle("Correct aspect", isOn: $correctAspect)
                        .font(.system(size: 11))
                        .fixedSize()
                        .help("Neither machine had square pixels. On, the picture is "
                              + "the shape it was drawn as — the aspect an IFF records, "
                              + "or the PAL ratio a C64 picture does not. Off, one pixel "
                              + "is one pixel.")
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(palette.color(.border))
            Button("Save as PNG…", action: savePNG)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(decoded == nil)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.color(.window))
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(palette.color(.dim))
    }

    private func readout(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.color(.dim))
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.color(.text))
                .lineLimit(1)
        }
    }

    /// The picture as it is, one image pixel per picture pixel: the zoom and
    /// the aspect correction are how it is being looked at, not what it is.
    private func savePNG() {
        guard let decoded else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
            .replacingOccurrences(of: "/", with: "-")
            .appending(".png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PixelImage.pngData(decoded.image)?.write(to: url)
    }
}
