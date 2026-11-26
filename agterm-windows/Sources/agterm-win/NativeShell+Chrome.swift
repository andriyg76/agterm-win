import AgtermWinKit
import NativeShim
import WinSDK
import agtermCore

extension NativeShell {
    private static let dividerSlop: Int32 = 4

    var chromePalette: ChromePalette {
        ChromePalette.recompute(theme: NativeTerminal.theme, sidebarTint: settings.sidebarTint)
    }

    func applyChrome() {
        let colors = chromePalette
        colors.applyToShim()
        if let tree { nt_tree_apply_colors(tree) }
        if let palette { nt_palette_apply_chrome(palette) }
        SettingsWindow.current?.applyChrome()
        noticeWindow?.invalidate()
        refreshClientBrushes(colors)
        invalidateTitleBar()
        invalidateSidebarFooter()
        if let window { InvalidateRect(window, nil, false) }
    }

    private func refreshClientBrushes(_ palette: ChromePalette) {
        DeleteObject(darkBrush)
        darkBrush = CreateSolidBrush(ChromePalette.colorref(palette.clientBg))
        DeleteObject(highlightBrush)
        highlightBrush = CreateSolidBrush(ChromePalette.colorref(palette.palSel))
    }

    /// sidebarWidth is the tree column in client pixels at the current DPI.
    var sidebarWidth: Int32 {
        settings.sidebarVisible ? scaled(Int32(settings.sidebarWidthPoints.rounded())) : 0
    }

    var sidebarVisible: Bool { settings.sidebarVisible }

    func setSidebarVisible(_ visible: Bool) {
        settings.sidebarVisible = visible
        saveSettings()
        layout()
    }

    func setSidebarWidth(points: Double) {
        settings.sidebarWidthPoints = AppStore.clampSidebarWidth(points)
        saveSettings()
        layout()
        invalidateTitleBar()
    }

    var sidebarWidthPoints: Double { settings.sidebarWidthPoints }

    func onSidebarDivider(x: Int32) -> Bool {
        guard settings.sidebarVisible else { return false }
        let edge = sidebarWidth
        let slop = scaled(Self.dividerSlop)
        return x >= edge - slop && x <= edge + slop
    }

    func sidebarResizeDrag(x: Int32) {
        let points = Double(x) * 96 / Double(dpi)
        setSidebarWidth(points: points)
    }
}
