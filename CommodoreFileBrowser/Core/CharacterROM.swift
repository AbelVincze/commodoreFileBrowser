import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif

/// Which machine's character generator to draw with.
enum CharacterROMVariant: String, CaseIterable, Identifiable, Codable {
    case c64
    case pet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .c64: return "Commodore 64"
        case .pet: return "PET"
        }
    }

    /// Base name of the bundled 4 KB ROM.
    var resourceName: String {
        switch self {
        case .c64: return "character"
        case .pet: return "pet"
        }
    }
}

/// A character generator ROM: 2 x 256 glyphs of 8x8 pixels. Set 0 is upper
/// case / graphics, set 1 is lower case / upper case, and within each set the
/// glyphs $80-$FF are the inverted (reverse video) forms.
///
/// The C64 ROM ships in that layout already. The 2 KB PET generator does not
/// carry reverse video forms, so `Tools/expand-rom.py` builds them by
/// inverting every byte; both ROMs are then indexed identically.
final class CharacterROM {

    static let shared = CharacterROM()

    enum CharSet: Int, CaseIterable, Identifiable, Codable {
        case uppercase = 0
        case lowercase = 1
        var id: Int { rawValue }
        var label: String { self == .uppercase ? "Upper case / graphics" : "Lower case / upper case" }
    }

    static let glyphWidth = 8
    static let glyphHeight = 8

    private var roms: [CharacterROMVariant: [UInt8]] = [:]
    private let lock = NSLock()

    private init() {}

    private func rom(_ variant: CharacterROMVariant) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let loaded = roms[variant] { return loaded }

        // Bundled resource first; the fallbacks let command line tools that
        // reuse this code find the ROM as well.
        let name = variant.resourceName
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "rom"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(name).rom"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("CommodoreFileBrowser/Resources/\(name).rom"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("\(name).rom")
        ].compactMap { $0 }

        var loaded = [UInt8](repeating: 0, count: 4096)
        for url in candidates {
            if let data = try? Data(contentsOf: url), data.count >= 4096 {
                loaded = [UInt8](data)
                break
            }
        }
        roms[variant] = loaded
        return loaded
    }

    /// The 8 row bytes of one glyph.
    func rows(screenCode: UInt8, font: PETSCIIFont) -> ArraySlice<UInt8> {
        let bytes = rom(font.rom)
        let base = font.set.rawValue * 2048 + Int(screenCode) * 8
        guard base + 8 <= bytes.count else { return bytes[0..<8] }
        return bytes[base..<(base + 8)]
    }
}

/// A ROM plus the half of it currently in use - everything needed to pick a glyph.
struct PETSCIIFont: Codable, Equatable, Hashable {
    var rom: CharacterROMVariant = .c64
    var set: CharacterROM.CharSet = .uppercase

    static let `default` = PETSCIIFont()
}

/// Renders runs of screen codes into template images that the UI tints with the
/// current theme colour. Images are 1 device pixel per C64 pixel; the views
/// draw them with nearest-neighbour interpolation so they stay crisp.
final class PETSCIIRenderer {

    static let shared = PETSCIIRenderer()

    private struct Key: Hashable {
        let codes: [UInt8]
        let font: PETSCIIFont
    }

    private var cache: [Key: NSImage] = [:]
    private let lock = NSLock()

    /// Point size of one character cell at the given zoom step.
    static func cellSize(zoom: Int) -> CGSize {
        CGSize(width: CGFloat(CharacterROM.glyphWidth * zoom),
               height: CGFloat(CharacterROM.glyphHeight * zoom))
    }

    func image(codes: [UInt8], font: PETSCIIFont) -> NSImage? {
        guard !codes.isEmpty else { return nil }
        let key = Key(codes: codes, font: font)

        lock.lock()
        let cached = cache[key]
        lock.unlock()

        if let cached { return cached }
        guard let made = render(codes: codes, font: font) else { return nil }
        lock.lock()
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = made
        lock.unlock()
        return made
    }

    private func render(codes: [UInt8], font: PETSCIIFont) -> NSImage? {
        let w = codes.count * CharacterROM.glyphWidth
        let h = CharacterROM.glyphHeight
        var pixels = [UInt8](repeating: 0, count: w * h * 4)

        for (index, code) in codes.enumerated() {
            let rows = CharacterROM.shared.rows(screenCode: code, font: font)
            for (y, byte) in rows.enumerated() {
                for bit in 0..<8 where (byte & (0x80 >> UInt8(bit))) != 0 {
                    let x = index * CharacterROM.glyphWidth + bit
                    let o = (y * w + x) * 4
                    pixels[o] = 255; pixels[o + 1] = 255; pixels[o + 2] = 255; pixels[o + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent)
        else { return nil }

        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: w, height: h)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}
