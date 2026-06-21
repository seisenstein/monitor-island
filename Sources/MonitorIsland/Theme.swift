import SwiftUI

// Three-color palette drawn from the Sierra mountain photo: snow white, deep sky
// blue, dark slate. Everything else is an opacity of one of these three.
// Anthropic-clean: SF Pro Rounded for all type (no serif, no mono face).
enum Theme {
    // The 3 colors.
    static let sky   = Color(red: 0x4F/255.0, green: 0x97/255.0, blue: 0xEA/255.0) // #4F97EA deep sky blue
    static let snow  = Color(red: 0xEE/255.0, green: 0xF3/255.0, blue: 0xF9/255.0) // #EEF3F9 snow white
    static let slate = Color(red: 0x16/255.0, green: 0x20/255.0, blue: 0x2A/255.0) // #16202A dark slate

    // The single accent (all gauges / sparkline / dots use it).
    static let accent = sky

    // Named aliases kept so the views compile; all map into the 3-color palette.
    static let teal    = sky
    static let energy  = sky
    static let success = sky
    static let amber   = sky
    static let danger  = sky

    // Text = snow at three opacities.
    static let textPrimary   = snow
    static let textSecondary = snow.opacity(0.66)
    static let textFaint     = snow.opacity(0.40)

    // Cool slate glass tint (overlaid on the material/glass).
    static let glassTint = slate

    // Snow specular highlight for the border.
    static let specular = snow

    // Neutral shadow.
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
