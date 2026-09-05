import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            AppearanceSettings(settings: settings)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            DisplaySettings(settings: settings)
                .tabItem { Label("Display", systemImage: "textformat.size") }
            FileSettings(settings: settings)
                .tabItem { Label("Files", systemImage: "folder") }
        }
        .frame(width: 460)
    }
}

private struct AppearanceSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var editing: ColorScheme = .light

    private var palette: Binding<Palette> {
        editing == .dark ? $settings.dark : $settings.light
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Theme", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Presets").font(.system(size: 11, weight: .medium))
                Spacer()
                ForEach(ThemePresets.all) { preset in
                    Button(preset.name) { settings.apply(preset) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Divider()

            Picker("Editing", selection: $editing) {
                Text("Light colours").tag(ColorScheme.light)
                Text("Dark colours").tag(ColorScheme.dark)
            }
            .pickerStyle(.segmented)

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Palette.Field.allCases) { field in
                        ColorPicker(field.rawValue, selection: Binding(
                            get: { Color(hex: palette.wrappedValue[field]) ?? .gray },
                            set: { palette.wrappedValue[field] = $0.hexString }
                        ))
                        .font(.system(size: 11))
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 190)
        }
        .padding(20)
    }
}

private struct DisplaySettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Character size", selection: $settings.zoom) {
                Text("Small (8 px)").tag(1)
                Text("Medium (16 px)").tag(2)
                Text("Large (24 px)").tag(3)
            }
            Picker("Character ROM", selection: $settings.font.rom) {
                ForEach(CharacterROMVariant.allCases) { Text($0.label).tag($0) }
            }
            Picker("Character set", selection: $settings.font.set) {
                ForEach(CharacterROM.CharSet.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.system(size: 11, weight: .medium))
                VStack(alignment: .leading, spacing: 2) {
                    PETSCIIText(petscii: PETSCII.petscii(fromASCII: "0 \"COMMODORE FILES\" 01 2A"),
                                color: .primary, zoom: settings.zoom, font: settings.font, reverse: true)
                    PETSCIIText(petscii: PETSCII.petscii(fromASCII: "12   \"HELLO WORLD\"     PRG"),
                                color: .primary, zoom: settings.zoom, font: settings.font)
                    PETSCIIText(petscii: PETSCII.petscii(fromASCII: "664 BLOCKS FREE."),
                                color: .primary, zoom: settings.zoom, font: settings.font)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
            }
            Spacer()
        }
        .padding(20)
        .frame(height: 300)
    }
}

private struct FileSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            Toggle("Move deleted files to the Trash", isOn: $settings.deleteToTrash)
            Text("Files scratched from a disk image are always removed from the image itself; the Trash only applies to the file system.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(20)
        .frame(height: 200)
    }
}
