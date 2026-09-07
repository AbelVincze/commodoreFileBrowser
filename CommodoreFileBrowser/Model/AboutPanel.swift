import AppKit

/// What the About window says beyond the name and version macOS fills in.
///
/// The standard panel is kept rather than replaced with a window of our own:
/// it already knows the app's name, version and icon, and it is the shape
/// people expect from the menu. Only the credits block below the version is
/// ours, and it is an attributed string because the address at the end should
/// be clickable.
///
/// The engine credits are not a courtesy. c-flod is CC BY-NC-SA, whose
/// attribution term asks for exactly this, and libopenmpt is BSD, which asks
/// for its notice to travel with the binary.
enum AboutPanel {

    private static let summary = """
        A two-panel file manager that opens Commodore and Amiga disk images as \
        folders. Copy files in and out of them, edit a directory, and play the \
        SID tunes and tracker modules you find inside.
        """

    /// Kept short enough to sit on one line at the width the panel gives the
    /// credits; the last one breaks where it is told to rather than wherever
    /// it happens to run out of room.
    private static let engines = [
        "SID — cSID-light by Hermit (Mihaly Horvath)",
        "Modules — libopenmpt by the OpenMPT project",
        "Amiga chiptunes — c-flod by rofl0r,\nafter Flod by Christian Corti",
    ]

    private static let credit = "By Abel Vincze 2026 (C)"
    private static let siteText = "https://iparigrafika.hu/retrocomputing"
    private static let site = URL(string: "https://iparigrafika.hu/retrocomputing")!

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Not private so it can be laid out and checked on its own.
    static func credits() -> NSAttributedString {
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        centred.lineSpacing = 2

        let text = NSMutableAttributedString()
        func add(_ string: String, size: CGFloat, colour: NSColor) {
            text.append(NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: colour,
                .paragraphStyle: centred,
            ]))
        }

        add(summary + "\n\n", size: 11, colour: .labelColor)

        for engine in engines {
            add(engine + "\n", size: 10, colour: .secondaryLabelColor)
        }
        add("\n", size: 10, colour: .secondaryLabelColor)

        add(credit + "\n", size: 10, colour: .secondaryLabelColor)

        // The link carries its own colour and underline: the panel does not
        // style links itself, so without these it reads as plain grey text.
        text.append(NSAttributedString(string: siteText, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .link: site,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: centred,
        ]))

        return text
    }
}
