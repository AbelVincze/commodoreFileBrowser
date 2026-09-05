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
        CommandGroup(replacing: .newItem) {
            Button("New Disk Image…") { model.beginNewImage() }
            Button("New Folder…") { model.beginMakeFolder() }
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Copy to Other Panel") { model.beginTransfer(isMove: false) }
            Button("Move to Other Panel") { model.beginTransfer(isMove: true) }
            Button("Rename…") { model.beginRename() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Delete") { model.beginDelete() }
        }
        CommandGroup(after: .sidebar) {
            Button("Show Hidden Files") {
                settings.showHiddenFiles.toggle()
                model.applyHiddenSetting()
                model.refreshBoth()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh") { model.refreshBoth() }
                .keyboardShortcut("u", modifiers: .command)
            Divider()
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Image") { model.saveActiveImage() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Discard Changes and Leave Image") { model.leaveDiscardingChanges() }
        }
        CommandMenu("Go") {
            Button("Volumes") { model.activePanel.goToVolumes() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Up") { model.activePanel.goUp() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
        CommandMenu("Commodore") {
            Button("View File…") { model.beginView() }
            Button("View as Bitmap…") { model.beginView(bitmap: true) }
            Button("Play as SID…") { model.beginPlay(manual: false) }
            Button("Switch Character Set (Ctrl-Shift)") { model.toggleCharacterSet() }
            Divider()
            Button("Edit Disk Header…") { model.beginEditHeader() }
            Button("Add DEL Entry…") { model.sheet = .addDecoration }
            Button("Toggle Lock (<)") { model.toggleLock() }
            Divider()
            Button("Move Entry Up") { model.moveEntry(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Move Entry Down") { model.moveEntry(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Commodore File Browser Help") { model.sheet = .help }
        }
    }
}
