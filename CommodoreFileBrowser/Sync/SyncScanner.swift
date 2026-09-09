import Foundation
import CryptoKit

/// Reading a folder tree and taking the hash of everything in it.
///
/// Two passes on purpose. The first walks and only stats, which is cheap and
/// gives the second an honest denominator to show a progress bar against; the
/// second hashes, skipping whatever the baseline already vouches for.
enum SyncScanner {

    /// A megabyte at a time. Not `Data(contentsOf:)` — a hardfile is hundreds
    /// of megabytes and every other read in this app is whole-file, which is
    /// exactly what must not happen here. Not `.mappedIfSafe` either: a mapped
    /// read that faults on a volume that has gone away is a crash where a
    /// thrown error is wanted.
    static let chunk = 1 << 20

    /// How far apart two modification dates may be and still count as the same
    /// file.
    ///
    /// One second, because file systems with whole-second stamps are still in
    /// use. Not a hair wider: a wider window makes a false *match* likelier,
    /// and a false match is the direction that loses data. What it costs is a
    /// file edited within the same second and back to the same length, which is
    /// what the sheet's "hash every file" button is for.
    static let dateTolerance = 1.0

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey,
        .fileSizeKey, .contentModificationDateKey,
    ]

    // MARK: - The walk

    /// Everything under `root`, hashed.
    ///
    /// `baseline` is consulted only to skip work: an entry whose size and date
    /// still match is taken at its recorded hash rather than read again. Since
    /// a copy carries its modification date with it, the run after a sync opens
    /// no files at all.
    static func scan(root: URL, includeHidden: Bool,
                     baseline: [String: SyncEntry],
                     hashEverything: Bool = false,
                     cancel: SyncCancel,
                     progress: ((SyncProgress) -> Void)? = nil) throws -> SyncScan {
        var scan = SyncScan(root: root)
        var pending: [(url: URL, entry: SyncEntry)] = []
        var total: Int64 = 0

        try walk(root, at: [], includeHidden: includeHidden, cancel: cancel,
                 scan: &scan, pending: &pending, total: &total, progress: progress)

        progress?(SyncProgress(phase: .hashing, done: 0, total: total))
        var done: Int64 = 0
        for var item in pending {
            if cancel.isCancelled { throw SyncError.cancelled }
            if !hashEverything, let known = baseline[item.entry.path],
               known.isDirectory == item.entry.isDirectory,
               known.size == item.entry.size,
               abs(known.modified - item.entry.modified) < dateTolerance {
                item.entry.hash = known.hash
                scan.entries[item.entry.path] = item.entry
                done += item.entry.size
                continue
            }
            do {
                item.entry.hash = item.entry.isPackage
                    ? try packageHash(item.url, cancel: cancel)
                    : try fileHash(item.url, cancel: cancel)
                scan.entries[item.entry.path] = item.entry
                scan.bytesHashed += item.entry.size
            } catch is SyncError {
                throw SyncError.cancelled
            } catch {
                // Recorded, and deliberately not entered into `scan.entries`.
                // A file whose bytes were never seen must not become something
                // a later deletion is justified by.
                scan.problems.append(SyncProblem(side: nil, path: item.entry.path,
                                                 cause: .unreadable(error.localizedDescription)))
            }
            done += item.entry.size
            progress?(SyncProgress(phase: .hashing, done: done, total: total,
                                   path: item.entry.path))
        }
        return scan
    }

    private static func walk(_ url: URL, at components: [String],
                             includeHidden: Bool, cancel: SyncCancel,
                             scan: inout SyncScan,
                             pending: inout [(url: URL, entry: SyncEntry)],
                             total: inout Int64,
                             progress: ((SyncProgress) -> Void)?) throws {
        if cancel.isCancelled { throw SyncError.cancelled }
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys,
                options: includeHidden ? [] : [.skipsHiddenFiles])
        } catch {
            // The rule that matters most. Everything under here is unknown, so
            // nothing under here may be given a verdict — otherwise one folder
            // with its permissions off reads as nine hundred files deleted on
            // the other side.
            let path = syncKey(for: components)
            scan.blindDirectories.append(path)
            scan.problems.append(SyncProblem(side: nil, path: path.isEmpty ? "." : path,
                                             cause: .unlistable(error.localizedDescription)))
            return
        }

        // A case-insensitive volume folds two names into one file; a
        // case-sensitive one does not. Spotting the collision here means it can
        // be refused rather than silently resolved by whichever copy runs last.
        var seenLowercased: [String: String] = [:]

        for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if cancel.isCancelled { throw SyncError.cancelled }
            let values = try? child.resourceValues(forKeys: Set(keys))
            let name = child.lastPathComponent
            let path = syncKey(for: components + [name])

            // Asked first, and it has to be: `isDirectory` follows a link, so
            // testing that first would walk straight down one.
            if values?.isSymbolicLink == true {
                scan.problems.append(SyncProblem(side: nil, path: path, cause: .symbolicLink))
                continue
            }

            let folded = path.lowercased()
            if let other = seenLowercased[folded] {
                scan.problems.append(SyncProblem(side: nil, path: path,
                                                 cause: .caseCollision(other)))
            }
            seenLowercased[folded] = path

            let isPackage = values?.isPackage == true && values?.isDirectory == true
            let isDirectory = values?.isDirectory == true && !isPackage
            let size = Int64(values?.fileSize ?? 0)
            let entry = SyncEntry(
                path: path, isDirectory: isDirectory, isPackage: isPackage,
                size: size,
                modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                hash: "")

            if isDirectory {
                scan.entries[path] = entry
                progress?(SyncProgress(phase: .walking, path: path))
                try walk(child, at: components + [name], includeHidden: includeHidden,
                         cancel: cancel, scan: &scan, pending: &pending,
                         total: &total, progress: progress)
            } else {
                // A package is one thing, and a disk image is simply a file —
                // no special case is needed for the second, since a .d64 is
                // already a file to the file system and that is the whole of
                // "the walk stops at the image".
                pending.append((child, entry))
                total += size
            }
        }
    }

    // MARK: - Hashing

    static func fileHash(_ url: URL, cancel: SyncCancel) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let piece = try handle.read(upToCount: chunk), !piece.isEmpty {
            if cancel.isCancelled { throw SyncError.cancelled }
            hasher.update(data: piece)
        }
        return hex(hasher.finalize())
    }

    /// A bundle's digest: every file inside it, by relative path, size and
    /// hash, in sorted order.
    ///
    /// A `.app` is compared and copied as one unit rather than descended into.
    /// Two reasons, and the first is about data: the copy loop cannot promise
    /// anything across nine hundred files at once, and a half-written bundle is
    /// a broken application that still looks launchable. The second is that one
    /// changed bundle would otherwise fill the report with hundreds of rows and
    /// drown everything the report exists to show. The price is that any change
    /// inside one re-copies the whole thing, which is what the Finder does too.
    static func packageHash(_ url: URL, cancel: SyncCancel) throws -> String {
        var lines: [String] = []
        let base = url.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        else { return "" }
        for case let file as URL in walker {
            if cancel.isCancelled { throw SyncError.cancelled }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            var relative = file.standardizedFileURL.path
            if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)) }
            let inner = try fileHash(file, cancel: cancel)
            lines.append("\(relative.precomposedStringWithCanonicalMapping)\t"
                         + "\(values?.fileSize ?? 0)\t\(inner)")
        }
        var hasher = SHA256()
        hasher.update(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
