import SwiftUI

/// A run of C64 screen codes drawn from the character ROM, tinted with a
/// theme colour and scaled by whole pixels so it stays sharp.
struct PETSCIIText: View {
    let codes: [UInt8]
    let color: Color
    let zoom: Int
    let font: PETSCIIFont
    /// Draw the run in reverse video, the way a directory header prints.
    var reverse: Bool = false

    private var screenCodes: [UInt8] {
        reverse ? codes.map { $0 | 0x80 } : codes
    }

    var body: some View {
        if let image = PETSCIIRenderer.shared.image(codes: screenCodes, font: font) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .renderingMode(.template)
                .frame(width: CGFloat(codes.count * CharacterROM.glyphWidth * zoom),
                       height: CGFloat(CharacterROM.glyphHeight * zoom))
                .foregroundStyle(color)
        }
    }
}

/// Convenience for drawing PETSCII bytes (as stored on disk) rather than
/// screen codes.
extension PETSCIIText {
    init(petscii bytes: [UInt8], color: Color, zoom: Int, font: PETSCIIFont, reverse: Bool = false) {
        self.init(codes: PETSCII.screenCodes(bytes), color: color, zoom: zoom,
                  font: font, reverse: reverse)
    }
}
