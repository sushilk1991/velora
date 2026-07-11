import AppKit
import SwiftUI

/// Velora's spacing scale. Every HUD inset and gap (and the settings /
/// onboarding layout constants) picks from these five steps so padding stays
/// consistent across the app instead of accreting one-off values.
enum VeloraSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
}

/// Brand palette sampled from `Resources/branding/AppIcon-1024.png`:
/// midnight indigo fading into electric violet behind glowing white
/// waveform bars. The HUD borrows the hue as a whisper, not a costume.
enum VeloraBrand {
    /// Raw sRGB components so per-bar colors can be blended by hand
    /// (`Color.mix` needs macOS 15; the deployment target is 14).
    struct RGB {
        let r: Double
        let g: Double
        let b: Double

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
    }

    /// Midnight indigo (upper stop of the icon gradient, lifted to a midtone).
    static let indigo = RGB(r: 0.26, g: 0.22, b: 0.62)
    /// Electric violet (lower stop of the icon gradient).
    static let violet = RGB(r: 0.55, g: 0.27, b: 0.96)

    /// The brand gradient for icons and accents (top-leading indigo →
    /// bottom-trailing violet, matching the app icon).
    static var iconGradient: LinearGradient {
        LinearGradient(
            colors: [indigo.color, violet.color],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Linear interpolation between two brand colors.
    static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let clamped = min(max(t, 0), 1)
        return RGB(
            r: a.r + (b.r - a.r) * clamped,
            g: a.g + (b.g - a.g) * clamped,
            b: a.b + (b.b - a.b) * clamped)
    }

    /// Waveform bar color at horizontal fraction `t` (0 = leading edge,
    /// 1 = trailing edge): indigo→violet, blended 90 % toward white in dark
    /// mode / 75 % toward black in light mode so bars stay high-contrast
    /// with only a subtle brand tint.
    static func barColor(fraction: Double, darkMode: Bool) -> Color {
        let brand = lerp(indigo, violet, fraction)
        let blended = darkMode
            ? lerp(brand, RGB(r: 1, g: 1, b: 1), 0.90)
            : lerp(brand, RGB(r: 0, g: 0, b: 0), 0.75)
        return blended.color
    }
}

/// HUD geometry for the fixed live card and compact outcome states.
enum HUDGeometry {
    /// Stable live card dimensions. Partial updates never alter this shell,
    /// which keeps the HUD anchored while Whisper revises provisional words.
    static let recordingWidth: CGFloat = 348
    static let recordingHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 20
    static let successWidth: CGFloat = 112
    static let successHeight: CGFloat = 40

    /// Error pill width (icon + one-line message + action button).
    static let errorWidth: CGFloat = 320

    /// Compact-state horizontal inset and live-card element gap.
    static let contentInsetH: CGFloat = VeloraSpacing.l
    static let elementGap: CGFloat = VeloraSpacing.m

    /// Compact live waveform strip beside the transcript.
    static let waveformSize = CGSize(width: 32, height: 24)
    static let timerWidth: CGFloat = 36
    static let chipIconSide: CGFloat = 14
    static let chipIconCornerRadius: CGFloat = VeloraSpacing.xs

    /// Live transcript phrase: enough for two useful lines, selected only on
    /// word/sentence boundaries.
    static let transcriptCharacterLimit = 96
    static let transcriptFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let chipFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)

    /// Width of a single-line string in `font`, rounded up to whole points.
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let bounds = (text as NSString).size(withAttributes: [.font: font])
        return ceil(bounds.width)
    }
}
