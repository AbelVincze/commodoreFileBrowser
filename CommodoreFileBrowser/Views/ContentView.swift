import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    @Environment(\.colorScheme) private var systemScheme
    @State private var keyMonitor: Any?

    private var palette: Palette { settings.palette(for: systemScheme) }
    private var scheme: ColorScheme { settings.appearance.colorScheme ?? systemScheme }
    /// Measured from AppKit: the system title bar is 32 pt tall and the window
    /// buttons span x 9...69 with their centres 16 pt below the window top.
    private let systemTitleBarHeight: CGFloat = 32
    private let titleLeading: CGFloat = 86
    /// One gap value used above, beside and below the columns. The title band
    /// and the key bar both centre their text in their own height, and those
    /// two slacks are within half a point of each other, so reusing the same
    /// padding makes the gap above the columns match the gap below them.
    private let contentPadding: CGFloat = 8

    var body: some View {
        // The whole thing ignores the safe area and clears the title bar with
        // its own padding, so the offset is the same whether or not SwiftUI
        // decides to inset for the title bar itself.
        ZStack(alignment: .top) {
            palette.color(.window)
            VStack(spacing: 0) {
                titleBar
                panels
                    .padding(.horizontal, contentPadding)
                    .padding(.bottom, contentPadding)

                FunctionBar(palette: palette, keys: functionKeys)
                    // The bar sits behind whatever is modal and so is already
                    // out of reach; this says so rather than relying on it.
                    .disabled(model.isPresentingModal)
            }
        }
        .ignoresSafeArea()
        .background(WindowStyler(background: palette.color(.window), scheme: scheme))
        .preferredColorScheme(settings.appearance.colorScheme)
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .sheet(item: $model.sheet) { sheet in sheetView(sheet) }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.alertMessage != nil },
                                    set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    /// Stands in for the hidden system title bar: the traffic lights are drawn
    /// over it by AppKit, so the text starts clear of them.
    private var titleBar: some View {
        HStack(spacing: 0) {
            Text("Commodore File Browser")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.color(.header))
            Spacer(minLength: 0)
        }
        .padding(.leading, titleLeading)
        // Centred in the system bar's own height, which puts it on the same
        // line as the window buttons.
        .frame(height: systemTitleBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, contentPadding)
    }

    /// A plain splitter rather than HSplitView, whose divider paints a hard
    /// black seam across the otherwise solid background.
    private var panels: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let handle: CGFloat = 8
            let minimum: CGFloat = 300
            let leftWidth = min(max(total * settings.splitFraction, minimum),
                                max(minimum, total - minimum - handle))
            HStack(spacing: 0) {
                panel(model.left, side: .left).frame(width: leftWidth)
                Rectangle()
                    .fill(palette.color(.window))
                    .frame(width: handle)
                    .contentShape(Rectangle())
                    .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                    .gesture(
                        DragGesture(coordinateSpace: .named("panels"))
                            .onChanged { value in
                                guard total > 0 else { return }
                                settings.splitFraction = min(max(value.location.x / total, 0.2), 0.8)
                            }
                    )
                panel(model.right, side: .right).frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "panels")
        }
    }

    private func panel(_ p: PanelModel, side: PanelSide) -> some View {
        PanelView(panel: p,
                  settings: settings,
                  model: model,
                  palette: palette,
                  isActive: model.activeSide == side,
                  status: model.statusMessage,
                  onActivate: { model.activeSide = side },
                  onOpen: { model.activeSide = side; model.activateItem() })
    }

    private var functionKeys: [FunctionKey] {
        [
            FunctionKey(key: "F1", label: "Help") { model.sheet = .help },
            FunctionKey(key: "F2", label: "Image") { model.beginNewImage() },
            FunctionKey(key: "F3", label: "View") { model.beginView() },
            FunctionKey(key: "F4", label: "Header") { model.beginEditHeader() },
            FunctionKey(key: "F5", label: "Copy") { model.beginTransfer(isMove: false) },
            FunctionKey(key: "F6", label: "Move") { model.beginTransfer(isMove: true) },
            FunctionKey(key: "F7", label: "MkDir") { model.beginMakeFolder() },
            FunctionKey(key: "F8", label: "Delete") { model.beginDelete() },
            FunctionKey(key: "F9", label: "Rename") { model.beginRename() },
            FunctionKey(key: "F10", label: "Quit") { NSApp.terminate(nil) }
        ]
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                model.handleFlags(event)
                return event
            }
            return model.handleKey(event) ? nil : event
        }
    }

    @ViewBuilder
    private func sheetView(_ sheet: AppSheet) -> some View {
        switch sheet {
        case .transfer(let plan):
            TransferSheet(plan: plan, palette: palette,
                          onCancel: { model.sheet = nil },
                          onConfirm: { model.sheet = nil; model.perform($0) })
        case .delete(let items):
            DeleteSheet(items: items, toTrash: settings.deleteToTrash, palette: palette,
                        onCancel: { model.sheet = nil },
                        onConfirm: { model.sheet = nil; model.performDelete(items) })
        case .rename(let item):
            TextPromptSheet(title: "Rename", label: "New name", confirmTitle: "Rename",
                            text: item.title, palette: palette,
                            onCancel: { model.sheet = nil },
                            onConfirm: { model.sheet = nil; model.performRename(item, to: $0) })
        case .makeFolder:
            TextPromptSheet(title: "New folder", label: "Name", confirmTitle: "Create",
                            text: "", palette: palette,
                            onCancel: { model.sheet = nil },
                            onConfirm: { model.sheet = nil; model.performMakeFolder(named: $0) })
        case .newImage:
            NewImageSheet(palette: palette,
                          onCancel: { model.sheet = nil },
                          onConfirm: { kind, option, file, name, id in
                              model.sheet = nil
                              model.performNewImage(kind: kind, option: option, fileName: file,
                                                    diskName: name, diskID: id)
                          })
        case .diskHeader:
            DiskHeaderSheet(palette: palette,
                            name: model.activePanel.image?.displayDiskName ?? "",
                            id: PETSCII.ascii(Array((model.activePanel.image?.diskID ?? []).prefix(2))),
                            wantsID: model.activePanel.image?.diskID != nil,
                            onCancel: { model.sheet = nil },
                            onConfirm: { name, id in
                                model.sheet = nil
                                model.performEditHeader(name: name, id: id)
                            })
        case .addDecoration:
            TextPromptSheet(title: "Add DEL entry", label: "Text", confirmTitle: "Add",
                            text: "----------------", palette: palette,
                            onCancel: { model.sheet = nil },
                            onConfirm: { model.sheet = nil; model.addDecorativeEntry(named: $0) })
        case .discardChanges:
            DiscardChangesSheet(imageName: model.activePanel.headerTitle,
                                palette: palette,
                                onCancel: { model.sheet = nil },
                                onSave: { model.sheet = nil; model.performSaveAndLeave() },
                                onDiscard: { model.sheet = nil; model.performDiscard() })
        case .player:
            if let request = model.playerRequest {
                // .id rebuilds the sheet's contents for a new tune while the
                // sheet itself stays presented.
                SIDPlayerSheet(request: request, palette: palette, player: model.player,
                               settings: settings,
                               onClose: { model.player.stop(); model.sheet = nil })
                    .id(request.id)
            }
        case .module:
            if let request = model.moduleRequest {
                // .id rebuilds the contents for a new module while the sheet
                // itself stays presented, as the SID sheet does.
                ModulePlayerSheet(request: request, palette: palette,
                                  player: model.modulePlayer, settings: settings,
                                  onClose: { model.modulePlayer.unload(); model.sheet = nil })
                    .id(request.id)
            }
        case .sample:
            if let request = model.sampleRequest {
                SamplePlayerSheet(request: request, palette: palette,
                                  player: model.samplePlayer, settings: settings,
                                  onClose: { model.samplePlayer.unload(); model.sheet = nil })
                    .id(request.id)
            }
        case .viewer(let content):
            ViewerSheet(content: content, palette: palette, settings: settings,
                        onClose: { model.sheet = nil })
        case .help:
            HelpSheet(palette: palette, onClose: { model.sheet = nil })
        }
    }
}
