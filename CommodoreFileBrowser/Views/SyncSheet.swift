import SwiftUI
import AppKit

/// What two folders differ by, and what to do about it.
///
/// The one dialog in this app that scrolls a list the user edits, so it is
/// built like the help sheet — its own header, its own footer, a fixed frame —
/// rather than out of `DialogFrame`, which is sized to its contents and assumes
/// there are few of them. Native controls throughout: the retro look belongs to
/// the content, and here the content is a list of paths.
struct SyncSheet: View {
    let plan: SyncPlan?
    let progress: SyncProgress?
    let scanning: Bool
    /// True while the run is under way. The sheet stays up through it — there
    /// has to be somewhere to put the bar, and somewhere to put Stop.
    let applying: Bool
    let leftName: String
    let rightName: String
    let palette: Palette
    @Binding var propagateDeletions: Bool
    let onRescan: () -> Void
    let onCancel: () -> Void
    let onApply: ([SyncDifference]) -> Void

    /// The rows as the user has edited them. Seeded from the plan and reseeded
    /// only when a new scan lands, so a rescan does not quietly throw away
    /// decisions — and neither does a SwiftUI rebuild.
    @State private var rows: [SyncDifference] = []
    @State private var showSettled = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.color(.border))
            paths
            Divider().overlay(palette.color(.border))
            content
            Divider().overlay(palette.color(.border))
            footer
        }
        .frame(width: 820, height: 620)
        .background(palette.color(.window))
        .onChange(of: plan?.id) { _, _ in rows = plan?.rows ?? [] }
        .onAppear { rows = plan?.rows ?? [] }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Sync Folders")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(applying ? "Stop" : "Close", action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var paths: some View {
        HStack(spacing: 8) {
            Text(leftName)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("⇄").foregroundStyle(palette.color(.dim))
            Text(rightName)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(palette.color(.dim))
        .lineLimit(1)
        .truncationMode(.head)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        if applying {
            applyingView
        } else if scanning {
            scanningView
        } else if let plan {
            if rows.isEmpty {
                nothingToDo(plan)
            } else {
                list(plan)
            }
        } else {
            centred("Nothing to show.")
        }
    }

    private var scanningView: some View {
        VStack(spacing: 10) {
            if let progress, progress.phase == .hashing, progress.total > 0 {
                ProgressView(value: progress.fraction).frame(width: 260)
                Text(ByteCountFormatter.string(fromByteCount: progress.done, countStyle: .file)
                     + " of "
                     + ByteCountFormatter.string(fromByteCount: progress.total, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.color(.dim))
            } else {
                ProgressView().controlSize(.small)
                Text("Reading both folders…")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.color(.dim))
            }
            Text(progress?.path ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(palette.color(.dim))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// What the run looks like while it happens.
    ///
    /// The bar is weighted by bytes so a large file moves it in proportion to
    /// what it costs, and the count of files underneath keeps moving while the
    /// bar is stuck inside one — between them they answer the only question
    /// being asked, which is whether anything is still happening.
    private var applyingView: some View {
        VStack(spacing: 10) {
            ProgressView(value: progress?.fraction ?? 0).frame(width: 300)
            Text(applyingCaption)
                .font(.system(size: 11))
                .foregroundStyle(palette.color(.dim))
            Text(progress?.path ?? "")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(palette.color(.dim))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var applyingCaption: String {
        guard let progress, progress.count > 0 else { return "Starting…" }
        var text = "\(progress.index) of \(progress.count) files"
        // Only worth saying when bytes are what is being moved: a run of
        // renames and deletions has none to speak of.
        if progress.bytesTotal > 0 {
            func size(_ n: Int64) -> String {
                ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
            }
            text += " · \(size(progress.bytesDone)) of \(size(progress.bytesTotal))"
        }
        return text
    }

    private func nothingToDo(_ plan: SyncPlan) -> some View {
        VStack(spacing: 8) {
            Text("Nothing to do.")
                .font(.system(size: 13))
            Text("\(plan.settled.count) file\(plan.settled.count == 1 ? "" : "s") match on both sides.")
                .font(.system(size: 11))
                .foregroundStyle(palette.color(.dim))
            Button("Compare again, reading every file", action: onRescan)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centred(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(palette.color(.dim))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The list

    private func list(_ plan: SyncPlan) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !plan.hasBaseline { firstRunNotice }
                if plan.blind { blindNotice }
                ForEach(Array(SyncKind.groupNames.enumerated()), id: \.offset) { index, name in
                    let group = rows.indices.filter { rows[$0].kind.group == index }
                    if !group.isEmpty {
                        section(name, count: group.count)
                        ForEach(Array(group.enumerated()), id: \.element) { position, row in
                            self.row(at: row, banded: position.isMultiple(of: 2))
                        }
                    }
                }
                if showSettled, !plan.settled.isEmpty {
                    section("Identical", count: plan.settled.count)
                    ForEach(plan.settled.keys.sorted(), id: \.self) { path in
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(palette.color(.dim))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !plan.problems.isEmpty { problems(plan) }
            }
            .padding(.vertical, 8)
        }
    }

    private func section(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
            Text("\(count)")
                .font(.system(size: 9))
            Spacer()
        }
        .foregroundStyle(palette.color(.dim))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func row(at index: Int, banded: Bool) -> some View {
        let row = rows[index]
        let alarming = row.kind.isConflict || row.action.isDestructive
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(row.kind.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(alarming ? palette.color(.marked) : palette.color(.accent))
                    // Wide enough for the longest verdict there is, "Changed
                    // left, deleted right", on one line: a verdict that wraps
                    // or truncates is one that stops saying where.
                    .frame(width: 158, alignment: .leading)
                Text(pathText(row))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.color(.text))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: $rows[index].action) {
                    ForEach(row.allowed) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .disabled(row.allowed.count < 2)
                .frame(width: 130)
            }
            if let note = row.note {
                Text(note)
                    .font(.system(size: 9))
                    .foregroundStyle(palette.color(.dim))
                    .lineLimit(2)
                    .padding(.leading, 166)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        // Banded so the eye can cross from a path to its control without
        // losing the line, and tinted where the row is one to look twice at.
        .background(row.kind.isConflict
                    ? palette.color(.marked).opacity(0.12)
                    : (banded ? palette.color(.panel).opacity(0.5) : Color.clear))
    }

    /// A rename's two names, shown so it is clear whether they sit on one side
    /// or on opposite ones.
    private func pathText(_ row: SyncDifference) -> String {
        if case .possibleRename = row.kind, let l = row.leftName, let r = row.rightName {
            // Not an arrow: nothing has moved, and neither name is the older.
            return "\(l)  ⇄  \(r)"
        }
        if let from = row.renamedFrom { return "\(from)  →  \(row.path)" }
        return row.path
    }

    private var firstRunNotice: some View {
        notice("There is no record of an earlier sync between these folders, so "
               + "nothing is proposed for deletion: a file on one side alone is "
               + "as likely to be new there as deleted here.")
    }

    private var blindNotice: some View {
        notice("A folder could not be read, so this comparison is incomplete. "
               + "Nothing inside it has been given a verdict.")
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(palette.color(.dim))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }

    private func problems(_ plan: SyncPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            section("Left alone", count: plan.problems.count)
            ForEach(Array(plan.problems.prefix(20).enumerated()), id: \.offset) { _, problem in
                Text(problem.text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(palette.color(.dim))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if plan.problems.count > 20 {
                Text("and \(plan.problems.count - 20) more")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.color(.dim))
                    .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Carry deletions across", isOn: $propagateDeletions)
                    .font(.system(size: 11))
                    .fixedSize()
                    .disabled(applying)
                    .help("Off, a sync only ever adds and replaces, so nothing can "
                          + "be lost. On, a file deleted on one side since the last "
                          + "sync is deleted on the other — always to the Trash.")
                Toggle("Show identical", isOn: $showSettled)
                    .font(.system(size: 11))
                    .fixedSize()
                Spacer()
                Button("Compare again", action: onRescan)
                    .controlSize(.small)
                    .disabled(scanning || applying)
            }
            Text(summary)
                .font(.system(size: 10))
                .foregroundStyle(palette.color(.dim))
                .lineLimit(1)
            HStack {
                Menu("All…") {
                    Button("Accept every suggestion") { reset() }
                    Button("Skip everything") { setAll(.skip) }
                    Button("Send everything right") { setAll(.copyToRight) }
                    Button("Send everything left") { setAll(.copyToLeft) }
                    Button("Skip every deletion") { skipDeletions() }
                }
                .frame(width: 90)
                .disabled(rows.isEmpty || applying)
                Spacer()
                Button(applying ? "Stop" : "Cancel", action: onCancel)
                Button(applyTitle) { onApply(rows) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scanning || applying || !rows.contains { $0.action != .skip })
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: String {
        guard !rows.isEmpty else { return "" }
        var parts: [String] = []
        let right = rows.filter { $0.action == .copyToRight }.count
        let left = rows.filter { $0.action == .copyToLeft }.count
        let renames = rows.filter { $0.action == .renameOnLeft || $0.action == .renameOnRight }.count
        let deletes = rows.filter { $0.action.isDestructive }.count
        let unresolved = rows.filter { $0.kind.isConflict && $0.action == .skip }.count
        if right > 0 { parts.append("\(right) →") }
        if left > 0 { parts.append("← \(left)") }
        if renames > 0 { parts.append("\(renames) renamed") }
        if deletes > 0 { parts.append("\(deletes) to the Trash") }
        if unresolved > 0 { parts.append("\(unresolved) conflict\(unresolved == 1 ? "" : "s") left alone") }
        let bytes = rows.reduce(Int64(0)) { $0 + $1.bytesToCopy }
        if bytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        return parts.isEmpty ? "Nothing chosen" : parts.joined(separator: " · ")
    }

    private var applyTitle: String {
        let doing = rows.filter { $0.action != .skip }.count
        return doing == 0 ? "Sync" : "Sync \(doing)"
    }

    // MARK: - Bulk edits

    private func reset() { rows = plan?.rows ?? [] }

    private func setAll(_ action: SyncAction) {
        for index in rows.indices where rows[index].allowed.contains(action) {
            rows[index].action = action
        }
    }

    private func skipDeletions() {
        for index in rows.indices where rows[index].action.isDestructive {
            rows[index].action = .skip
        }
    }
}
