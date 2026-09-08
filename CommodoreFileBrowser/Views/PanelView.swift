import SwiftUI
import AppKit

enum PanelLayout {
    /// Shared by the header, the rules and the rows so the listing lines up
    /// with the disk header line above it.
    static let inset: CGFloat = 12
    static let infoFont = NSFont.systemFont(ofSize: 9, weight: .semibold)
    static let markerSize: CGFloat = 40
    static var markerFont: NSFont {
        NSFont(name: "DINCondensed-Bold", size: markerSize)
            ?? .systemFont(ofSize: markerSize, weight: .bold)
    }
    /// Distance from a text run's top edge down to its cap height, so runs at
    /// very different sizes can be aligned by the tops of their capitals.
    static func capInset(_ font: NSFont) -> CGFloat { font.ascender - font.capHeight }
}

struct PanelView: View {
    @ObservedObject var panel: PanelModel
    @ObservedObject var settings: SettingsStore
    /// The row menu needs the whole command set, not the two closures below.
    @ObservedObject var model: AppModel
    let palette: Palette
    let isActive: Bool
    /// Shown in the footer of the active panel.
    let status: String
    let onActivate: () -> Void
    let onOpen: () -> Void

    private let inset = PanelLayout.inset

    private struct ClickRecord {
        var id: Int
        var time: Date
    }
    @State private var lastClick: ClickRecord?

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            listing
            rule
            footer
        }
        // No border: the active panel is picked out by a lighter background.
        .background(isActive ? palette.color(.panel) : palette.color(.window))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onActivate() }
    }

    /// Selection happens on the first click. A single count-1 gesture fires
    /// straight away, whereas pairing it with a count-2 gesture makes SwiftUI
    /// hold every click back for the whole double click interval before it can
    /// tell them apart. The second click is recognised here instead.
    private func click(_ item: PanelItem) {
        onActivate()
        panel.moveCursor(to: item.id)

        let now = Date()
        if let last = lastClick, last.id == item.id,
           now.timeIntervalSince(last.time) <= NSEvent.doubleClickInterval {
            lastClick = nil
            onOpen()
        } else {
            lastClick = ClickRecord(id: item.id, time: now)
        }
    }

    /// A hairline inset to line up with the text either side of it.
    private var rule: some View {
        Rectangle()
            .fill(palette.color(.border))
            .frame(height: 1)
            .padding(.horizontal, inset)
    }

    // MARK: - Header

    /// The all caps context line above the path or the disk header.
    private var infoLine: String {
        switch panel.location {
        case .volumes:
            return "FILESYSTEM"
        case .directory(let url):
            let volume = (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? ""
            return volume.isEmpty ? "FILESYSTEM" : "FILESYSTEM: \(volume.uppercased())"
        case .image:
            guard let image = panel.image else { return "DISK IMAGE" }
            var parts = [image.formatName.uppercased()]
            if let note = image.integrityNote { parts.append(note) }
            if image.hasUnsavedChanges { parts.append("MODIFIED") }
            if !image.canWrite { parts.append("READ ONLY") }
            return parts.joined(separator: "   ")
        }
    }

    /// FS for the file system, or the container's own type.
    private var typeMarker: String {
        switch panel.location {
        case .volumes, .directory: return "FS"
        case .image(let url, _): return url.pathExtension.uppercased()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(infoLine)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(palette.color(.dim))
                    .lineLimit(1)
                    .truncationMode(.middle)
                mainLine
            }
            .alignmentGuide(.top) { $0[.top] + PanelLayout.capInset(PanelLayout.infoFont) }
            // Sized before the spacer. Without this the stack shares the offer
            // with it, and the info line — the only thing here that can shrink
            // — is laid out against half the room, truncating while the disk
            // header line below it, whose width is fixed, runs on past the
            // ellipsis. The marker's width is still reserved, so nothing it
            // needs is taken away.
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(typeMarker)
                .font(.typeMarker(PanelLayout.markerSize))
                .foregroundStyle(palette.color(.marker))
                .fixedSize()
                // Claim only down to the baseline. DIN Condensed reports a 48 pt
                // line box at 40 pt against a 28.5 pt ascender, and that empty
                // descent would otherwise set the height of the whole header.
                // The marker text is all capitals and digits, so nothing is
                // drawn below the baseline and nothing is cut off.
                .frame(height: PanelLayout.markerFont.ascender, alignment: .top)
                .alignmentGuide(.top) { $0[.top] - 1 + PanelLayout.capInset(PanelLayout.markerFont) }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var mainLine: some View {
        if let image = panel.image, image.listingStyle == .petscii {
            PETSCIIText(petscii: PanelModel.headerLine(for: image),
                        color: palette.color(.header), zoom: settings.zoom,
                        font: settings.font, reverse: true)
        } else {
            HStack(spacing: 6) {
                Image(systemName: headerIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.color(.dim))
                Text(headerText)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.color(.header))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            // Boxed to the height of a PETSCII line so the two panels, and the
            // two kinds of image header, all sit at the same place.
            .frame(height: CGFloat(8 * settings.zoom))
        }
    }

    private var headerIcon: String {
        if panel.image != nil { return "opticaldiscdrive.fill" }
        return panel.location == .volumes ? "externaldrive.connected.to.line.below" : "folder"
    }

    /// An image drawn as text names its volume, since it has no reverse-video
    /// header line to carry the name; the path inside it follows.
    private var headerText: String {
        guard let image = panel.image else { return panel.headerTitle }
        let volume = image.diskName.isEmpty
            ? panel.location.url?.lastPathComponent ?? ""
            : NameEncoding.latin1.text(image.diskName).trimmingCharacters(in: .whitespaces)
        return (["\(volume):"] + panel.location.imagePath).joined(separator: "/")
    }

    // MARK: - Listing

    private var listing: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(panel.items) { item in
                        PanelRow(item: item,
                                 isCursor: item.id == panel.cursor,
                                 isActive: isActive,
                                 isMarked: panel.marked.contains(item.id),
                                 palette: palette,
                                 font: settings.font,
                                 zoom: settings.zoom,
                                 rowHeight: settings.rowHeight,
                                 usePETSCII: panel.isImagePanel)
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { click(item) }
                            .contextMenu {
                                RowContextMenu(model: model, panel: panel, item: item)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: panel.cursor) { _, new in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(new, anchor: nil) }
            }
            .onChange(of: panel.items.count) { _, _ in
                proxy.scrollTo(panel.cursor, anchor: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = panel.loadError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.color(.marked))
                Text(error).lineLimit(1)
            } else {
                Text(panel.footerText).lineLimit(1)
            }
            Spacer(minLength: 8)
            if isActive, !status.isEmpty {
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(palette.color(.accent))
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(palette.color(.dim))
        .padding(.horizontal, inset)
        .frame(height: 24)
    }
}

struct PanelRow: View {
    let item: PanelItem
    let isCursor: Bool
    let isActive: Bool
    let isMarked: Bool
    let palette: Palette
    /// Taken by value, not read off the settings store. A store is a reference,
    /// so SwiftUI sees an unchanged input and skips redrawing the row; changing
    /// the character ROM then left every row but the header stale until it was
    /// touched.
    let font: PETSCIIFont
    let zoom: Int
    let rowHeight: CGFloat
    let usePETSCII: Bool

    private var foreground: Color {
        if isCursor && isActive { return palette.color(.cursorText) }
        if isMarked { return palette.color(.marked) }
        switch item.kind {
        case .parent: return palette.color(.dim)
        case .folder, .volume, .imageFolder: return palette.color(.directory)
        case .diskImage: return palette.color(.image)
        case .imageFile: return palette.color(.header)
        case .file: return palette.color(.text)
        }
    }

    private var background: Color {
        guard isCursor else { return .clear }
        return isActive ? palette.color(.cursorBackground) : palette.color(.cursorBackground).opacity(0.22)
    }

    /// One trailing column of a row drawn as text.
    private func column(_ text: String, width: CGFloat? = nil, minWidth: CGFloat? = nil) -> some View {
        Text(text)
            // The face and the size the names are set in, so the row reads as
            // one line rather than two. Only the digits are held to an even
            // width: the columns are right aligned, and proportional figures
            // would shuffle them sideways as the listing scrolls past.
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isCursor && isActive ? palette.color(.cursorText).opacity(0.8)
                                                  : palette.color(.dim))
            .frame(width: width, alignment: .trailing)
            .frame(minWidth: minWidth, alignment: .trailing)
    }

    /// Short enough to sit beside a name without crowding it, and the same on
    /// both sides so the columns line up across the two panels.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd-MMM-yy"
        return f
    }()

    private static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }

    private var icon: String {
        switch item.kind {
        case .parent: return "arrow.turn.left.up"
        case .volume: return "externaldrive"
        case .folder, .imageFolder: return "folder.fill"
        case .diskImage: return "opticaldiscdrive.fill"
        case .file, .imageFile: return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if usePETSCII, let line = item.petsciiLine {
                PETSCIIText(petscii: line, color: foreground,
                            zoom: zoom, font: font)
                Spacer(minLength: 0)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .frame(width: 13)
                    .foregroundStyle(foreground.opacity(item.kind == .file ? 0.6 : 1))
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(foreground)
                Spacer(minLength: 8)
                // Trailing columns, each at a width its content cannot outgrow,
                // so the two panels read down the page as columns rather than
                // as three ragged edges. The size is only a floor: a file big
                // enough to need more room takes it from the name, which is the
                // one field here that can be shortened without losing meaning.
                column(item.detail, minWidth: 74)
                if !item.flags.isEmpty { column(item.flags, width: 62) }
                if let modified = item.modified { column(Self.dateText(modified), width: 68) }
            }
        }
        .padding(.horizontal, PanelLayout.inset)
        .frame(height: rowHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .leading) {
            // Sits inside the leading padding, so it never shifts the listing.
            if isMarked {
                Text("▸")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isCursor && isActive ? palette.color(.cursorText)
                                                          : palette.color(.marked))
                    .padding(.leading, 3)
            }
        }
    }
}
