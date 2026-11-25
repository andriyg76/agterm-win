import Foundation

/// ChromePalette is every native chrome color derived from the active terminal theme, as agwinterm's
/// `RecomputeChrome` derives title bar, sidebar, and overlay colors from the terminal background.
public struct ChromePalette: Equatable, Sendable {
    public var isDark: Bool
    public var chromeBg, chromeText, chromeDim, chromeAccent, chromeBorder: UInt32
    public var sbBg, sbActiveText, sbHeaderText, sbDim, sbHighlight: UInt32
    public var palBg, palBorder, palSel: UInt32
    public var titleHover, titlePressed, closeHover, closePressed: UInt32
    public var titleInactive, titleDisabled, clientBg: UInt32

    /// Default terminal colors when no theme file is selected.
    public static let defaultBackground: UInt32 = 0x0C0C0C
    public static let defaultForeground: UInt32 = 0xCCCCCC

    /// recompute builds a palette from `theme` and a sidebar tint in agwinterm's -100...100 range.
    public static func recompute(theme: TerminalTheme?, sidebarTint: Int = 0) -> ChromePalette {
        let bg = theme?.background ?? defaultBackground
        let fg = theme?.foreground ?? defaultForeground
        let dark = luminance(bg) < 0.5

        let chromeBg = shade(bg, dark ? -0.42 : -0.06)
        var sidebar = shade(bg, dark ? -0.28 : -0.09)
        let tint = min(100, max(-100, sidebarTint))
        let tintAmount = Float(tint) / 100 * (dark ? 0.6 : 0.4)
        let sbBg = shade(sidebar, tintAmount)
        let palBg = shade(bg, dark ? 0.07 : -0.04)

        var accent = color(theme, index: 12, fallback: fg)
        if luminance(accent) < 0.22, let alt = theme?.palette[4] {
            accent = alt
        }
        if luminance(accent) < 0.18 { accent = 0x4D8CF2 }

        let chromeText = mix(fg, bg, 0.04)
        let chromeDim = mix(fg, bg, dark ? 0.42 : 0.40)
        let sbActiveText = fg
        let sbHeaderText = mix(fg, bg, 0.20)
        let sbDim = chromeDim
        let sbHighlight = mix(sbBg, fg, 0.14)
        let chromeBorder = mix(bg, fg, dark ? 0.20 : 0.26)
        let palBorder = mix(palBg, fg, dark ? 0.28 : 0.30)
        let palSel = mix(palBg, accent, dark ? 0.45 : 0.32)

        let titleHover = mix(chromeBg, chromeText, dark ? 0.12 : 0.08)
        let titlePressed = mix(chromeBg, chromeText, dark ? 0.18 : 0.14)
        let closeHover: UInt32 = 0xC42B1C
        let closePressed: UInt32 = 0x9F2216
        let titleInactive = mix(chromeText, chromeBg, 0.55)
        let titleDisabled: UInt32 = 0x6E6E6E

        return ChromePalette(isDark: dark, chromeBg: chromeBg, chromeText: chromeText, chromeDim: chromeDim, chromeAccent: accent,
                             chromeBorder: chromeBorder, sbBg: sbBg, sbActiveText: sbActiveText, sbHeaderText: sbHeaderText, sbDim: sbDim,
                             sbHighlight: sbHighlight, palBg: palBg, palBorder: palBorder, palSel: palSel, titleHover: titleHover,
                             titlePressed: titlePressed, closeHover: closeHover, closePressed: closePressed, titleInactive: titleInactive,
                             titleDisabled: titleDisabled, clientBg: chromeBg)
    }

    /// colorref is a palette color (0xRRGGBB) in Win32's COLORREF order, 0x00BBGGRR.
    public static func colorref(_ rgb: UInt32) -> UInt32 {
        (rgb & 0xFF) << 16 | (rgb & 0xFF00) | (rgb >> 16 & 0xFF)
    }

    private static func color(_ theme: TerminalTheme?, index: Int, fallback: UInt32) -> UInt32 {
        theme?.palette[index] ?? fallback
    }

    private static func luminance(_ rgb: UInt32) -> Float {
        let r = Float((rgb >> 16) & 0xFF) / 255
        let g = Float((rgb >> 8) & 0xFF) / 255
        let b = Float(rgb & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

  private static func mix(_ a: UInt32, _ b: UInt32, _ t: Float) -> UInt32 {
        let (ar, ag, ab) = components(a)
        let (br, bg, bb) = components(b)
        return rgb(ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t)
    }

    private static func shade(_ rgb: UInt32, _ amount: Float) -> UInt32 {
        if amount >= 0 { return mix(rgb, 0xFFFFFF, amount) }
        return mix(rgb, 0x000000, -amount)
    }

    private static func components(_ rgb: UInt32) -> (Float, Float, Float) {
        (Float((rgb >> 16) & 0xFF) / 255, Float((rgb >> 8) & 0xFF) / 255, Float(rgb & 0xFF) / 255)
    }

    private static func rgb(_ r: Float, _ g: Float, _ b: Float) -> UInt32 {
        UInt32(min(255, max(0, Int(r * 255 + 0.5)))) << 16 | UInt32(min(255, max(0, Int(g * 255 + 0.5)))) << 8
            | UInt32(min(255, max(0, Int(b * 255 + 0.5))))
    }
}