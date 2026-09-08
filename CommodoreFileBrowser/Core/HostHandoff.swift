import Foundation

/// Getting a file out of a disk image and somewhere the system can reach it.
///
/// A CBM entry is not a file: it is a chain of sectors inside a container. To
/// hand one to another application it has to be written out first, and what
/// gets written is a copy — nothing an editor does to it comes back into the
/// image. The copies are written read-only so that stays visible: an editor
/// says the file is locked rather than saving into a folder nobody will read
/// again.
enum HostHandoff {

    /// Copies live under one folder per image, so two disks holding a file of
    /// the same name do not overwrite each other's copy.
    static func temporaryFolder(for container: URL?) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommodoreFileBrowser", isDirectory: true)
        guard let container else { return root }
        return root.appendingPathComponent(container.deletingPathExtension().lastPathComponent,
                                           isDirectory: true)
    }

    /// Write `data` as `name` in `folder`, replacing any copy already there.
    ///
    /// Replacing rather than adding matters: opening the same entry twice in a
    /// session should hand the application the same path, so it reloads what is
    /// in front of it instead of collecting numbered duplicates.
    ///
    /// `readOnly` is what makes a copy handed to an editor say so. A copy being
    /// dragged somewhere asks for it off: that file is the one the user is
    /// putting down, not a look at one, and it should land writable.
    @discardableResult
    static func write(_ data: Data, named name: String, in folder: URL,
                      readOnly: Bool = true) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = folder.appendingPathComponent(safeName(name))
        // An earlier copy may be read-only, so it cannot simply be written over.
        if manager.fileExists(atPath: url.path) {
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            try manager.removeItem(at: url)
        }
        try data.write(to: url)
        try? manager.setAttributes([.posixPermissions: readOnly ? 0o444 : 0o644],
                                   ofItemAtPath: url.path)
        return url
    }

    /// A CBM name can hold characters a path cannot. `/` is the only one the
    /// file system truly forbids, and a leading dot would hide the copy.
    static func safeName(_ name: String) -> String {
        var out = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if out.hasPrefix(".") { out = "_" + out.dropFirst() }
        return out.isEmpty ? "unnamed" : out
    }
}
