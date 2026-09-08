import SwiftUI

@main
struct CommodoreFileBrowserApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: SettingsStore
    @StateObject private var model: AppModel

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: AppModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, settings: settings)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear { appDelegate.model = model }
        }
        // The browser paints its own title bar area, so the system one is
        // hidden: a WindowGroup keeps its own background behind a standard
        // title bar no matter what backgroundColor is set on the window.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1080, height: 700)
        .commands { menuCommands }

        Settings {
            SettingsView(settings: settings)
        }
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        // The standard About item, kept in its usual place, but pointed at our
        // own panel so it carries a description and the credit line.
        CommandGroup(replacing: .appInfo) {
            Button("About Commodore File Browser") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {
            // Everything below acts on a panel, so all of it goes grey while a
            // sheet or the error alert is up. The key monitor swallows the
            // chords; this is the same rule for the mouse, and it is why the
            // items look unavailable rather than quietly doing nothing.
            Group {
                Button("New Disk Image…") { model.beginNewImage() }
                Button("New Folder…") { model.beginMakeFolder() }
            }
            .disabled(model.isPresentingModal)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Group {
                // Handing a file to the system, never navigating: walking into a
                // folder or an image is Return's job.
                Button("Open") { model.openWithSystem() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Show in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Unpack Archive to ADF") { model.unpackArchive() }
                Divider()
                Button("Copy to Other Panel") { model.beginTransfer(isMove: false) }
                Button("Move to Other Panel") { model.beginTransfer(isMove: true) }
                Button("Rename…") { model.beginRename() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Delete") { model.beginDelete() }
            }
            .disabled(model.isPresentingModal)
        }
        CommandGroup(after: .sidebar) {
            Group {
                Button("Show Hidden Files") {
                    settings.showHiddenFiles.toggle()
                    model.applyHiddenSetting()
                    model.refreshBoth()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Refresh") { model.refreshBoth() }
                    .keyboardShortcut("u", modifiers: .command)
            }
            .disabled(model.isPresentingModal)
            Divider()
        }
        CommandGroup(replacing: .saveItem) {
            Group {
                Button("Save Image") { model.saveActiveImage() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Discard Changes and Leave Image") { model.leaveDiscardingChanges() }
            }
            .disabled(model.isPresentingModal)
        }
        CommandMenu("Go") {
            Group {
                Button("Volumes") { model.activePanel.goToVolumes() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Up") { model.activePanel.goUp() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
            .disabled(model.isPresentingModal)
        }
        CommandMenu("Commodore") {
            Group {
                Button("View File…") { model.beginView() }
                Button("View as Bitmap…") { model.beginView(bitmap: true) }
                Button("Play as SID…") { model.beginPlay(manual: false) }
                // Ctrl-Shift is the C64 gesture and is handled in the key monitor,
                // but a modifier-only chord is at the mercy of anything the system
                // has bound to those two keys — input source switching, most often.
                // This is the route that cannot be taken away.
                Button("Switch Character Set (or Ctrl-Shift)") { model.toggleCharacterSet() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Edit Disk Header…") { model.beginEditHeader() }
                Button("Repair Disk (Validate)…") { model.beginRepairDisk() }
                    .disabled(model.repairableImage == nil)
                Button("Add DEL Entry…") { model.sheet = .addDecoration }
                Button("Toggle Lock (<)") { model.toggleLock() }
                Divider()
                // Rearranging a directory is a Commodore listing's trick. An Amiga
                // hash table has no order to move a row within, so the items go
                // grey rather than offering a move that can only be refused.
                Button("Move Entry Up") { model.moveEntry(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                    .disabled(!model.canReorderEntries)
                Button("Move Entry Down") { model.moveEntry(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .disabled(!model.canReorderEntries)
            }
            .disabled(model.isPresentingModal)
        }
        CommandGroup(replacing: .help) {
            Button("Commodore File Browser Help") { model.sheet = .help }
                .disabled(model.isPresentingModal)
        }
    }
}
