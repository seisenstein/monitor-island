import SwiftUI

// Color palette and font helpers for the Monitor Island redesign.
// Hues are lifted from the prompt-weaver identity and brightened for dark glass legibility.
enum Theme {
    // Accent hues (brightened for dark glass).
    static let teal    = Color(red: 0x46/255.0, green: 0xD6/255.0, blue: 0xDB/255.0) // #46D6DB
    static let energy  = Color(red: 0xE6/255.0, green: 0xA7/255.0, blue: 0x65/255.0) // #E6A765
    static let success = Color(red: 0x9F/255.0, green: 0xCB/255.0, blue: 0x72/255.0) // #9FCB72
    static let amber   = Color(red: 0xE0/255.0, green: 0xB1/255.0, blue: 0x4E/255.0) // #E0B14E
    static let danger  = Color(red: 0xE2/255.0, green: 0x70/255.0, blue: 0x5C/255.0) // #E2705C

    // Warm cream text.
    static let textPrimary   = Color(red: 0xF2/255.0, green: 0xEC/255.0, blue: 0xE0/255.0) // #F2ECE0
    static let textSecondary = Color(red: 0xBD/255.0, green: 0xB6/255.0, blue: 0xA8/255.0) // #BDB6A8
    static let textFaint     = Color(red: 0x8C/255.0, green: 0x86/255.0, blue: 0x7C/255.0) // #8C867C

    // Warm espresso glass tint (overlaid on the material/glass).
    static let glassTint = Color(red: 0x26/255.0, green: 0x23/255.0, blue: 0x1D/255.0) // rgb(38,35,29)

    // Faint warm specular highlight for the border.
    static let specular = Color(red: 1.0, green: 0.97, blue: 0.92)

    // Warm-tinted shadow.
    static let shadow = Color(red: 40/255.0, green: 30/255.0, blue: 15/255.0)

    static let cornerRadius: CGFloat = 22
}

extension Font {
    // Fraunces (serif) for big captions / section titles. Falls back to system serif.
    // Use explicit named instances per weight: SwiftUI's .weight() does not reliably
    // pick a variable-font instance for a custom face, so we map to concrete PostScript names.
    static func brand(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if FontLoader.brandAvailable {
            let name: String
            switch weight {
            case .black, .heavy: name = "Fraunces-Black"
            case .bold:          name = "Fraunces-Bold"
            case .semibold:      name = "Fraunces-SemiBold"
            case .medium:        name = "Fraunces-SemiBold"
            case .light, .thin, .ultraLight: name = "Fraunces-Light"
            default:             name = "Fraunces-Regular"
            }
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    // JetBrains Mono for numbers / values. Falls back to system monospaced.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if FontLoader.monoAvailable {
            let name: String
            switch weight {
            case .bold, .heavy, .black: name = "JetBrainsMono-Bold"
            case .medium, .semibold:    name = "JetBrainsMono-Medium"
            default:                    name = "JetBrainsMono-Regular"
            }
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }
}
