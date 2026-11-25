import AgtermWinKit
import NativeShim
import WinSDK

extension ChromePalette {
    /// applyToShim pushes the palette into NativeShim for title bar, sidebar tree, and palettes.
    func applyToShim() {
        var palette = nt_chrome_palette(
            chrome_bg: chromeBg, chrome_text: chromeText, chrome_dim: chromeDim, chrome_accent: chromeAccent, chrome_border: chromeBorder,
            sb_bg: sbBg, sb_active_text: sbActiveText, sb_header_text: sbHeaderText, sb_dim: sbDim, sb_highlight: sbHighlight,
            pal_bg: palBg, pal_border: palBorder, pal_sel: palSel, title_hover: titleHover, title_pressed: titlePressed,
            close_hover: closeHover, close_pressed: closePressed, title_inactive: titleInactive, title_disabled: titleDisabled,
            client_bg: clientBg, is_dark: isDark ? 1 : 0)
        nt_set_chrome_colors(&palette)
    }
}