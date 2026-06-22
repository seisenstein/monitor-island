import SwiftUI

// Three-color palette from the Sierra photo: snow white, deep sky blue, dark slate.
// Dark glass (the version that reads well): snow text on a dark slate-tinted glass,
// sky blue as the single accent. All type is SF Pro Rounded (no serif, no mono face).
enum Theme {
    // The 3 colors.
    static let sky   = Color(red: 0x4F/255.0, green: 0x97/255.0, blue: 0xEA/255.0) // #4F97EA sky blue (on dark)
    static let snow  = Color(red: 0xEE/255.0, green: 0xF3/255.0, blue: 0xF9/255.0) // #EEF3F9 snow white
    static let slate = Color(red: 0x16/255.0, green: 0x20/255.0, blue: 0x2A/255.0) // #16202A dark slate

    // Single accent (gauges / sparkline / dots).
    static let accent = sky

    // Deliberate, documented exception to the 3-color palette: the memory-pressure
    // escalation. These are used ONLY by the SWAP / pressure gauge and only ever
    // become visible when the kernel reports warning/critical pressure (i.e. when the
    // machine is genuinely approaching or doing SSD swap) — the one moment a warning
    // color earns its keep. Normal pressure stays on `accent` (sky).
    static let pressureWarn     = Color(red: 0xE8/255.0, green: 0xA8/255.0, blue: 0x3E/255.0) // amber
    static let pressureCritical = Color(red: 0xE5/255.0, green: 0x55/255.0, blue: 0x4E/255.0) // red

    // Map the exact kernel pressure level (1 normal, 2 warning, 4 critical) to a color.
    static func pressureColor(level: Int) -> Color {
        switch level {
        case 4:  return pressureCritical
        case 2:  return pressureWarn
        default: return accent
        }
    }

    // Aliases kept so the views compile; all map into the 3-color palette.
    static let teal    = sky
    static let energy  = sky
    static let success = sky
    static let amber   = sky
    static let danger  = sky

    // Text = snow at three opacities.
    static let textPrimary   = snow
    static let textSecondary = snow.opacity(0.66)
    static let textFaint     = snow.opacity(0.40)

    // Dark slate glass tint laid over the clear glass.
    static let glassTint = slate
    static let glassTintOpacity: Double = 0.45

    // Ring track / faint structural lines on dark glass.
    static let track = snow.opacity(0.16)

    // Snow specular highlight for the border.
    static let specular = snow

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
