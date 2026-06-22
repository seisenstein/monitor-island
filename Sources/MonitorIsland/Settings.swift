import SwiftUI
import AppKit

// MARK: - Color hex extension

extension Color {
    /// Parse a "#RRGGBB", "RRGGBB", or "#RGB" hex string into an sRGB Color.
    /// Returns nil if the input cannot be parsed.
    init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw = String(raw.dropFirst()) }

        // Expand 3-digit shorthand → 6-digit
        if raw.count == 3 {
            raw = raw.map { "\($0)\($0)" }.joined()
        }

        guard raw.count == 6,
              let value = UInt64(raw, radix: 16) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >>  8) & 0xFF) / 255.0
        let b = Double( value        & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Return the color as an uppercase "#RRGGBB" hex string using the sRGB color space.
    /// Returns nil if the conversion fails.
    func toHexString() -> String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((ns.redComponent.clamped(to: 0...1) * 255).rounded())
        let g = Int((ns.greenComponent.clamped(to: 0...1) * 255).rounded())
        let b = Int((ns.blueComponent.clamped(to: 0...1) * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - AppSettings

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let defaultAccentHex = "#36B0B5"   // promptable teal (prompt-weaver dark --teal-bright)

    private let key = "MonitorIsland.accentHex"

    @Published var accent: Color {
        didSet { persist() }
    }

    private init() {
        let stored = UserDefaults.standard.string(forKey: "MonitorIsland.accentHex")
        let hex    = stored ?? AppSettings.defaultAccentHex
        accent     = Color(hex: hex) ?? Color(hex: AppSettings.defaultAccentHex)!
    }

    private func persist() {
        if let hex = accent.toHexString() {
            UserDefaults.standard.set(hex, forKey: key)
        }
    }

    func resetToDefault() {
        accent = Color(hex: AppSettings.defaultAccentHex)!
    }
}

// MARK: - SettingsPanel

struct SettingsPanel: View {
    @ObservedObject var settings: AppSettings
    var onClose: () -> Void

    private let presets: [(name: String, hex: String)] = [
        ("Teal",   "#36B0B5"),
        ("Blue",   "#5EA5F2"),
        ("Violet", "#B98CF0"),
        ("Green",  "#5FD08A"),
        ("Pink",   "#F07AA8"),
        ("Amber",  "#E8A83E"),
        ("Red",    "#FF7B72"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack {
                Text("ACCENT")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundColor(Theme.textFaint)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textFaint)
                }
                .buttonStyle(.plain)
            }

            // Preset swatches
            HStack(spacing: 8) {
                ForEach(presets, id: \.hex) { preset in
                    SwatchButton(
                        hex: preset.hex,
                        isSelected: isSelected(preset.hex),
                        onTap: {
                            if let c = Color(hex: preset.hex) {
                                settings.accent = c
                            }
                        }
                    )
                }
            }

            // Custom color picker
            ColorPicker("Custom", selection: $settings.accent, supportsOpacity: false)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(Theme.textSecondary)

            // Reset button
            Button("Reset") { settings.resetToDefault() }
                .buttonStyle(.plain)
                .font(.system(size: 10, design: .rounded))
                .foregroundColor(Theme.textFaint)
        }
        .frame(maxWidth: 270, alignment: .leading)
    }

    private func isSelected(_ hex: String) -> Bool {
        guard let current = settings.accent.toHexString() else { return false }
        return current.uppercased() == hex.uppercased()
    }
}

// MARK: - SwatchButton helper

private struct SwatchButton: View {
    let hex: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Selection ring (slightly larger, behind the filled circle)
                if isSelected {
                    Circle()
                        .stroke(Theme.snow.opacity(0.9), lineWidth: 2)
                        .frame(width: 22, height: 22)
                }
                Circle()
                    .fill(Color(hex: hex) ?? .clear)
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
    }
}
