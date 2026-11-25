import AgtermWinKit
import Foundation
import WinSDK

/// The notice bar's place in the window: what it takes from the content band, and the commands that move and close it.
extension NativeShell {
    /// contentSpan is the client band the sidebar and the sessions share: under the title bar, less the notice bar
    /// while it shows a notice.
    var contentSpan: (top: Int32, bottom: Int32) {
        var client = RECT()
        GetClientRect(window, &client)
        var top = titleBar.height, bottom = client.bottom
        if let bar = noticeWindow, bar.state.shown != nil {
            if bar.state.position == .top { top += bar.height } else { bottom -= bar.height }
        }
        return (top, max(bottom, top + 1))
    }

    var noticeBar: NoticeBar.State { noticeWindow?.state ?? NoticeBar.State(position: settings.noticeBarPosition) }

    func setNoticePosition(_ position: NoticeBar.Position) {
        log("native shell: notice bar at \(position.rawValue)")
        noticeWindow?.state.position = position
        if settings.noticeBarPosition != position {
            settings.noticeBarPosition = position
            saveSettings()
        }
        layout()
    }

    func dismissNotice() -> Bool {
        guard noticeWindow?.state.dismissShown() == true else { return false }
        layout()
        return true
    }

    /// openLog opens agterm-win.log with what Windows opens .log files with, else Notepad.
    func openLog() {
        let verb = Array("open".utf16) + [0], file = Array(stateDirectory.appendingPathComponent("agterm-win.log").path.utf16) + [0]
        if Int(bitPattern: ShellExecuteW(window, verb, file, nil, nil, SW_SHOWNORMAL)) <= 32 {
            _ = ShellExecuteW(window, verb, Array("notepad.exe".utf16) + [0], file, nil, SW_SHOWNORMAL)
        }
    }
}
