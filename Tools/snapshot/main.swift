import SwiftUI
import AppKit

// Renders the real panel and key bar views offscreen for design review.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let out = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? "."
let base = URL(fileURLWithPath: "/Users/macc/dev/commodoreFileBrowser/sample_images")

@MainActor
func shoot<V: View>(_ view: V, _ name: String) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { print("render failed: \(name)"); return }
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    print("wrote \(name).png \(Int(image.size.width))x\(Int(image.size.height))")
}

MainActor.assumeIsolated {
    let settings = SettingsStore()
    settings.zoom = 2
    settings.font = PETSCIIFont(rom: .c64, set: .uppercase)

    let left = PanelModel(side: .left)
    left.navigate(to: .directory(URL(fileURLWithPath: "/Users/macc/dev/commodoreFileBrowser")))
    left.cursor = 3

    let right = PanelModel(side: .right)
    right.navigate(to: .image(base.appendingPathComponent("cbmcmd23.d64")))
    right.cursor = 4
    // Make the image look edited so the MODIFIED flag shows in the header.
    if let image = right.image, let first = image.entries.first {
        try? image.rename(first, to: PETSCII.cbmName(fromASCII: "AD ASTRA    /GP"))
        right.refreshImage()
    }
    right.marked = [6]

    func rows(_ panel: PanelModel, _ palette: Palette, active: Bool, petscii: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(panel.items.prefix(16)) { item in
                PanelRow(item: item, isCursor: item.id == panel.cursor, isActive: active,
                         isMarked: panel.marked.contains(item.id), palette: palette,
                         settings: settings, usePETSCII: petscii)
            }
        }
    }

    // PanelView's listing is lazy and will not materialise in ImageRenderer,
    // so the chrome and the rows are composed separately here.
    func column(_ panel: PanelModel, _ palette: Palette, active: Bool, petscii: Bool) -> some View {
        ZStack(alignment: .top) {
            PanelView(panel: panel, settings: settings, palette: palette, isActive: active,
                      status: active ? "Copied 2 items" : "",
                      onActivate: {}, onOpen: {})
            VStack(spacing: 0) {
                Color.clear.frame(height: 66)
                rows(panel, palette, active: active, petscii: petscii)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 520)
        .clipped()
    }

    @MainActor func window(_ palette: Palette, _ scheme: ColorScheme, _ name: String) {
        let view = VStack(spacing: 0) {
            HStack(spacing: 8) {
                column(left, palette, active: false, petscii: false)
                column(right, palette, active: true, petscii: true)
            }
            .padding(8)
            FunctionBar(palette: palette, keys: [
                ("F1", "Help"), ("F2", "Image"), ("F3", "View"), ("F4", "Header"),
                ("F5", "Copy"), ("F6", "Move"), ("F7", "MkDir"), ("F8", "Delete"),
                ("F9", "Rename"), ("F10", "Quit")
            ].map { FunctionKey(key: $0.0, label: $0.1) {} })
        }
        .frame(width: 1100, height: 620)
        .background(palette.color(.window))
        .environment(\.colorScheme, scheme)
        shoot(view, name)
    }

    window(settings.dark, .dark, "main_dark")
    window(settings.light, .light, "main_light")
}
