import SwiftUI

// Three-color palette from the Sierra photo: snow white, deep sky blue, dark slate.
// Dark glass (the version that reads well): snow text on a dark slate-tinted glass,
// sky blue as the single accent. All type is SF Pro Rounded (no serif, no mono face).
//
// Contrast strategy (WCAG 2.1/2.2 AA): the island never detects its backdrop. Instead
// the slate tint is laid down at near-opaque strength (see glassTintOpacity) so the
// effective background behind the text is always dark, regardless of what is behind the
// window. Every text token was verified >= 4.5:1 (>= 3:1 for the large numbers) composited
// over the worst case (the tint over a pure-white backdrop). sky and the critical red are
// pitched bright enough to clear 4.5:1 as small-label text on that dark scrim.
enum Theme {
    // The 3 colors.
    static let sky   = Color(red: 0x5E/255.0, green: 0xA5/255.0, blue: 0xF2/255.0) // #5EA5F2 sky blue (AA on dark scrim)
    static let snow  = Color(red: 0xEE/255.0, green: 0xF3/255.0, blue: 0xF9/255.0) // #EEF3F9 snow white
    static let slate = Color(red: 0x16/255.0, green: 0x20/255.0, blue: 0x2A/255.0) // #16202A dark slate

    // Single accent (gauges / sparkline / dots).
    static let accent = sky

    // Deliberate, documented exception to the 3-color palette: the memory-pressure
    // escalation. These are used ONLY by the SWAP / pressure gauge and only ever
    // become visible when the kernel reports warning/critical pressure (i.e. when the
    // machine is genuinely approaching or doing SSD swap) — the one moment a warning
    // color earns its keep. Normal pressure stays on `accent` (sky).
    static let pressureWarn     = Color(red: 0xE8/255.0, green: 0xA8/255.0, blue: 0x3E/255.0) // amber (6.3:1 on scrim)
    static let pressureCritical = Color(red: 0xFF/255.0, green: 0x7B/255.0, blue: 0x72/255.0) // bright red (5.2:1 on scrim)

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

    // Text = snow at three opacities. Faint is 0.60 (not lower) so even the small
    // structural labels (MEMORY / TEMP / NET, GPU ACTIVITY) clear 4.5:1 on the scrim.
    static let textPrimary   = snow
    static let textSecondary = snow.opacity(0.66)
    static let textFaint     = snow.opacity(0.60)

    // Slate tint laid over the glass. Near-opaque (0.92) so the effective background is
    // always dark enough for snow/sky text to meet WCAG AA no matter what is behind the
    // window — the "guaranteed scrim" in place of backdrop detection. ~8% glass/backdrop
    // shimmer still bleeds through (the most translucency that still passes over white).
    static let glassTint = slate
    static let glassTintOpacity: Double = 0.92

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
