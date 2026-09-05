import SwiftUI

struct FunctionKey: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let action: () -> Void
    var enabled: Bool = true
}

/// The Midnight Commander style key bar: one segment per function key,
/// spread across the whole width and divided by hairlines.
struct FunctionBar: View {
    let palette: Palette
    let keys: [FunctionKey]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                if index > 0 {
                    Rectangle()
                        .fill(palette.color(.border))
                        .frame(width: 1)
                        .padding(.vertical, 5)
                }
                Button(action: key.action) {
                    HStack(spacing: 5) {
                        Text(key.key)
                            .foregroundStyle(palette.color(.dim))
                        Text(key.label.uppercased())
                            .foregroundStyle(key.enabled ? palette.color(.text) : palette.color(.dim))
                    }
                    // Key and label share one size, as on a Commodore key bar.
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!key.enabled)
                .opacity(key.enabled ? 1 : 0.45)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(palette.color(.window))
    }
}
