import SwiftUI
import AppKit

// Reproduces the real app's window: a SwiftUI WindowGroup, not a hand built
// NSWindow. The earlier harness made its own window and so did not exercise
// the code path where SwiftUI attaches the view to the window later.
let out = ProcessInfo.processInfo.environment["SHOT_DIR"] ?? "."
let base = URL(fileURLWithPath: "/Users/macc/dev/commodoreFileBrowser/sample_images")

let settings = SettingsStore()
settings.zoom = 2
settings.font = PETSCIIFont(rom: .c64, set: .uppercase)
settings.appearance = ProcessInfo.processInfo.environment["LIGHT"] == nil ? .dark : .light

let model = AppModel(settings: settings)

struct HarnessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, settings: settings)
                .frame(minWidth: 760, minHeight: 460)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 640)
    }
}

/// Capture an attached sheet rather than the window itself.
func captureSheet(_ name: String) {
    guard let host = NSApp.windows.first(where: { $0.attachedSheet != nil }),
          let sheet = host.attachedSheet,
          let view = sheet.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { print("no sheet"); return }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        print("wrote \(name).png  \(Int(rep.size.width))x\(Int(rep.size.height)) pt")
    }
}

func capture() {
    guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }),
          let frame = window.contentView?.superview,
          let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
    else { print("no window"); exit(1) }
    frame.cacheDisplay(in: frame.bounds, to: rep)

    let suffix = settings.appearance == .light ? "_light" : ""
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(out)/window\(suffix).png"))
    }

    // Exact geometry of the system window buttons, so the title can be
    // positioned against them instead of guessed at.
    print("window metrics:")
    for (name, kind) in [("close", NSWindow.ButtonType.closeButton),
                         ("miniaturize", .miniaturizeButton),
                         ("zoom", .zoomButton)] {
        if let b = window.standardWindowButton(kind) {
            let f = b.convert(b.bounds, to: nil)   // window coordinates
            print(String(format: "  %-12@ x %.1f..%.1f   y %.1f..%.1f (from bottom)",
                         name as NSString, f.minX, f.maxX, f.minY, f.maxY))
        }
    }
    let titleBarHeight = window.frame.height - window.contentLayoutRect.height
    print(String(format: "  window h %.1f  contentLayoutRect h %.1f  title bar %.1f pt",
                 window.frame.height, window.contentLayoutRect.height, titleBarHeight))
    if let b = window.standardWindowButton(.closeButton) {
        let f = b.convert(b.bounds, to: nil)
        let centreFromTop = window.frame.height - f.midY
        print(String(format: "  button centre is %.1f pt below the window top", centreFromTop))
    }

    let pw = rep.pixelsWide, ph = rep.pixelsHigh
    let sc = max(1, pw / Int(rep.size.width))
    func hex(_ x: Int, _ y: Int) -> String {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255),
                      Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    print("window\(suffix): \(pw)x\(ph) px @\(sc)x")
    for (label, x, y) in [("title bar, centre", pw / 2, 8 * sc),
                          ("title bar, right end", pw - 8 * sc, 8 * sc),
                          ("body, left edge", 3 * sc, 300 * sc),
                          ("between panels", pw / 2, 400 * sc),
                          ("key bar", pw / 2, ph - 3 * sc)] {
        print(String(format: "  %-22@ %@", label as NSString, hex(x, y) as NSString))
    }

    // Zoom on the title bar corner: buttons, title and the gap below.
    if let cg = rep.cgImage,
       let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: 460 * sc, height: 130 * sc)) {
        let scaled = NSImage(size: NSSize(width: 460 * sc * 2, height: 130 * sc * 2))
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.cgContext.draw(crop, in: CGRect(origin: .zero, size: scaled.size))
        scaled.unlockFocus()
        if let t = scaled.tiffRepresentation, let r = NSBitmapImageRep(data: t),
           let png = r.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(out)/titlebar\(suffix).png"))
            print("wrote titlebar\(suffix).png")
        }
    }

    // Measure the gap above the columns against the gap below them.
    guard let winBG = rep.colorAt(x: 3 * sc, y: 300 * sc)?.usingColorSpace(.sRGB),
          let panelBG = rep.colorAt(x: 500 * sc, y: 300 * sc)?.usingColorSpace(.sRGB)
    else { return }
    func rgb(_ c: NSColor) -> String {
        String(format: "#%02X%02X%02X", Int(c.redComponent * 255),
               Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
    print("gap symmetry (window \(rgb(winBG)), active panel \(rgb(panelBG))):")

    func close(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.004
            && abs(a.greenComponent - b.greenComponent) < 0.004
            && abs(a.blueComponent - b.blueComponent) < 0.004
    }
    func hasInk(_ y: Int, _ x0: Int, _ x1: Int) -> Bool {
        for x in stride(from: x0 * sc, to: x1 * sc, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.brightnessComponent - winBG.brightnessComponent > 0.15 { return true }
        }
        return false
    }

    // x = 14 pt sits inside the panel background but left of any row content,
    // so the column region is simply every row there that is not window colour.
    var panelTop = 0, panelBottom = 0
    for y in (30 * sc)..<ph {
        let differs = rep.colorAt(x: 14 * sc, y: y)
            .flatMap { $0.usingColorSpace(.sRGB) }
            .map { !close($0, winBG) } ?? false
        if differs {
            if panelTop == 0 { panelTop = y }
            panelBottom = y
        }
    }

    // Title text: top 36 pt only, so the panel header below cannot creep in.
    var titleBottom = 0
    for y in 0..<(36 * sc) where hasInk(y, 90, 300) { titleBottom = y }
    // Key bar text: bottom 60 pt, skipping the very last rows (rounded corners).
    var keyTop = ph
    for y in (panelBottom + 1)..<(ph - 2 * sc) where hasInk(y, 40, 200) {
        keyTop = min(keyTop, y)
    }

    // Where does the header end? The first listing row is the cursor row,
    // painted in the accent colour, so its top edge is unmistakable.
    var cursorRowTop = 0
    for y in (panelTop + 1)..<ph {
        if let c = rep.colorAt(x: 500 * sc, y: y)?.usingColorSpace(.sRGB),
           c.blueComponent - c.redComponent > 0.2 {
            cursorRowTop = y
            break
        }
    }
    print(String(format: "  header: panel top %.1f -> first row %.1f  = %.1f pt tall",
                 Double(panelTop) / Double(sc), Double(cursorRowTop) / Double(sc),
                 Double(cursorRowTop - panelTop) / Double(sc)))

    let topGap = Double(panelTop - titleBottom) / Double(sc)
    let bottomGap = Double(keyTop - panelBottom) / Double(sc)
    print(String(format: "  title text bottom   %6.1f pt", Double(titleBottom) / Double(sc)))
    print(String(format: "  columns top         %6.1f pt    gap above = %.1f pt", Double(panelTop) / Double(sc), topGap))
    print(String(format: "  columns bottom      %6.1f pt", Double(panelBottom) / Double(sc)))
    print(String(format: "  key bar text top    %6.1f pt    gap below = %.1f pt", Double(keyTop) / Double(sc), bottomGap))
    print(String(format: "  difference %.1f pt", abs(topGap - bottomGap)))
}

DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
    model.left.navigate(to: .directory(URL(fileURLWithPath: "/Users/macc/dev/commodoreFileBrowser")))
    model.right.navigate(to: .image(base.appendingPathComponent("cbmcmd23.d64")))
    model.activeSide = .left
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        capture()
        // Now open the viewer on a real PRG and capture the sheet.
        // A real BASIC loader off one of the sample disks.
        if let image = model.right.image,
           let entry = image.entries.first(where: { $0.displayName == "LOADCBMCMD" }),
           let data = try? image.read(entry) {
            model.sheet = .viewer(ViewerContent(title: entry.displayName, data: data,
                                                isPRG: true, startInBitmap: false))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            captureSheet("basic")
            exit(0)
        }
    }
}

HarnessApp.main()
