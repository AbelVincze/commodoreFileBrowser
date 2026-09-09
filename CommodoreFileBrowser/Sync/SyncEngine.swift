import Foundation

/// Deciding what two sides differ by, given what they last agreed on.
///
/// Three dictionaries in, a list of rows out. No file system, no app, no views
/// — which is what makes the part of this feature that could destroy something
/// the part that is cheapest to test.
enum SyncEngine {

    /// Is `inner` the same folder as `outer`, or somewhere beneath it?
    ///
    /// By path components, never by `hasPrefix` on the string: that matches
    /// `/Users/me/backup` against `/Users/me/back` and would refuse a perfectly
    /// good pair of folders — or worse, let a bad one through the other way.
    static func isAncestor(_ outer: URL, of inner: URL) -> Bool {
        let a = outer.standardizedFileURL.pathComponents
        let b = inner.standardizedFileURL.pathComponents
        guard a.count <= b.count else { return false }
        return Array(b.prefix(a.count)) == a
    }

    // MARK: - The plan

    static func plan(left: SyncScan, right: SyncScan,
                     baseline: [String: SyncEntry]?,
                     propagateDeletions: Bool) -> SyncPlan {
        var plan = SyncPlan(leftRoot: left.root, rightRoot: right.root,
                            hasBaseline: baseline != nil)
        plan.scannedLeft = left.entries.count
        plan.scannedRight = right.entries.count
        plan.problems = left.problems.map { withSide($0, .left) }
            + right.problems.map { withSide($0, .right) }
        plan.blind = !left.blindDirectories.isEmpty || !right.blindDirectories.isEmpty

        let known = baseline ?? [:]
        var rows: [SyncDifference] = []
        var settled: [String: SyncEntry] = [:]
        var carried: [String: SyncEntry] = [:]

        for path in Set(left.entries.keys).union(right.entries.keys).union(known.keys).sorted() {
            let l = left.entries[path], r = right.entries[path], b = known[path]

            // Nothing under a folder that would not open gets a verdict. The
            // baseline entry is carried through rather than dropped, since
            // dropping it is itself a claim about what is there.
            if left.isBlind(path) || right.isBlind(path) {
                if let b { carried[path] = b }
                rows.append(row(path: path, kind: .unreadable, action: .skip,
                                allowed: [.skip], l: l, r: r, b: b,
                                note: "a folder on the way to this could not be read"))
                continue
            }
            // The same for a file whose bytes could not be taken: it is absent
            // from the scan but present on disk, and treating that as "not
            // there" is how a sync deletes the wrong side.
            if let problem = unreadableProblem(path, left: left, right: right) {
                if let b { carried[path] = b }
                rows.append(row(path: path, kind: .unreadable, action: .skip,
                                allowed: [.skip], l: l, r: r, b: b, note: problem))
                continue
            }

            if let verdict = classify(baseline: b, left: l, right: r,
                                      propagateDeletions: propagateDeletions,
                                      hasBaseline: baseline != nil) {
                rows.append(row(path: path, kind: verdict.kind, action: verdict.action,
                                allowed: verdict.allowed, l: l, r: r, b: b,
                                note: verdict.note ?? difference(l, r)))
            } else if let l, let r, l.sameContent(as: r) {
                // Agreed, and nothing to do but write it down.
                settled[path] = l
            }
        }

        plan.rows = pairRenames(rows, baseline: known, hasBaseline: baseline != nil,
                                left: left, right: right)
        plan.settled = settled
        plan.carried = carried
        plan.rows.sort {
            $0.kind.group != $1.kind.group ? $0.kind.group < $1.kind.group : $0.path < $1.path
        }
        for index in plan.rows.indices { plan.rows[index].id = index }
        return plan
    }

    // MARK: - One path

    struct Verdict {
        var kind: SyncKind
        var action: SyncAction
        var allowed: [SyncAction]
        var note: String?
    }

    /// The whole table. `nil` means there is nothing to report about this path.
    ///
    /// Every conflict defaults to `.skip`, and every first-run case that could
    /// be read two ways defaults to copying rather than deleting. With no record
    /// of an earlier state, "here and not there" is exactly as much evidence for
    /// "added there" as for "deleted here", and one of those two readings
    /// destroys the file — so a first run never proposes a deletion at all.
    static func classify(baseline b: SyncEntry?, left l: SyncEntry?, right r: SyncEntry?,
                         propagateDeletions: Bool, hasBaseline: Bool) -> Verdict? {
        // A folder on one side and a file on the other. Never resolved on its
        // own: resolving it means deleting a whole tree.
        if let l, let r, l.isDirectory != r.isDirectory {
            return Verdict(kind: .conflictTypeMismatch, action: .skip, allowed: [.skip],
                           note: "one side has a folder here and the other a file")
        }

        switch (b, l, r) {
        case (_, nil, nil):
            return nil                                    // gone from both; drop it

        case (nil, .some, nil):
            return Verdict(kind: .newOnLeft, action: .copyToRight,
                           allowed: [.copyToRight, .skip] + deleteIf(propagateDeletions, .deleteLeft))
        case (nil, nil, .some):
            return Verdict(kind: .newOnRight, action: .copyToLeft,
                           allowed: [.copyToLeft, .skip] + deleteIf(propagateDeletions, .deleteRight))

        case (nil, .some(let l), .some(let r)):
            if l.sameContent(as: r) { return nil }         // appeared on both, identical
            return Verdict(kind: .conflictBothAdded, action: .skip,
                           allowed: [.skip, .copyToRight, .copyToLeft],
                           note: hasBaseline
                                 ? "both sides added this, with different content"
                                 : "no record of an earlier sync, and the two differ")

        case (.some(let b), .some(let l), nil):
            if l.sameContent(as: b) {
                // Deleted on the right, and the left still holds what was
                // agreed — so the deletion is the change to carry over.
                return Verdict(kind: .deletedOnRight,
                               action: propagateDeletions ? .deleteLeft : .skip,
                               allowed: [.skip, .copyToRight] + deleteIf(propagateDeletions, .deleteLeft),
                               note: propagateDeletions ? nil : "deletions are switched off")
            }
            return Verdict(kind: .conflictChangedAndDeleted(changed: .left), action: .skip,
                           allowed: [.skip, .copyToRight] + deleteIf(propagateDeletions, .deleteLeft),
                           note: "changed on the left and deleted on the right")

        case (.some(let b), nil, .some(let r)):
            if r.sameContent(as: b) {
                return Verdict(kind: .deletedOnLeft,
                               action: propagateDeletions ? .deleteRight : .skip,
                               allowed: [.skip, .copyToLeft] + deleteIf(propagateDeletions, .deleteRight),
                               note: propagateDeletions ? nil : "deletions are switched off")
            }
            return Verdict(kind: .conflictChangedAndDeleted(changed: .right), action: .skip,
                           allowed: [.skip, .copyToLeft] + deleteIf(propagateDeletions, .deleteRight),
                           note: "deleted on the left and changed on the right")

        case (.some(let b), .some(let l), .some(let r)):
            if l.sameContent(as: r) { return nil }         // agreed, changed or not
            if l.sameContent(as: b) {
                return Verdict(kind: .changedOnRight, action: .copyToLeft,
                               allowed: [.copyToLeft, .copyToRight, .skip])
            }
            if r.sameContent(as: b) {
                return Verdict(kind: .changedOnLeft, action: .copyToRight,
                               allowed: [.copyToRight, .copyToLeft, .skip])
            }
            return Verdict(kind: .conflictBothChanged, action: .skip,
                           allowed: [.skip, .copyToRight, .copyToLeft],
                           note: "changed on both sides since the last sync")
        }
    }

    private static func deleteIf(_ on: Bool, _ action: SyncAction) -> [SyncAction] {
        on ? [action] : []
    }

    // MARK: - Renames

    /// Folds an add and a matching disappearance into one move.
    ///
    /// With a baseline a rename on the left shows as two rows: a path that is
    /// new on the left, and a path the baseline had which the right still holds
    /// unchanged but the left has lost. Same bytes, so it is one file that
    /// changed its name, and applying it as a move rather than as a copy and a
    /// delete is both faster and truer.
    ///
    /// Only ever when exactly one candidate stands on each side. Two files with
    /// the same content carry no evidence about which of them became which, and
    /// a wrong rename cannot be told from a lost file the moment the user
    /// renames something back. Empty files are excluded outright, since every
    /// one of them shares a single hash.
    private static func pairRenames(_ rows: [SyncDifference], baseline: [String: SyncEntry],
                                    hasBaseline: Bool,
                                    left: SyncScan, right: SyncScan) -> [SyncDifference] {
        var out = rows
        var consumed = Set<Int>()

        func hashOf(_ row: SyncDifference, side: PanelSide) -> String? {
            let entry = side == .left ? row.left : row.right
            guard let entry, !entry.isDirectory, entry.size > 0, !entry.hash.isEmpty
            else { return nil }
            return entry.hash
        }

        for side in [PanelSide.left, PanelSide.right] {
            let newKind: SyncKind = side == .left ? .newOnLeft : .newOnRight
            // The far side lost nothing; this side did. "Deleted on the left"
            // is the row that says the left no longer has a file the baseline
            // and the right still agree on.
            let goneKind: SyncKind = side == .left ? .deletedOnLeft : .deletedOnRight

            var arrived: [String: [Int]] = [:]
            var departed: [String: [Int]] = [:]
            for (index, row) in out.enumerated() where !consumed.contains(index) {
                if row.kind == newKind, let h = hashOf(row, side: side) {
                    arrived[h, default: []].append(index)
                } else if row.kind == goneKind, let b = baseline[row.path],
                          !b.isDirectory, b.size > 0, !b.hash.isEmpty {
                    departed[b.hash, default: []].append(index)
                }
            }
            for (hash, news) in arrived {
                guard news.count == 1, let olds = departed[hash], olds.count == 1 else { continue }
                let newIndex = news[0], oldIndex = olds[0]
                consumed.insert(oldIndex)
                out[newIndex].kind = side == .left ? .renamedOnLeft : .renamedOnRight
                out[newIndex].renamedFrom = out[oldIndex].path
                out[newIndex].action = side == .left ? .renameOnRight : .renameOnLeft
                out[newIndex].allowed = [out[newIndex].action, .skip]
                out[newIndex].note = nil
            }
        }

        // With no baseline there is nothing to say which name came first, so
        // the pair is reported and left alone rather than guessed at.
        if !hasBaseline {
            var leftOnly: [String: [Int]] = [:]
            var rightOnly: [String: [Int]] = [:]
            for (index, row) in out.enumerated() where !consumed.contains(index) {
                if row.kind == .newOnLeft, let h = hashOf(row, side: .left) {
                    leftOnly[h, default: []].append(index)
                } else if row.kind == .newOnRight, let h = hashOf(row, side: .right) {
                    rightOnly[h, default: []].append(index)
                }
            }
            for (hash, lefts) in leftOnly {
                guard lefts.count == 1, let rights = rightOnly[hash], rights.count == 1
                else { continue }
                let a = lefts[0], bIndex = rights[0]
                consumed.insert(bIndex)
                out[a].kind = .possibleRename
                out[a].renamedFrom = out[bIndex].path
                out[a].action = .skip
                out[a].allowed = [.skip, .renameOnRight, .renameOnLeft, .copyToRight, .copyToLeft]
                out[a].note = "the same content under two names, and no record of "
                            + "which came first"
            }
        }

        // Two files sharing a hash are left as they were, and told why, so an
        // add-and-delete pair that looks like a rename does not look like a bug.
        for (index, row) in out.enumerated() where !consumed.contains(index) {
            if (row.kind == .newOnLeft || row.kind == .newOnRight), row.note == nil,
               let entry = row.left ?? row.right, entry.size > 0, !entry.isDirectory,
               duplicateHash(entry.hash, in: left) || duplicateHash(entry.hash, in: right) {
                out[index].note = "more than one file here has this content, so which "
                                + "was renamed cannot be told"
            }
        }

        return out.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
    }

    private static func duplicateHash(_ hash: String, in scan: SyncScan) -> Bool {
        var seen = 0
        for entry in scan.entries.values where entry.hash == hash && !entry.isDirectory {
            seen += 1
            if seen > 1 { return true }
        }
        return false
    }

    // MARK: - Pieces

    private static func row(path: String, kind: SyncKind, action: SyncAction,
                            allowed: [SyncAction], l: SyncEntry?, r: SyncEntry?,
                            b: SyncEntry?, note: String?) -> SyncDifference {
        SyncDifference(id: 0, path: path, renamedFrom: nil, kind: kind, action: action,
                       allowed: allowed, left: l, right: r, baseline: b, note: note)
    }

    /// A second line for a row, saying what each side holds, since "changed"
    /// on its own does not tell the user which way to send it.
    private static func difference(_ l: SyncEntry?, _ r: SyncEntry?) -> String? {
        guard let l, let r, !l.isDirectory, !r.isDirectory else { return nil }
        let stamp = DateFormatter()
        stamp.dateStyle = .short
        stamp.timeStyle = .short
        func side(_ e: SyncEntry) -> String {
            "\(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))"
            + " · \(stamp.string(from: Date(timeIntervalSince1970: e.modified)))"
        }
        return "left \(side(l))  ·  right \(side(r))"
    }

    private static func withSide(_ problem: SyncProblem, _ side: PanelSide) -> SyncProblem {
        var out = problem
        out.side = side
        return out
    }

    private static func unreadableProblem(_ path: String,
                                          left: SyncScan, right: SyncScan) -> String? {
        for scan in [left, right] {
            for problem in scan.problems where problem.path == path {
                if case .unreadable(let why) = problem.cause { return "could not be read: \(why)" }
                if case .caseCollision(let other) = problem.cause {
                    return "the same name as \(other) but for its case"
                }
            }
        }
        return nil
    }
}
