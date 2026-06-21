import SwiftUI

// Light, almost-clear, tinted glassmorphic palette. Three colors drawn from the
// Sierra photo: snow white, deep sky blue, dark slate. Light-mode feel: dark slate
// text on a barely-tinted clear glass, with sky blue as the single accent.
// All type is SF Pro Rounded (no serif, no mono face).
enum Theme {
    // The 3 colors.
    static let sky   = Color(red: 0x2E/255.0, green: 0x7B/255.0, blue: 0xD6/255.0) // #2E7BD6 deep sky blue (reads on light)
    static let snow  = Color(red: 0xF4/255.0, green: 0xF8/255.0, blue: 0xFD/255.0) // #F4F8FD snow white
    static let slate = Color(red: 0x14/255.0, green: 0x1E/255.0, blue: 0x2A/255.0) // #141E2A dark slate (ink)

    // Single accent (gauges / sparkline / dots).
    static let accent = sky

    // Aliases kept so the views compile; all map into the 3-color palette.
    static let teal    = sky
    static let energy  = sky
    static let success = sky
    static let amber   = sky
    static let danger  = sky

    // Text = dark slate ink at three opacities (light-mode glass).
    static let textPrimary   = slate
    static let textSecondary = slate.opacity(0.62)
    static let textFaint     = slate.opacity(0.42)

    // Very light, barely-there tint laid over the clear glass (keeps it readable
    // while staying "almost clear"). A pale cool snow.
    static let glassTint = Color(red: 0xEC/255.0, green: 0xF2/255.0, blue: 0xFA/255.0) // #ECF2FA
    static let glassTintOpacity: Double = 0.42

    // Ring track / faint structural lines on light glass.
    static let track = slate.opacity(0.12)

    // Bright specular highlight for the top edge of the border.
    static let specular = Color.white

    // Soft neutral shadow.
    static let shadow = Color.black

    static let cornerRadius: CGFloat = 22
}

extension Font {
    // Labels / captions: SF Pro Rounded (clean Apple sans, no serif).
    static func brand(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // Numbers / values: also SF Pro Rounded; callers add .monospacedDigit() so the
    // digits stay tabular (no width jitter) while ticking.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
