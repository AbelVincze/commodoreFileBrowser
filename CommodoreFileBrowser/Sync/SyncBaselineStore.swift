import Foundation
import CryptoKit

/// What the two sides last agreed on.
///
/// This is the whole reason a sync between two folders that both change can be
/// safe. Without it, "here and not there" is two stories at once — added here,
/// or deleted there — and picking the wrong one destroys the file. With it the
/// question is answered rather than guessed: whichever side no longer matches
/// what was agreed is the side that moved.
///
/// One map, not two. The record is of paths and their content, which is
/// side-independent, so swapping the panels cannot apply it the wrong way round.
struct SyncBaseline: Codable {
    /// Anything but 1 is read as no baseline at all. A format this decides
    /// deletions from is not a thing to be clever about across versions.
    static let currentVersion = 1

    var version = SyncBaseline.currentVersion
    var leftPath: String
    var rightPath: String
    var completedAt: Date
    /// Which `showHiddenFiles` setting produced it, so the sheet can say when
    /// the answer is about to change underfoot.
    var includesHidden: Bool
    /// Sorted by path, so two baselines can be diffed by eye.
    var entries: [SyncEntry]

    var byPath: [String: SyncEntry] {
        Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

/// Where baselines live and how they are named.
///
/// Under Application Support rather than as a dot-file beside the user's own
/// folders: this app writes nothing next to user data and that is worth
/// keeping. The cost is that the record does not travel with the folders — the
/// same pair synced from another Mac is a first run — and a first run cannot
/// delete anything, so the cost is paid in convenience rather than in safety.
struct SyncBaselineStore {
    let root: URL

    /// The default home. Injectable so the tests write into a scratch folder,
    /// and because `Bundle.main.bundleIdentifier` is nil in the test binary.
    static func applicationSupport() -> SyncBaselineStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let id = Bundle.main.bundleIdentifier ?? "CommodoreFileBrowser"
        return SyncBaselineStore(root: base.appendingPathComponent(id)
                                           .appendingPathComponent("Sync"))
    }

    /// The file name for a pair of folders.
    ///
    /// The two paths are sorted before they are hashed, so the key does not
    /// depend on which panel is which — the record itself has no sides. The
    /// leaf names are decoration, there so a person looking in the folder can
    /// tell one file from another.
    func url(forLeft left: URL, right: URL) -> URL {
        let a = left.standardizedFileURL.path
        let b = right.standardizedFileURL.path
        let pair = [a, b].sorted()
        let digest = SHA256.hash(data: Data(pair.joined(separator: "\n").utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let names = pair.map { Self.tidy(URL(fileURLWithPath: $0).lastPathComponent) }
        return root.appendingPathComponent("\(names[0])-\(names[1])-\(hex).json")
    }

    private static func tidy(_ name: String) -> String {
        let kept = name.map { c -> Character in
            c.isLetter || c.isNumber || c == "." || c == "_" || c == "-" ? c : "-"
        }
        return String(String(kept).prefix(24))
    }

    /// The record for this pair, or nil.
    ///
    /// Nil covers every doubt there is — no file, unreadable, a version this
    /// does not know, or a record naming folders these are not. Every one of
    /// them means a first run, and a first run proposes no deletions, so a
    /// baseline that cannot be trusted completely costs one extra decision
    /// rather than a lost file.
    func load(left: URL, right: URL) -> SyncBaseline? {
        guard let data = try? Data(contentsOf: url(forLeft: left, right: right)),
              let baseline = try? JSONDecoder().decode(SyncBaseline.self, from: data),
              baseline.version == SyncBaseline.currentVersion
        else { return nil }
        let pair = Set([left.standardizedFileURL.path, right.standardizedFileURL.path])
        guard pair == Set([baseline.leftPath, baseline.rightPath]) else { return nil }
        return baseline
    }

    /// Writes the record, and tidies the folder while it is there.
    ///
    /// A failure here is reported but is not a failed sync: the files are
    /// already where they belong, and the only cost is that the next run falls
    /// back to first-run rules.
    func save(_ entries: [String: SyncEntry], left: URL, right: URL,
              includesHidden: Bool) throws {
        let baseline = SyncBaseline(
            leftPath: left.standardizedFileURL.path,
            rightPath: right.standardizedFileURL.path,
            completedAt: Date(),
            includesHidden: includesHidden,
            entries: entries.values.sorted { $0.path < $1.path })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        try encoder.encode(baseline).write(to: url(forLeft: left, right: right),
                                           options: .atomic)
        prune()
    }

    /// Old records are dropped rather than kept forever: losing one costs a
    /// first run, and this folder is not the user's business to tidy.
    private func prune(keeping: Int = 50, olderThan days: Double = 180) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys) else { return }
        let dated = files.filter { $0.pathExtension == "json" }.map {
            ($0, (try? $0.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        let stale = Date().addingTimeInterval(-days * 24 * 3600)
        for (index, entry) in dated.enumerated() where index >= keeping || entry.1 < stale {
            try? FileManager.default.removeItem(at: entry.0)
        }
    }
}

extension SyncBaselineStore {
    /// Forgets a pair. Only the tests need this — nothing in the app deletes a
    /// record, since losing one costs a first run and a first run is safe.
    func deleteRecord(left: URL, right: URL) {
        try? FileManager.default.removeItem(at: url(forLeft: left, right: right))
    }
}
