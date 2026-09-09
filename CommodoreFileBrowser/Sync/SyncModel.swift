import Foundation

/// Comparing two folders, and what comes of it.
///
/// One rule runs through all of this and decides every judgement call: **where
/// the evidence is ambiguous, leave more data rather than less**. A missing
/// baseline, a folder that would not open, a hash that could not be taken, two
/// files with the same content — each of those degrades to proposing nothing
/// destructive, never to proposing a delete. A sync that copies something twice
/// is an annoyance; a sync that deletes the wrong side is the end of the file.

/// One file or folder as the scan found it, keyed by its path relative to the
/// folder being synced — the only name that means anything on both sides at
/// once.
///
/// `size` and `modified` are the fast path. When both still match what the
/// baseline recorded, the hash is taken on trust and the file is never opened;
/// `FileManager` preserves modification dates across a copy, so the run after a
/// sync reads no file bytes at all.
struct SyncEntry: Codable, Equatable {
    /// "sub/dir/name.txt". No leading slash, and normalised — see `key(for:)`.
    var path: String
    var isDirectory: Bool
    /// A `.app` and its kind: one unit, hashed as a whole and never entered.
    var isPackage: Bool
    var size: Int64
    /// Seconds since 1970 rather than a `Date`, because the comparison wants a
    /// tolerance and file systems with whole-second stamps are still in use.
    var modified: Double
    /// Lowercase SHA-256 hex, or empty for a plain directory.
    var hash: String

    // Short keys: a baseline of ten thousand files is the difference between
    // about a megabyte of JSON and two.
    enum CodingKeys: String, CodingKey {
        case path = "p", isDirectory = "d", isPackage = "k"
        case size = "s", modified = "m", hash = "h"
    }

    /// Whether this is the same bytes as `other`, which for a directory means
    /// only that both are directories: a folder has no content of its own.
    func sameContent(as other: SyncEntry) -> Bool {
        isDirectory == other.isDirectory && (isDirectory || hash == other.hash)
    }
}

/// The relative-path key two sides are matched on.
///
/// Normalised to NFC. An APFS volume hands back decomposed names and a folder
/// mounted over SMB composed ones, so without this `café.txt` on one side and
/// `café.txt` on the other are two different keys holding the same hash — which
/// the rename pass would then cheerfully offer to rename. The raw components
/// stay in the URLs used for the actual file operations; only the key is
/// normalised.
func syncKey(for components: [String]) -> String {
    components.joined(separator: "/").precomposedStringWithCanonicalMapping
}

/// What one side looked like.
struct SyncScan {
    var root: URL
    var entries: [String: SyncEntry] = [:]
    /// Directories that could not be listed.
    ///
    /// Everything underneath one of these is unknown, and no verdict may be
    /// drawn about any of it. This is the difference between "the right side is
    /// missing nine hundred files" and "I was not allowed to look at the right
    /// side", and it is the single most important safety rule here: without it,
    /// one folder with its permissions off turns into a mass deletion.
    var blindDirectories: [String] = []
    var problems: [SyncProblem] = []
    /// How much was actually read, so the fast path can be seen working.
    var bytesHashed: Int64 = 0

    /// True when `path` sits under a directory that would not open.
    func isBlind(_ path: String) -> Bool {
        blindDirectories.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// Something worth saying out loud that is not a difference: a file that would
/// not open, a symbolic link left alone, a folder that would not list.
struct SyncProblem: Equatable {
    enum Cause: Equatable {
        case unreadable(String)
        case unlistable(String)
        case symbolicLink
        case caseCollision(String)
    }
    var side: PanelSide?
    var path: String
    var cause: Cause

    var text: String {
        // Named by side for the same reason the verdicts are: a path on its own
        // does not say which of the two folders it was found in.
        let where_ = side.map { "\($0.rawValue): " } ?? ""
        switch cause {
        case .unreadable(let why): return "\(where_)\(path) — could not be read: \(why)"
        case .unlistable(let why): return "\(where_)\(path) — could not be listed: \(why)"
        case .symbolicLink: return "\(where_)\(path) — a symbolic link, left alone"
        case .caseCollision(let other):
            return "\(where_)\(path) — the same name as \(other) but for its case"
        }
    }
}

/// What the comparison made of one path.
enum SyncKind: Equatable {
    case newOnLeft, newOnRight
    case changedOnLeft, changedOnRight
    case deletedOnLeft, deletedOnRight
    case renamedOnLeft, renamedOnRight
    case conflictBothChanged
    case conflictBothAdded
    /// One side edited it, the other threw it away.
    case conflictChangedAndDeleted(changed: PanelSide)
    case conflictBothRenamed
    /// Two names on one side that a case-insensitive volume cannot tell apart.
    case conflictCaseOnly(side: PanelSide)
    /// A folder on one side, a file of the same name on the other.
    case conflictTypeMismatch(folderOn: PanelSide)
    /// First run: the same bytes under two names, and nothing anywhere to say
    /// which of them is the newer.
    case possibleRename
    /// Could not be hashed, or lives under a folder that would not open. The
    /// side is nil when neither could be read.
    case unreadable(side: PanelSide?)

    var isConflict: Bool {
        switch self {
        case .conflictBothChanged, .conflictBothAdded, .conflictChangedAndDeleted,
             .conflictBothRenamed, .conflictCaseOnly, .conflictTypeMismatch:
            return true
        default: return false
        }
    }

    /// For the sheet's verdict column.
    ///
    /// Every one of these names the side the change was made on, because that
    /// is the whole question the report is answering: not *that* the two
    /// folders differ — the user can see that — but which of them moved, and
    /// therefore which way the difference should travel. A verdict that says
    /// "Renamed" and leaves the side to the action menu is asking the reader to
    /// work backwards from the fix to the fact.
    ///
    /// The direction the row will be applied in is the action menu's business
    /// and is deliberately not repeated here.
    var label: String {
        switch self {
        case .newOnLeft: return "New on left"
        case .newOnRight: return "New on right"
        case .changedOnLeft: return "Changed on left"
        case .changedOnRight: return "Changed on right"
        case .deletedOnLeft: return "Deleted on left"
        case .deletedOnRight: return "Deleted on right"
        case .renamedOnLeft: return "Renamed on left"
        case .renamedOnRight: return "Renamed on right"
        case .conflictBothChanged: return "Changed on both"
        case .conflictBothAdded: return "Added on both"
        case .conflictBothRenamed: return "Renamed on both"
        case .conflictChangedAndDeleted(let changed):
            return changed == .left ? "Changed left, deleted right"
                                    : "Changed right, deleted left"
        case .conflictCaseOnly(let side): return "Name clash on \(side.rawValue)"
        case .conflictTypeMismatch(let folderOn):
            return folderOn == .left ? "Folder left, file right"
                                     : "Folder right, file left"
        case .possibleRename: return "Maybe renamed"
        case .unreadable(let side):
            // Nil means neither side could be read. Saying so beats saying
            // nothing: "Unreadable" alone reads as though one side were fine.
            return side.map { "Unreadable on \($0.rawValue)" } ?? "Unreadable on both"
        }
    }

    /// Which group of the report it belongs under, and in what order they come.
    /// Conflicts first: they are the only rows that need a decision, and a row
    /// that needs a decision must not be below the fold.
    var group: Int {
        if isConflict { return 0 }
        switch self {
        case .renamedOnLeft, .renamedOnRight, .possibleRename: return 1
        case .changedOnLeft, .changedOnRight: return 2
        case .newOnLeft, .newOnRight: return 3
        case .deletedOnLeft, .deletedOnRight: return 4
        default: return 5
        }
    }

    static let groupNames = ["Conflicts", "Renamed", "Changed", "New", "Deleted", "Skipped"]
}

/// What to do about a row.
enum SyncAction: String, Equatable, CaseIterable, Identifiable {
    case skip
    case copyToRight, copyToLeft
    case renameOnRight, renameOnLeft
    case deleteLeft, deleteRight

    var id: String { rawValue }

    var isDestructive: Bool { self == .deleteLeft || self == .deleteRight }

    var label: String {
        switch self {
        case .skip: return "Skip"
        case .copyToRight: return "Send right"
        case .copyToLeft: return "Send left"
        case .renameOnRight: return "Rename right"
        case .renameOnLeft: return "Rename left"
        case .deleteLeft: return "Delete left"
        case .deleteRight: return "Delete right"
        }
    }
}

/// One line of the report.
struct SyncDifference: Identifiable, Equatable {
    var id: Int
    /// For a rename this is the new path; `renamedFrom` holds the old one.
    var path: String
    var renamedFrom: String?
    /// On a rename row, the name each side currently holds.
    ///
    /// `renamedFrom` and `path` read well — old name, new name — but they do
    /// not say which folder each is in, and on a "maybe renamed" row the two
    /// names are on opposite sides. Renaming a side means moving the name it
    /// has to the name the other one has, so both are recorded plainly rather
    /// than inferred from the kind.
    var leftName: String?
    var rightName: String?
    var kind: SyncKind
    /// The suggestion. The user may pick anything in `allowed`.
    var action: SyncAction
    var allowed: [SyncAction]
    var left: SyncEntry?
    var right: SyncEntry?
    var baseline: SyncEntry?
    /// A second line under the row, where one side of the story is not enough.
    var note: String?

    var isDirectory: Bool { (left ?? right ?? baseline)?.isDirectory ?? false }

    /// How many bytes acting on this row would move.
    var bytesToCopy: Int64 {
        switch action {
        case .copyToRight: return left?.size ?? 0
        case .copyToLeft: return right?.size ?? 0
        default: return 0
        }
    }
}

/// Everything the sheet needs, and everything performing it needs.
struct SyncPlan {
    /// Changes when a fresh scan lands, so the sheet knows to reseed the rows
    /// the user has been editing.
    var id = UUID()
    var leftRoot: URL
    var rightRoot: URL
    /// False on a first run, which is what stops any delete being proposed.
    var hasBaseline: Bool
    var rows: [SyncDifference] = []
    /// Agreed on both sides and needing nothing: these seed the new baseline.
    var settled: [String: SyncEntry] = [:]
    /// Baseline entries about paths nothing could be decided for — carried
    /// through untouched rather than dropped, since dropping one is a claim.
    var carried: [String: SyncEntry] = [:]
    var scannedLeft = 0
    var scannedRight = 0
    var problems: [SyncProblem] = []
    /// True when a folder somewhere would not open, so the report is partial.
    var blind = false

    var conflicts: Int { rows.filter { $0.kind.isConflict }.count }
    var unresolved: Int { rows.filter { $0.kind.isConflict && $0.action == .skip }.count }
    var bytesToCopy: Int64 { rows.reduce(0) { $0 + $1.bytesToCopy } }
    var deletions: Int { rows.filter { $0.action.isDestructive }.count }
    var hasWork: Bool { rows.contains { $0.action != .skip } }
}

/// How a run went.
struct SyncResult {
    var applied = 0
    var skipped = 0
    var failures: [(path: String, error: Error)] = []
    /// What to write down as agreed, built from what actually happened rather
    /// than from what was planned.
    var baseline: [String: SyncEntry] = [:]
}

/// A flag a worker checks and the main thread sets.
///
/// A bare `Bool` written from one thread and read from another is a data race,
/// and it is the kind that works for a year and then does not.
final class SyncCancel {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}

/// Where a scan has got to, for the sheet's progress bar.
struct SyncProgress {
    enum Phase { case walking, hashing, applying }
    var phase: Phase
    var done: Int64 = 0
    var total: Int64 = 0
    var path: String = ""
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}

enum SyncError: LocalizedError {
    case cancelled
    case sameFolder
    case nested

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .sameFolder: return "Both panels are showing the same folder."
        case .nested: return "One of these folders is inside the other."
        }
    }
}
