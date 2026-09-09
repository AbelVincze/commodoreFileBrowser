import Foundation

/// Carrying out what the report proposed.
///
/// The order is the safety. Renames first, because a move is free and clears a
/// name out of the way; then every copy, in both directions; then, last, the
/// deletions. Doing all the copying before any of the deleting means a run cut
/// short leaves too much data rather than too little, which is the direction to
/// fail in.
enum SyncRunner {

    /// `toTrash` is a parameter rather than a setting read from the store, so
    /// the test suite can run this for real without filling the user's Trash.
    static func apply(_ rows: [SyncDifference], leftRoot: URL, rightRoot: URL,
                      settled: [String: SyncEntry], carried: [String: SyncEntry],
                      baseline: [String: SyncEntry],
                      toTrash: Bool,
                      cancel: SyncCancel,
                      progress: ((SyncProgress) -> Void)? = nil) -> SyncResult {
        var result = SyncResult()
        // Start from what was already agreed, keep what nothing could be
        // decided about, and add what the run actually achieves. Not what it
        // set out to achieve — a path recorded as agreed when it is not is a
        // deletion waiting to happen on some later run.
        result.baseline = baseline
        for (path, entry) in settled { result.baseline[path] = entry }
        for (path, entry) in carried { result.baseline[path] = entry }

        let work = rows.filter { $0.action != .skip }
        result.skipped = rows.count - work.count
        let ordered = work.sorted { rank($0.action) < rank($1.action) }
        let total = ordered.reduce(Int64(0)) { $0 + $1.weight }
        let bytesTotal = ordered.reduce(Int64(0)) { $0 + $1.bytesToCopy }
        var done: Int64 = 0
        var bytesDone: Int64 = 0

        for (index, row) in ordered.enumerated() {
            if cancel.isCancelled { break }
            // Announced before the row is done rather than after, so the path
            // on screen is the one being worked on. On slow media that name
            // sitting there is the whole difference between "copying a big
            // file" and "stopped".
            progress?(SyncProgress(phase: .applying, done: done, total: total,
                                   path: row.path, index: index, count: ordered.count,
                                   bytesDone: bytesDone, bytesTotal: bytesTotal))
            done += row.weight
            bytesDone += row.bytesToCopy
            do {
                try perform(row, leftRoot: leftRoot, rightRoot: rightRoot,
                            toTrash: toTrash, into: &result)
                result.applied += 1
            } catch {
                result.failures.append((row.path, error))
                // A path whose action failed is dropped from the record rather
                // than left in it. Dropped, it is simply looked at again next
                // run; left in wrongly, it is a claim that the two sides agree
                // when they do not.
                result.baseline.removeValue(forKey: row.path)
                if let from = row.renamedFrom { result.baseline.removeValue(forKey: from) }
            }
        }

        progress?(SyncProgress(phase: .applying, done: total, total: total,
                               index: ordered.count, count: ordered.count,
                               bytesDone: bytesDone, bytesTotal: bytesTotal))

        // Anything the user chose to leave alone is not agreed either.
        for row in rows where row.action == .skip {
            result.baseline.removeValue(forKey: row.path)
            if let from = row.renamedFrom { result.baseline.removeValue(forKey: from) }
        }
        return result
    }

    /// Renames, then copies, then deletes.
    private static func rank(_ action: SyncAction) -> Int {
        switch action {
        case .renameOnLeft, .renameOnRight: return 0
        case .copyToLeft, .copyToRight: return 1
        case .deleteLeft, .deleteRight: return 2
        case .skip: return 3
        }
    }

    // MARK: - One row

    private static func perform(_ row: SyncDifference, leftRoot: URL, rightRoot: URL,
                                toTrash: Bool, into result: inout SyncResult) throws {
        let fm = FileManager.default
        func url(_ root: URL, _ path: String) -> URL {
            path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        }

        switch row.action {
        case .skip:
            return

        case .copyToRight, .copyToLeft:
            let toRight = row.action == .copyToRight
            let source = url(toRight ? leftRoot : rightRoot, row.path)
            let target = url(toRight ? rightRoot : leftRoot, row.path)
            let expected = toRight ? row.left : row.right
            let clobbering = toRight ? row.right : row.left
            try verify(source, matches: expected, what: "the file to copy")
            try verify(target, matches: clobbering, what: "the file being replaced")

            if row.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try replace(source, with: target)
            }
            result.baseline[row.path] = stamped(expected, at: target)

        case .renameOnRight, .renameOnLeft:
            // Renaming a side means giving it the name the other side uses, so
            // both names are read off the row rather than worked out from which
            // of `path` and `renamedFrom` is which here.
            let onRight = row.action == .renameOnRight
            guard let from = onRight ? row.rightName : row.leftName,
                  let to = onRight ? row.leftName : row.rightName,
                  from != to else { return }
            let root = onRight ? rightRoot : leftRoot
            let old = url(root, from)
            let new = url(root, to)
            try fm.createDirectory(at: new.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            result.baseline.removeValue(forKey: from)
            result.baseline[to] = stamped(row.left ?? row.right, at: new)

        case .deleteLeft, .deleteRight:
            let onLeft = row.action == .deleteLeft
            let target = url(onLeft ? leftRoot : rightRoot, row.path)
            // Only ever delete what the report was actually about. If it has
            // moved on since the sheet opened, leave it and say so.
            try verify(target, matches: onLeft ? row.left : row.right,
                       what: "the file to delete")
            if toTrash {
                // Never a quiet fall back to removeItem when this fails, which
                // it does on some network volumes: "could not put it in the
                // Trash" and "deleted it forever instead" are not the same
                // answer to the same question.
                try fm.trashItem(at: target, resultingItemURL: nil)
            } else {
                try fm.removeItem(at: target)
            }
            result.baseline.removeValue(forKey: row.path)
        }
    }

    /// Copy beside the target, then swap it in.
    ///
    /// A failure part way through leaves the original untouched, and a success
    /// is one rename. The same instinct as the atomic writes elsewhere in the
    /// app, for files too large to hold in memory first.
    private static func replace(_ source: URL, with target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            try fm.copyItem(at: source, to: target)
            return
        }
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).cfbsync-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: source, to: temp)
            _ = try fm.replaceItemAt(target, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Refuses to touch anything that has changed since the report was made.
    ///
    /// The sheet can sit open for as long as the user likes, and a file that
    /// moved on in the meantime is one the report is no longer describing.
    /// Cheap — a stat — and it is what stops a sync overwriting an edit made
    /// while the user was reading about it.
    private static func verify(_ url: URL, matches entry: SyncEntry?, what: String) throws {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey,
                                                       .isDirectoryKey])
        let exists = values != nil
        guard let entry else {
            if exists { throw SyncFailure.changedUnderfoot(what) }
            return
        }
        guard exists else { throw SyncFailure.changedUnderfoot(what) }
        if entry.isDirectory { return }
        let size = Int64(values?.fileSize ?? 0)
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        guard size == entry.size,
              abs(date - entry.modified) < SyncScanner.dateTolerance
        else { throw SyncFailure.changedUnderfoot(what) }
    }

    /// The entry as it now sits at `url`, so the modification date recorded is
    /// the copy's own and the fast path recognises it next time.
    private static func stamped(_ entry: SyncEntry?, at url: URL) -> SyncEntry? {
        guard var entry else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let date = values?.contentModificationDate { entry.modified = date.timeIntervalSince1970 }
        if let size = values?.fileSize { entry.size = Int64(size) }
        return entry
    }
}

enum SyncFailure: LocalizedError {
    case changedUnderfoot(String)

    var errorDescription: String? {
        switch self {
        case .changedUnderfoot(let what):
            return "\(what) changed while the report was open, so it was left alone"
        }
    }
}
