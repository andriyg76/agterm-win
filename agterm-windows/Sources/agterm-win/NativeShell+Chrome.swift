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

    var fullscreen: Bool { beforeFullscreen != nil }

    /// setFullscreen covers the window's monitor with the client alone, as Windows Terminal's F11 does; leaving puts back
    /// the style and placement it had, a maximized window included.
    func setFullscreen(_ on: Bool) {
        guard on != fullscreen, let window else { return }
        if on {
            var placement = WINDOWPLACEMENT()
            placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
            var monitor = MONITORINFO()
            monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
            guard GetWindowPlacement(window, &placement),
                  GetMonitorInfoW(MonitorFromWindow(window, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor) else { return }
            let style = GetWindowLongPtrW(window, GWL_STYLE)
            beforeFullscreen = (style, placement)
            SetWindowLongPtrW(window, GWL_STYLE, style & ~LONG_PTR(WS_CAPTION | WS_THICKFRAME))
            let area = monitor.rcMonitor
            // nil is HWND_TOP, which Swift does not import
            SetWindowPos(window, nil, area.left, area.top, area.right - area.left, area.bottom - area.top,
                         UINT(SWP_NOOWNERZORDER | SWP_FRAMECHANGED))
        } else if let saved = beforeFullscreen {
            beforeFullscreen = nil
            var placement = saved.placement
            SetWindowLongPtrW(window, GWL_STYLE, saved.style)
            SetWindowPlacement(window, &placement)
            SetWindowPos(window, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED))
        }
        layout()
        invalidateTitleBar()
    }

    /// setSidebarVisible shows or hides the tree; a hidden tree keeps no keyboard focus, which goes to the terminal.
    func setSidebarVisible(_ visible: Bool) {
        let focused = !visible && tree.map { GetFocus() == HWND(bitPattern: UInt(bitPattern: $0)) } == true
        settings.sidebarVisible = visible
        saveSettings()
        layout()
        if focused { focus() }
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
