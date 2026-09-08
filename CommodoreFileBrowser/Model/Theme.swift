import SwiftUI

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

/// Every colour the browser draws with. Stored as hex so it round trips
/// through user defaults and can be shared as a preset.
struct Palette: Codable, Equatable {
    var window: String
    var panel: String
    var text: String
    var dim: String
    var directory: String
    var image: String
    var cursorBackground: String
    var cursorText: String
    var marked: String
    var header: String
    var border: String
    var accent: String
    /// The big FS / D64 type marker in the panel header.
    var marker: String

    /// Decoded leniently so a settings file written before a colour role
    /// existed still loads, rather than resetting the whole theme.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window = try c.decode(String.self, forKey: .window)
        panel = try c.decode(String.self, forKey: .panel)
        text = try c.decode(String.self, forKey: .text)
        dim = try c.decode(String.self, forKey: .dim)
        directory = try c.decode(String.self, forKey: .directory)
        image = try c.decode(String.self, forKey: .image)
        cursorBackground = try c.decode(String.self, forKey: .cursorBackground)
        cursorText = try c.decode(String.self, forKey: .cursorText)
        marked = try c.decode(String.self, forKey: .marked)
        header = try c.decode(String.self, forKey: .header)
        border = try c.decode(String.self, forKey: .border)
        accent = try c.decode(String.self, forKey: .accent)
        marker = try c.decodeIfPresent(String.self, forKey: .marker) ?? marked
    }

    init(window: String, panel: String, text: String, dim: String, directory: String,
         image: String, cursorBackground: String, cursorText: String, marked: String,
         header: String, border: String, accent: String, marker: String) {
        self.window = window; self.panel = panel; self.text = text; self.dim = dim
        self.directory = directory; self.image = image
        self.cursorBackground = cursorBackground; self.cursorText = cursorText
        self.marked = marked; self.header = header; self.border = border
        self.accent = accent; self.marker = marker
    }

    enum Field: String, CaseIterable, Identifiable {
        case window = "Window"
        case panel = "Panel"
        case text = "File name"
        case dim = "Secondary text"
        case directory = "Folder"
        case image = "Disk image"
        case cursorBackground = "Cursor"
        case cursorText = "Cursor text"
        case marked = "Marked file"
        case header = "Header"
        case border = "Border"
        case accent = "Accent"
        case marker = "Type marker"
        var id: String { rawValue }
    }

    subscript(field: Field) -> String {
        get {
            switch field {
            case .window: return window
            case .panel: return panel
            case .text: return text
            case .dim: return dim
            case .directory: return directory
            case .image: return image
            case .cursorBackground: return cursorBackground
            case .cursorText: return cursorText
            case .marked: return marked
            case .header: return header
            case .border: return border
            case .accent: return accent
            case .marker: return marker
            }
        }
        set {
            switch field {
            case .window: window = newValue
            case .panel: panel = newValue
            case .text: text = newValue
            case .dim: dim = newValue
            case .directory: directory = newValue
            case .image: image = newValue
            case .cursorBackground: cursorBackground = newValue
            case .cursorText: cursorText = newValue
            case .marked: marked = newValue
            case .header: header = newValue
            case .border: border = newValue
            case .accent: accent = newValue
            case .marker: marker = newValue
            }
        }
    }

    func color(_ field: Field) -> Color { Color(hex: self[field]) ?? .gray }
}

struct ThemePreset: Identifiable {
    let id: String
    let name: String
    let light: Palette
    let dark: Palette
}

enum ThemePresets {
    static let standardLight = Palette(
        window: "#F2F2F5", panel: "#FFFFFF", text: "#1D1D1F", dim: "#86868B",
        directory: "#0B63CE", image: "#7A44C8", cursorBackground: "#0B63CE",
        cursorText: "#FFFFFF", marked: "#C2410C", header: "#6E6E73",
        border: "#D8D8DE", accent: "#0B63CE", marker: "#B87400")

    static let standardDark = Palette(
        window: "#161618", panel: "#1D1D20", text: "#E6E6EB", dim: "#8A8A90",
        directory: "#6FA8FF", image: "#C39BFF", cursorBackground: "#2F6FED",
        cursorText: "#FFFFFF", marked: "#FFB454", header: "#98989D",
        border: "#303036", accent: "#4C8DFF", marker: "#E0A33C")

    static let all: [ThemePreset] = [
        ThemePreset(id: "standard", name: "Standard", light: standardLight, dark: standardDark),
        ThemePreset(id: "graphite", name: "Graphite",
                    light: Palette(window: "#EDEDED", panel: "#FBFBFB", text: "#222222", dim: "#777777",
                                   directory: "#333333", image: "#555555", cursorBackground: "#333333",
                                   cursorText: "#FFFFFF", marked: "#A83232", header: "#666666",
                                   border: "#D4D4D4", accent: "#444444", marker: "#767676"),
                    dark: Palette(window: "#141414", panel: "#1B1B1B", text: "#DEDEDE", dim: "#828282",
                                  directory: "#CFCFCF", image: "#A8A8A8", cursorBackground: "#3A3A3A",
                                  cursorText: "#FFFFFF", marked: "#E0733F", header: "#909090",
                                  border: "#2B2B2B", accent: "#9A9A9A", marker: "#8A8A8A")),
        ThemePreset(id: "c64", name: "Commodore 64",
                    light: Palette(window: "#7C70DA", panel: "#40318D", text: "#B8B0FF", dim: "#8A80E0",
                                   directory: "#7C70DA", image: "#BFCE72", cursorBackground: "#B8B0FF",
                                   cursorText: "#40318D", marked: "#BFCE72", header: "#B8B0FF",
                                   border: "#5A4EB8", accent: "#B8B0FF", marker: "#BFCE72"),
                    dark: Palette(window: "#352A7A", panel: "#40318D", text: "#B8B0FF", dim: "#8A80E0",
                                  directory: "#7C70DA", image: "#BFCE72", cursorBackground: "#B8B0FF",
                                  cursorText: "#40318D", marked: "#BFCE72", header: "#B8B0FF",
                                  border: "#5A4EB8", accent: "#B8B0FF", marker: "#BFCE72")),
        ThemePreset(id: "amber", name: "Amber Terminal",
                    light: Palette(window: "#F5EFE0", panel: "#FFFAF0", text: "#3A2E1A", dim: "#8A7A5C",
                                   directory: "#9A6B00", image: "#7A4B00", cursorBackground: "#9A6B00",
                                   cursorText: "#FFFAF0", marked: "#B03A00", header: "#7A6A4C",
                                   border: "#E0D6C0", accent: "#9A6B00", marker: "#9A6B00"),
                    dark: Palette(window: "#14100A", panel: "#1B1610", text: "#FFB000", dim: "#A07000",
                                  directory: "#FFCE55", image: "#FF8C42", cursorBackground: "#8A5E00",
                                  cursorText: "#FFE9B0", marked: "#FF6B35", header: "#B08000",
                                  border: "#2E2416", accent: "#FFB000", marker: "#FFB000"))
    ]
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class SettingsStore: ObservableObject {

    @Published var appearance: AppearanceMode { didSet { save() } }
    @Published var light: Palette { didSet { save() } }
    @Published var dark: Palette { didSet { save() } }
    /// Character cell size for PETSCII rows, in whole pixels per C64 pixel.
    /// Fixed rather than a setting: the panels are laid out around it.
    let zoom = 2
    @Published var font: PETSCIIFont { didSet { save() } }
    @Published var showHiddenFiles: Bool { didSet { save() } }
    /// Deleting host files puts them in the Trash rather than erasing them.
    @Published var deleteToTrash: Bool { didSet { save() } }
    /// Copying out of a Commodore image adds the file type as an extension.
    /// Remembered from the copy sheet, since it is a habit rather than a
    /// per-file decision.
    @Published var addHostExtension: Bool { didSet { save() } }
    /// Where the divider between the two panels sits, as a fraction of the width.
    @Published var splitFraction: Double { didSet { save() } }
    /// Bitmap viewer display preferences. The block geometry is inferred per
    /// file instead, since it depends on what the file actually is.
    @Published var bitmapMagnification: Int { didSet { save() } }
    @Published var bitmapInvert: Bool { didSet { save() } }
    /// Whether the viewer reads the first two bytes as a load address.
    @Published var viewerUsesC64Offsets: Bool { didSet { save() } }
    /// SID player preferences, carried from one tune to the next.
    @Published var sidModel: Int { didSet { save() } }
    @Published var scopeEnabled: Bool { didSet { save() } }
    /// Stored as the raw value so the settings store stays clear of the views.
    @Published var scopeMode: String { didSet { save() } }
    /// The module scope has its own two modes, so it needs its own setting.
    @Published var moduleScopeMode: String { didSet { save() } }
    @Published var sidVolume: Double { didSet { save() } }
    /// Video export choices, stored as raw values for the same reason.
    @Published var exportResolution: String { didSet { save() } }
    @Published var exportAspect: String { didSet { save() } }
    @Published var exportSeconds: Double { didSet { save() } }

    private struct Stored: Codable {
        var appearance: AppearanceMode
        var light: Palette
        var dark: Palette
        var charSet: CharacterROM.CharSet?   // pre-ROM-picker settings
        var font: PETSCIIFont?
        var showHiddenFiles: Bool
        var deleteToTrash: Bool?
        var addHostExtension: Bool?
        var splitFraction: Double?
        var bitmapMagnification: Int?
        var bitmapInvert: Bool?
        var viewerUsesC64Offsets: Bool?
        var sidModel: Int?
        var scopeEnabled: Bool?
        var scopeMode: String?
        var moduleScopeMode: String?
        var sidVolume: Double?
        var exportResolution: String?
        var exportAspect: String?
        var exportSeconds: Double?
    }

    private static let key = "theme.v1"
    private var loading = true

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        appearance = stored?.appearance ?? .system
        light = stored?.light ?? ThemePresets.standardLight
        dark = stored?.dark ?? ThemePresets.standardDark
        // Carry an older settings file over to the new font field.
        font = stored?.font ?? PETSCIIFont(rom: .c64, set: stored?.charSet ?? .uppercase)
        showHiddenFiles = stored?.showHiddenFiles ?? false
        deleteToTrash = stored?.deleteToTrash ?? true
        addHostExtension = stored?.addHostExtension ?? true
        splitFraction = stored?.splitFraction ?? 0.5
        bitmapMagnification = stored?.bitmapMagnification ?? 2
        bitmapInvert = stored?.bitmapInvert ?? false
        viewerUsesC64Offsets = stored?.viewerUsesC64Offsets ?? true
        sidModel = stored?.sidModel ?? 8580
        scopeEnabled = stored?.scopeEnabled ?? false
        scopeMode = stored?.scopeMode ?? "voices"
        moduleScopeMode = stored?.moduleScopeMode ?? ModuleScopeMode.mix.rawValue
        sidVolume = stored?.sidVolume ?? 1
        exportResolution = stored?.exportResolution ?? VideoResolution.p720.rawValue
        exportAspect = stored?.exportAspect ?? VideoAspect.sixteenNine.rawValue
        exportSeconds = stored?.exportSeconds ?? 30
        loading = false
    }

    private func save() {
        guard !loading else { return }
        let stored = Stored(appearance: appearance, light: light, dark: dark,
                            charSet: nil, font: font, showHiddenFiles: showHiddenFiles,
                            deleteToTrash: deleteToTrash, addHostExtension: addHostExtension,
                            splitFraction: splitFraction,
                            bitmapMagnification: bitmapMagnification, bitmapInvert: bitmapInvert,
                            viewerUsesC64Offsets: viewerUsesC64Offsets,
                            sidModel: sidModel, scopeEnabled: scopeEnabled, scopeMode: scopeMode,
                            moduleScopeMode: moduleScopeMode,
                            sidVolume: sidVolume, exportResolution: exportResolution,
                            exportAspect: exportAspect, exportSeconds: exportSeconds)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func apply(_ preset: ThemePreset) {
        light = preset.light
        dark = preset.dark
    }

    func palette(for scheme: ColorScheme) -> Palette {
        (appearance.colorScheme ?? scheme) == .dark ? dark : light
    }

    /// Row height in points, shared by both panel styles so the two sides line up.
    var rowHeight: CGFloat { max(18, CGFloat(8 * zoom) + 4) }
}
