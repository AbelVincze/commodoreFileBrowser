import AppKit
import UniformTypeIdentifiers

/// Everything the browser asks the system to do with a file, in one place.
///
/// The app is not sandboxed, so none of this needs a permission the user has to
/// grant first: a path is enough.
enum HostOpener {

    /// Open with whatever the system would use for a double click in Finder.
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Open with a named application instead of the default one.
    static func open(_ url: URL, with application: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Show it in Finder, selected in its enclosing folder.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Applications that will open this file, the default one first.
    static func applications(for url: URL) -> [URL] {
        ordered(NSWorkspace.shared.urlsForApplications(toOpen: url),
                default: NSWorkspace.shared.urlForApplication(toOpen: url))
    }

    /// The same list for a file that does not exist yet — an entry still inside
    /// an image, whose candidates have to come from its name alone. Building
    /// the menu must not be what writes the copy out.
    static func applications(forExtension ext: String) -> [URL] {
        guard let type = UTType(filenameExtension: ext.lowercased()) else { return [] }
        return ordered(NSWorkspace.shared.urlsForApplications(toOpen: type),
                       default: NSWorkspace.shared.urlForApplication(toOpen: type))
    }

    /// The list as the menu shows it: the default application first, then the
    /// rest by name, and nothing listed twice.
    private static func ordered(_ applications: [URL], default preferred: URL?) -> [URL] {
        var rest = applications.filter { $0 != preferred }
        rest.sort { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
        return (preferred.map { [$0] } ?? []) + rest
    }

    /// Pick an application by hand. AppKit has no public "Open With" panel, so
    /// this is an open panel that will only take an application.
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The name Finder shows. `displayName(atPath:)` keeps the `.app` on the
    /// end here, which reads badly in a menu, so the bundle is asked first.
    static func name(of application: URL) -> String {
        let bundle = Bundle(url: application)
        let info = bundle?.localizedInfoDictionary ?? bundle?.infoDictionary
        if let name = (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String,
           !name.isEmpty {
            return name
        }
        return application.deletingPathExtension().lastPathComponent
    }

    static func icon(of application: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: application.path)
    }
}
