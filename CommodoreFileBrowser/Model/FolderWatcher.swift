import Foundation
import CoreServices

/// Watches one folder for changes made outside the app: a file written in the
/// Finder, a folder renamed from a shell, the folder we are standing in thrown
/// away while we stand in it.
///
/// FSEvents rather than a dispatch source on an open descriptor: a descriptor
/// held open on a directory keeps its volume busy, and a file browser is the
/// last program that should be the reason a disk refuses to eject.
///
/// The watcher reports that something happened at or inside the folder and
/// nothing more. What it means — reread the listing, or walk out because the
/// folder is gone — is for the panel to work out, since only it knows what it
/// is showing.
final class FolderWatcher {

    private var stream: FSEventStreamRef?
    /// The folder being watched, and the same folder as the file system spells
    /// it back to us. Events arrive fully resolved — `/private/var/…` for a
    /// path handed in as `/var/…` — so both spellings are kept and compared
    /// against.
    private var roots: [String] = []
    private var path: String?
    private var handler: (() -> Void)?
    private let queue = DispatchQueue(label: "FolderWatcher")

    /// Long enough that a folder being written to in bulk arrives as one
    /// event rather than as a hundred, short enough to feel immediate.
    private let latency: CFTimeInterval = 0.3

    deinit { stop() }

    /// Point the watcher at a folder, or at nothing. Re-pointing it at the
    /// folder it is already on leaves the stream running.
    func watch(_ url: URL?, onChange: @escaping () -> Void) {
        handler = onChange
        let wanted = url?.standardizedFileURL.path
        guard wanted != path else { return }
        stop()
        guard let wanted else { return }

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(nil, folderWatcherCallback, &context,
                                               [wanted] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, FSEventStreamCreateFlags(flags))
        else { return }
        path = wanted
        roots = Array(Set([wanted, Self.canonical(wanted)]))
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        path = nil
        roots = []
    }

    /// The path with every symbolic link along it resolved, which is the form
    /// FSEvents reports in. `URL.resolvingSymlinksInPath` is not enough: it
    /// leaves `/var` alone, and the temporary folder lives under it.
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Called off the main thread, once per batch of coalesced events.
    fileprivate func report(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard concerns(paths: paths, flags: flags) else { return }
        DispatchQueue.main.async { [weak self] in self?.handler?() }
    }

    /// FSEvents watches a whole subtree, and only the folder itself and what
    /// sits directly in it can change the listing on screen. A file three
    /// levels down — a build writing into a folder we happen to be above —
    /// is not worth a reread.
    private func concerns(paths: [String], flags: [FSEventStreamEventFlags]) -> Bool {
        let wholesale = kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount
        for (event, flag) in zip(paths, flags) {
            if Int(flag) & wholesale != 0 { return true }
            if roots.contains(event) { return true }
            if roots.contains((event as NSString).deletingLastPathComponent) { return true }
        }
        return false
    }
}

/// Free function because a C callback cannot close over anything: the watcher
/// comes back through the stream's context instead.
private let folderWatcherCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    watcher.report(paths: paths, flags: (0..<count).map { flags[$0] })
}
