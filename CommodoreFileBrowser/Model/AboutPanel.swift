import AppKit

/// What the About window says beyond the name and version macOS fills in.
///
/// The standard panel is kept rather than replaced with a window of our own:
/// it already knows the app's name, version and icon, and it is the shape
/// people expect from the menu. Only the credits block below the version is
/// ours, and it is an attributed string because the address at the end should
/// be clickable.
enum AboutPanel {

    private static let summary = """
        A two-panel file manager that opens Commodore and Amiga disk images as \
        folders. Copy files in and out of them, edit a directory, and play the \
        SID tunes and tracker modules you find inside.
        """

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

        text.append(NSAttributedString(string: summary + "\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centred,
        ]))

        text.append(NSAttributedString(string: credit + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centred,
        ]))

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
