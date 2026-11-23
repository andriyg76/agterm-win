import AgtermWinKit
import Foundation
import NativeShim
import WinSDK

/// TerminalAppearance turns the Appearance settings into what every terminal draws with, in the current Windows app
/// mode.
@MainActor
enum TerminalAppearance {
    static var themes = TerminalThemes(userDirectory: URL(fileURLWithPath: "."), bundledDirectory: nil)

    /// use sets the theme and font every terminal takes; true when the font family changed, which refits the grid.
    @discardableResult
    static func use(_ appearance: Appearance) -> Bool {
        NativeTerminal.theme = appearance.activeTheme(dark: isDark).flatMap(themes.theme(named:))
        let refit = NativeTerminal.fontFamily != appearance.fontFamily
        NativeTerminal.fontFamily = appearance.fontFamily
        return refit
    }

    /// isDark is Windows' app mode, Settings ▸ Personalization ▸ Colors; light when it cannot be read.
    static var isDark: Bool {
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let currentUser = HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001)))  // HKEY_CURRENT_USER
        let status = RegGetValueW(currentUser, Array(#"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"#.utf16) + [0],
                                  Array("AppsUseLightTheme".utf16) + [0], DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
        return status == 0 && value == 0
    }

    /// monospaceFonts are the installed monospaced families, sorted.
    static var monospaceFonts: [String] {
        let length = nt_monospace_fonts(nil, 0)
        var units = [UInt16](repeating: 0, count: Int(length))
        _ = nt_monospace_fonts(&units, length)
        let names = Set(String(decoding: units, as: UTF16.self).split(separator: "\n").map(String.init))
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
