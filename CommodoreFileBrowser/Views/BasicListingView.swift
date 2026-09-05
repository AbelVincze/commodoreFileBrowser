import SwiftUI

/// Lists a tokenised BASIC program in the Commodore character set, the way the
/// machine itself would print it.
struct BasicPane: View {
    /// The whole file, load address included.
    let bytes: [UInt8]
    let palette: Palette
    @ObservedObject var settings: SettingsStore

    @State private var lines: [CommodoreBASIC.Line] = []

    /// One step down from the panel size, matching the PETSCII column of the
    /// hex dump so the two modes read at the same scale.
    private var glyphZoom: Int { max(1, settings.zoom - 1) }

    var body: some View {
        Group {
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Text("No BASIC program here")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.color(.text))
                    Text("The file does not start with a tokenised BASIC line.")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.color(.dim))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // A ScrollView centres content smaller than itself, which puts
                // a listing in the middle of the pane and wastes the width the
                // long lines need. Make the content at least fill the viewport
                // and pin it to the top left.
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                PETSCIIText(petscii: line.petscii,
                                            color: palette.color(.text),
                                            zoom: glyphZoom,
                                            font: settings.font)
                            }
                        }
                        .padding(12)
                        .frame(minWidth: geometry.size.width,
                               minHeight: geometry.size.height,
                               alignment: .topLeading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.color(.panel))
        .onAppear { lines = CommodoreBASIC.listing(bytes) }
        .onChange(of: bytes.count) { _, _ in lines = CommodoreBASIC.listing(bytes) }
    }
}
