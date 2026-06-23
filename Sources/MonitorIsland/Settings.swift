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
    static let defaultAccentHex = "#36B0B5"

    // The default accent presets (moved here from SettingsPanel so the custom cap can mirror the count).
    static let presets: [(name: String, hex: String)] = [
        ("Teal",   "#36B0B5"),
        ("Blue",   "#5EA5F2"),
        ("Violet", "#B98CF0"),
        ("Green",  "#5FD08A"),
        ("Pink",   "#F07AA8"),
        ("Amber",  "#E8A83E"),
        ("Red",    "#FF7B72"),
    ]
    var maxCustom: Int { AppSettings.presets.count }   // users may save as many customs as there are defaults

    private let accentKey = "MonitorIsland.accentHex"
    private let customKey = "MonitorIsland.customAccents"

    @Published var accent: Color { didSet { persistAccent() } }
    @Published var customAccents: [String]   // saved custom hex strings, most-recent last, capped at maxCustom

    private init() {
        let hex = UserDefaults.standard.string(forKey: "MonitorIsland.accentHex") ?? AppSettings.defaultAccentHex
        accent = Color(hex: hex) ?? Color(hex: AppSettings.defaultAccentHex)!
        customAccents = UserDefaults.standard.stringArray(forKey: "MonitorIsland.customAccents") ?? []
    }

    private func persistAccent() {
        if let h = accent.toHexString() { UserDefaults.standard.set(h, forKey: accentKey) }
    }
    private func persistCustom() { UserDefaults.standard.set(customAccents, forKey: customKey) }

    func select(hex: String) { if let c = Color(hex: hex) { accent = c } }

    /// Save a new custom accent (dedupe case-insensitively; cap at maxCustom, evicting the oldest) and select it.
    func addCustom(hex: String) {
        let up = hex.uppercased()
        customAccents.removeAll { $0.uppercased() == up }
        customAccents.append(up)
        if customAccents.count > maxCustom { customAccents.removeFirst(customAccents.count - maxCustom) }
        persistCustom()
        select(hex: up)
    }

    func removeCustom(hex: String) {
        let up = hex.uppercased()
        customAccents.removeAll { $0.uppercased() == up }
        persistCustom()
    }
}

// MARK: - SettingsPanel

struct SettingsPanel: View {
    @ObservedObject var settings: AppSettings
    var onClose: () -> Void

    // Picker state
    @State private var showPicker = false
    @State private var hue: Double = 0.5
    @State private var sat: Double = 0.8
    @State private var bri: Double = 0.9
    @State private var hexText: String = ""
    @State private var hexFieldFocused = false
    @State private var footerHovered = false

    // Working color derived from HSB state
    private var workingColor: Color {
        Color(hue: hue, saturation: sat, brightness: bri)
    }
    private var workingHex: String {
        workingColor.toHexString() ?? "#000000"
    }

    init(settings: AppSettings, onClose: @escaping () -> Void) {
        self.settings = settings
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // (a) Header row
            headerRow

            // (b) Default accents
            accentSection(caption: "DEFAULT ACCENTS") { defaultSwatches }

            // (c) Custom accents
            accentSection(caption: "CUSTOM ACCENTS") { customSwatches }

            // (d) In-widget color picker
            if showPicker {
                colorPickerPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // (e) Footer — Promptable branding
            footerDivider
            footerBranding
        }
        .frame(maxWidth: 270, alignment: .leading)
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("APPEARANCE")
                .font(.brand(9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Theme.textFaint)
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textFaint)
                    .frame(width: 20, height: 20)
                    .background(Theme.slate.opacity(0.4))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func accentSection<Content: View>(caption: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.brand(9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(Theme.textFaint)
            content()
        }
    }

    private var defaultSwatches: some View {
        HStack(spacing: 7) {
            ForEach(AppSettings.presets, id: \.hex) { preset in
                SwatchButton(
                    hex: preset.hex,
                    isSelected: isSelected(preset.hex)
                ) {
                    settings.select(hex: preset.hex)
                }
            }
        }
    }

    @ViewBuilder
    private var customSwatches: some View {
        HStack(spacing: 7) {
            ForEach(settings.customAccents, id: \.self) { hex in
                RemovableSwatchButton(
                    hex: hex,
                    isSelected: isSelected(hex),
                    onTap: { settings.select(hex: hex) },
                    onRemove: { settings.removeCustom(hex: hex) }
                )
            }

            // "+" add button
            let atCap = settings.customAccents.count >= settings.maxCustom
            Button {
                if !atCap {
                    openPicker()
                }
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(
                            showPicker ? settings.accent : Theme.textFaint.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])
                        )
                        .frame(width: 22, height: 22)
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(
                            showPicker ? settings.accent : (atCap ? Theme.textFaint.opacity(0.3) : Theme.textFaint.opacity(0.7))
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(atCap)
            .opacity(atCap ? 0.35 : 1)

            Spacer()
        }
    }

    // MARK: - Color Picker Panel

    private var colorPickerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Divider
            Rectangle()
                .fill(Theme.textFaint.opacity(0.12))
                .frame(height: 1)

            // Saturation/Brightness square
            SBSquare(hue: hue, sat: $sat, bri: $bri)

            // Hue rainbow slider
            HueSlider(hue: $hue)

            // Hex + eyedropper + preview + actions
            HStack(spacing: 8) {
                // Hex text field
                HStack(spacing: 2) {
                    Text("#")
                        .font(.mono(10))
                        .foregroundColor(Theme.textFaint)
                    TextField("RRGGBB", text: $hexText, onCommit: {
                        commitHexText()
                    })
                    .font(.mono(10))
                    .foregroundColor(Theme.textPrimary)
                    .textFieldStyle(.plain)
                    .frame(width: 58)
                    .onAppear {
                        hexText = String(workingHex.dropFirst()) // strip the "#"
                    }
                    .onChange(of: workingHex) { newHex in
                        if !hexFieldFocused {
                            hexText = String(newHex.dropFirst())
                        }
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Theme.slate.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.snow.opacity(0.1), lineWidth: 1)
                )

                // Eyedropper
                Button {
                    NSColorSampler().show { picked in
                        if let c = picked?.usingColorSpace(.deviceRGB) {
                            hue = Double(c.hueComponent)
                            sat = Double(c.saturationComponent)
                            bri = Double(c.brightnessComponent)
                        }
                    }
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.slate.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Theme.snow.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                // Live preview swatch
                Circle()
                    .fill(workingColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(Theme.snow.opacity(0.2), lineWidth: 1))

                Spacer()
            }

            // Cancel / Add row
            HStack(spacing: 8) {
                Spacer()

                Button("Cancel") {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showPicker = false
                    }
                }
                .buttonStyle(.plain)
                .font(.brand(11, weight: .medium))
                .foregroundColor(Theme.textFaint)

                Button("Add") {
                    settings.addCustom(hex: workingHex)
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        showPicker = false
                    }
                }
                .buttonStyle(.plain)
                .font(.brand(11, weight: .semibold))
                .foregroundColor(Theme.snow)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(settings.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Theme.slate.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.snow.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footerDivider: some View {
        Rectangle()
            .fill(Theme.textFaint.opacity(0.15))
            .frame(height: 1)
            .padding(.top, 2)
    }

    private var footerBranding: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://promptable.us")!)
        } label: {
            VStack(spacing: 4) {
                PromptableLogo(accent: settings.accent, height: 18)
                    .opacity(footerHovered ? 1.0 : 0.75)
                HStack(spacing: 3) {
                    Text("promptable.us")
                        .font(.mono(9))
                        .foregroundColor(Theme.textFaint)
                        .opacity(footerHovered ? 0.9 : 0.6)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Theme.textFaint)
                        .opacity(footerHovered ? 0.9 : 0.6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                footerHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: - Helpers

    private func isSelected(_ hex: String) -> Bool {
        guard let current = settings.accent.toHexString() else { return false }
        return current.uppercased() == hex.uppercased()
    }

    private func openPicker() {
        // Initialize HSB from current accent
        if let ns = NSColor(settings.accent).usingColorSpace(.deviceRGB) {
            hue = Double(ns.hueComponent)
            sat = Double(ns.saturationComponent)
            bri = Double(ns.brightnessComponent)
        }
        hexText = String((workingHex).dropFirst())
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            showPicker = true
        }
    }

    private func commitHexText() {
        hexFieldFocused = false
        let cleaned = hexText.trimmingCharacters(in: .whitespacesAndNewlines)
        let withHash = cleaned.hasPrefix("#") ? cleaned : "#\(cleaned)"
        if let parsed = NSColor(Color(hex: withHash) ?? .clear).usingColorSpace(.deviceRGB) {
            // Only update if it actually parsed (non-zero saturation check for black is fine)
            if Color(hex: withHash) != nil {
                hue = Double(parsed.hueComponent)
                sat = Double(parsed.saturationComponent)
                bri = Double(parsed.brightnessComponent)
            }
        }
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
                if isSelected {
                    Circle()
                        .stroke(Theme.snow.opacity(0.9), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
                Circle()
                    .fill(Color(hex: hex) ?? .clear)
                    .frame(width: 18, height: 18)
                    .shadow(color: (Color(hex: hex) ?? .clear).opacity(0.4), radius: 4, x: 0, y: 2)
            }
            .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - RemovableSwatchButton (custom dots with ✕ hover badge)

private struct RemovableSwatchButton: View {
    let hex: String
    let isSelected: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Main swatch
            Button(action: onTap) {
                ZStack {
                    if isSelected {
                        Circle()
                            .stroke(Theme.snow.opacity(0.9), lineWidth: 2)
                            .frame(width: 24, height: 24)
                    }
                    Circle()
                        .fill(Color(hex: hex) ?? .clear)
                        .frame(width: 18, height: 18)
                        .shadow(color: (Color(hex: hex) ?? .clear).opacity(0.4), radius: 4, x: 0, y: 2)
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)

            // ✕ remove badge — appears on hover
            if hovered {
                Button(action: onRemove) {
                    ZStack {
                        Circle()
                            .fill(Theme.slate)
                            .frame(width: 11, height: 11)
                        Image(systemName: "xmark")
                            .font(.system(size: 5.5, weight: .bold))
                            .foregroundColor(Theme.snow.opacity(0.85))
                    }
                }
                .buttonStyle(.plain)
                .offset(x: 3, y: -3)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.12)) {
                hovered = h
            }
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - SBSquare (Saturation / Brightness picker square)

private struct SBSquare: View {
    var hue: Double
    @Binding var sat: Double
    @Binding var bri: Double

    var body: some View {
        GeometryReader { g in
            ZStack {
                // White → full hue horizontal gradient
                LinearGradient(
                    colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Clear → black vertical overlay
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Draggable knob
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(
                        Circle()
                            .fill(Color(hue: hue, saturation: sat, brightness: bri))
                    )
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                    .position(
                        x: (sat * g.size.width).clamped(to: 0...g.size.width),
                        y: ((1 - bri) * g.size.height).clamped(to: 0...g.size.height)
                    )
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                sat = (v.location.x / g.size.width).clamped(to: 0...1)
                bri = (1 - v.location.y / g.size.height).clamped(to: 0...1)
            })
        }
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.snow.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - HueSlider

private struct HueSlider: View {
    @Binding var hue: Double

    private let stops: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 6.0)
        .map { Color(hue: $0, saturation: 1, brightness: 1) }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                // Draggable knob
                Circle()
                    .strokeBorder(.white, lineWidth: 2)
                    .background(Circle().fill(Color(hue: hue, saturation: 1, brightness: 1)))
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                    .position(
                        x: (hue * g.size.width).clamped(to: 0...g.size.width),
                        y: g.size.height / 2
                    )
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hue = (v.location.x / g.size.width).clamped(to: 0...1)
            })
        }
        .frame(height: 16)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.snow.opacity(0.12), lineWidth: 1))
    }
}
