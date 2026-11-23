import AgtermWinKit
import Foundation
import WinSDK
import agtermCore

/// Keys is the keymap every terminal, the sidebar and the shell's Win-key hook consult: loaded at start, again on
/// Reload Keymap.
@MainActor
enum Keys {
    private(set) static var configDirectory = URL(fileURLWithPath: ".")
    static var keymap = WindowsKeymap(text: "")
    /// onReload lets the shell refresh what follows the keymap, its Win-key hook.
    static var onReload: (() -> Void)?

    static func load(configDirectory: URL) {
        self.configDirectory = configDirectory
        keymap = WindowsKeymap.load(configDirectory: configDirectory)
        log("keymap: \(keymap.path), \(keymap.diagnostics.count) diagnostic(s)")
    }

    /// reload reads the file again, says what it found wrong unless `quiet`, and returns how many problems it found.
    @discardableResult
    static func reload(owner: HWND?, quiet: Bool = false) -> Int {
        load(configDirectory: configDirectory)
        onReload?()
        if !quiet { report(owner) }
        return keymap.diagnostics.count
    }

    /// report shows the file's problems, nothing when there are none.
    static func report(_ owner: HWND?) {
        let diagnostics = keymap.diagnostics
        guard !diagnostics.isEmpty else { return }
        let lines = diagnostics.prefix(12).map { $0.line > 0 ? "line \($0.line): \($0.message)" : $0.message }
        let text = "\(keymap.path)\n\n" + lines.joined(separator: "\n") + (diagnostics.count > 12 ? "\n…" : "")
        MessageBoxW(owner, Array(text.utf16) + [0], Array("agterm keymap".utf16) + [0], UINT(MB_ICONWARNING))
    }

    /// edit opens keymap.conf with what Windows opens .conf files with, else Notepad, writing the commented starter
    /// first when there is no file.
    static func edit(owner: HWND?) {
        let path = KeymapStore(configDirectory: configDirectory).path
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try? Data(ConfigPaths.starterKeymapConf().utf8).write(to: path)
        }
        let verb = Array("open".utf16) + [0], file = Array(path.path.utf16) + [0]
        let opened = ShellExecuteW(owner, verb, file, nil, nil, SW_SHOWNORMAL)
        if Int(bitPattern: opened) <= 32 {
            _ = ShellExecuteW(owner, verb, Array("notepad.exe".utf16) + [0], file, nil, SW_SHOWNORMAL)
        }
    }

    /// chord names a key with the modifiers held for the message being handled.
    static func chord(virtualKey: Int32) -> Chord? {
        WindowsKeymap.chord(virtualKey: virtualKey, control: GetKeyState(VK_CONTROL) < 0, alt: GetKeyState(VK_MENU) < 0,
                            shift: GetKeyState(VK_SHIFT) < 0, win: GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0)
    }
}

/// WinKeyHook sees Win chords before the Windows shell takes them, while the keymap binds one. It swallows only a
/// bound chord pressed with agterm in front, and posts its command so nothing modal runs inside the hook.
@MainActor
enum WinKeyHook {
    private static var hook: HHOOK?
    private static var window: HWND?
    static let commandMessage = UINT(WM_APP + 21)

    static func update(window: HWND?) {
        self.window = window
        if Keys.keymap.usesWinKey, hook == nil {
            hook = SetWindowsHookExW(WH_KEYBOARD_LL, lowLevelKeyboard, GetModuleHandleW(nil), 0)
            log("keymap: Win-key hook \(hook == nil ? "failed: \(GetLastError())" : "installed")")
        } else if !Keys.keymap.usesWinKey, let installed = hook {
            UnhookWindowsHookEx(installed)
            hook = nil
        }
    }

    static func remove() {
        if let hook { UnhookWindowsHookEx(hook) }
        hook = nil
    }

    fileprivate static func take(_ key: Int32) -> Bool {
        let held = { (key: Int32) in GetAsyncKeyState(key) < 0 }
        guard held(VK_LWIN) || held(VK_RWIN), let window, GetForegroundWindow() == window,
              let chord = WindowsKeymap.chord(virtualKey: key, control: held(VK_CONTROL), alt: held(VK_MENU), shift: held(VK_SHIFT), win: true)
        else { return false }
        switch Keys.keymap.press(chord) {
        case .pass: return false
        case .consumed: break
        case .command(let command): PostMessageW(window, commandMessage, WPARAM(command.rawValue), 0)
        }
        // a key the shell sees between Win's press and release keeps Start from opening on the release
        keybd_event(0xE8, 0, 0, 0)
        keybd_event(0xE8, 0, DWORD(KEYEVENTF_KEYUP), 0)
        return true
    }
}

private let injectedFlag = DWORD(0x10)  // LLKHF_INJECTED

private let lowLevelKeyboard: HOOKPROC = { code, wParam, lParam in
    if code == HC_ACTION, wParam == WPARAM(WM_KEYDOWN) || wParam == WPARAM(WM_SYSKEYDOWN),
       let info = UnsafePointer<KBDLLHOOKSTRUCT>(bitPattern: Int(lParam)), info.pointee.flags & injectedFlag == 0,
       MainActor.assumeIsolated({ WinKeyHook.take(Int32(info.pointee.vkCode)) }) {
        return 1
    }
    return CallNextHookEx(nil, code, wParam, lParam)
}
