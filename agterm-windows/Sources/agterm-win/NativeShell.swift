import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

private nonisolated(unsafe) var shell: NativeShell!
private let menuButtonID = 100
private let localWorkspaceID = Foundation.UUID()

/// NativeShell is a window drawn without WebView2: the sidebar as a Win32 tree beside the selected session's
/// terminal. It holds local sessions started from launch profiles, each with a terminal of its own, and the catalog
/// of an agterm-server in WSL, whose sessions share one terminal that attaches whichever is selected.
@MainActor
final class NativeShell {
    private struct LocalSession {
        let id = Foundation.UUID()
        var title: String
        let commandLine: String
        let terminal: NativeTerminal
        var exited = false
        var attention = false
    }

    private let remote: RemoteWindow
    private let core: URL
    private let settingsURL: URL
    private var settings: NativeSettings
    private var window: HWND?
    private var tree: UnsafeMutableRawPointer?
    private var notice: HWND?
    private var menuButton: HWND?
    private var findBar: HWND?
    private var findFailed = false
    private var menuFont: HFONT?
    private var remoteTerminal: NativeTerminal!
    private var locals: [LocalSession] = []
    private var profiles = LaunchProfiles.available(wslDistributions: [], powerShell7: NativeShell.powerShell7())
    private var selected: Foundation.UUID?
    // the server's sessions before New Session on Server, so the one it adds is selected when the catalog shows it
    private var sessionsBeforeCreate: Set<Foundation.UUID>?
    private var running: Foundation.UUID?
    // the tree's tags index these; 0 is a workspace row
    private var tagged: [Foundation.UUID] = []
    private var dimmed: [UInt8] = []
    private var items: [Foundation.UUID: UnsafeMutableRawPointer] = [:]
    private let darkBrush = CreateSolidBrush(0x262525)
    private var dpi: UInt32 = 96

    /// open shows the window; `profiles` name launch profiles to start local sessions from once they are known.
    static func open(remote: RemoteWindow, core: URL, settings: URL, profiles: [String]) {
        nt_init_process()
        shell = NativeShell(remote: remote, core: core, settingsURL: settings)
        shell.create(starting: profiles)
    }

    private init(remote: RemoteWindow, core: URL, settingsURL: URL) {
        self.remote = remote
        self.core = core
        self.settingsURL = settingsURL
        settings = NativeSettings.load(from: settingsURL)
    }

    private func create(starting requested: [String]) {
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-shell".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = shellWindowProcedure
            windowClass.hInstance = instance
            windowClass.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512)) // IDC_ARROW
            windowClass.hIcon = LoadIconW(instance, UnsafePointer<WCHAR>(bitPattern: 1))
            windowClass.hbrBackground = darkBrush
            windowClass.lpszClassName = name.baseAddress
            RegisterClassExW(&windowClass)
        }
        guard let window = CreateWindowExW(0, className, Array("agterm".utf16) + [0],
                                           DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN), CW_USEDEFAULT, CW_USEDEFAULT, 1300, 760,
                                           nil, nil, instance, nil) else {
            log("native shell: CreateWindowExW failed: \(GetLastError())")
            exit(1)
        }
        self.window = window
        nt_dark_title_bar(UnsafeMutableRawPointer(window))
        dpi = GetDpiForWindow(window)
        menuButton = CreateWindowExW(0, Array("BUTTON".utf16) + [0], Array("Menu".utf16) + [0],
                                     DWORD(WS_CHILD) | DWORD(WS_VISIBLE) | DWORD(BS_OWNERDRAW), 0, 0, 10, 10, window,
                                     HMENU(bitPattern: menuButtonID), instance, nil)
        updateMenuFont()
        tree = nt_tree_create(UnsafeMutableRawPointer(window), dpi)
        notice = CreateWindowExW(0, Array("STATIC".utf16) + [0], nil, DWORD(WS_CHILD) | DWORD(SS_LEFT), 0, 0, 10, 10, window, nil,
                                 instance, nil)
        findBar = nt_find_bar_create(UnsafeMutableRawPointer(window), dpi)?.assumingMemoryBound(to: HWND__.self)
        remoteTerminal = makeTerminal()
        restorePlacement()
        layout()
        restoreLocals()
        discoverProfiles(then: requested)
        remote.changed = { [weak self] in self?.catalogChanged() }
        catalogChanged()
        remote.start()
    }

    private func makeTerminal() -> NativeTerminal {
        let terminal = NativeTerminal(parent: window, core: core, points: settings.fontPoints)
        terminal.onWindowCommand = { [unowned self] in windowCommand($0) }
        terminal.onFontSize = { [unowned self] in setFontSize($0) }
        terminal.setDPI(dpi)
        return terminal
    }

    // MARK: settings

    private func setFontSize(_ points: Float) {
        settings.fontPoints = points
        terminalsShown.forEach { $0.setFontSize(points) }
        saveSettings()
    }

    /// restorePlacement shows the window where it last was, unless that rectangle is on no monitor now.
    private func restorePlacement() {
        guard let frame = settings.frame else {
            ShowWindow(window, settings.maximized ? SW_SHOWMAXIMIZED : SW_SHOW)
            return
        }
        var rect = RECT(left: frame.left, top: frame.top, right: frame.right, bottom: frame.bottom)
        guard MonitorFromRect(&rect, DWORD(MONITOR_DEFAULTTONULL)) != nil else {
            ShowWindow(window, SW_SHOW)
            return
        }
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        placement.showCmd = UINT(settings.maximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL)
        placement.rcNormalPosition = rect
        SetWindowPlacement(window, &placement)
    }

    private func saveSettings() {
        do {
            try settings.save(to: settingsURL)
        } catch {
            log("native shell: saving \(settingsURL.path) failed: \(error)")
        }
    }

    /// confirmQuit asks before running local sessions end with the window.
    fileprivate func confirmQuit() -> Bool {
        guard let question = NativeMenu.quitQuestion(runningLocalSessions: locals.filter { !$0.exited }.count) else { return true }
        return MessageBoxW(window, Array(question.utf16) + [0], Array("agterm".utf16) + [0],
                           UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)) == IDOK
    }

    fileprivate func closing() {
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        if GetWindowPlacement(window, &placement) {
            let rect = placement.rcNormalPosition
            settings.frame = .init(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
            settings.maximized = placement.showCmd == UINT(SW_SHOWMAXIMIZED)
        }
        let running = locals.filter { !$0.exited }
        settings.localSessions = running.map { .init(title: $0.title, commandLine: $0.commandLine) }
        settings.selectedLocal = running.firstIndex { $0.id == selected }
        saveSettings()
    }

    // MARK: find

    private func showFindBar() {
        SetWindowPos(findBar, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW))
        SetFocus(findBar)
        SendMessageW(findBar, UINT(EM_SETSEL), 0, -1)
    }

    private var findText: String {
        let length = GetWindowTextLengthW(findBar)
        var text = [UInt16](repeating: 0, count: Int(length) + 1)
        GetWindowTextW(findBar, &text, length + 1)
        return String(decodingCString: text, as: UTF16.self)
    }

    fileprivate func findChanged() { search(backward: true, restart: true) }

    fileprivate func findNext(newer: Bool) { search(backward: !newer, restart: false) }

    private func search(backward: Bool, restart: Bool) {
        let needle = findText
        findFailed = !needle.isEmpty && !visibleTerminal.find(needle, backward: backward, restart: restart)
        InvalidateRect(findBar, nil, true)
    }

    fileprivate func closeFindBar() {
        ShowWindow(findBar, SW_HIDE)
        focus()
    }

    fileprivate func editColors(_ context: HDC?) -> LRESULT {
        SetTextColor(context, findFailed ? 0x6B6BF0 : 0xE0E0E0)
        SetBkColor(context, 0x262525)
        return LRESULT(Int(bitPattern: darkBrush))
    }

    // MARK: launch profiles

    private static func powerShell7() -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ";").map { "\($0)\\pwsh.exe" }
            + [#"C:\Program Files\PowerShell\7\pwsh.exe"#]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// discoverProfiles adds the WSL distributions once `wsl.exe` lists them, off the UI thread: the first call can
    /// wait for the WSL service.
    private func discoverProfiles(then requested: [String]) {
        let powerShell7 = Self.powerShell7()
        DispatchQueue.global().async {
            let listing = (try? HiddenProcess(commandLine: "wsl.exe --list --quiet", captureErrors: false))?.readToEnd() ?? Data()
            let distributions = LaunchProfiles.distributions(fromWSLList: listing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    shell.profiles = LaunchProfiles.available(wslDistributions: distributions, powerShell7: powerShell7)
                    log("native shell: \(shell.profiles.count) launch profile(s): \(shell.profiles.map(\.name).joined(separator: ", "))")
                    for name in requested {
                        if let profile = LaunchProfiles.named(name, in: shell.profiles) {
                            shell.newSession(profile)
                        } else {
                            log("native shell: no launch profile named \(name)")
                        }
                    }
                }
            }
        }
    }

    private func newSession(_ profile: LaunchProfile) {
        let siblings = locals.filter { $0.title.hasPrefix(profile.name) }.count
        startLocal(title: siblings == 0 ? profile.name : "\(profile.name) \(siblings + 1)", commandLine: profile.commandLine)
    }

    /// restoreLocals starts again the local sessions open at the last quit, fresh programs under their names.
    private func restoreLocals() {
        let saved = settings.localSessions
        guard !saved.isEmpty else { return }
        for session in saved { startLocal(title: session.title, commandLine: session.commandLine, selecting: false) }
        log("native shell: restored \(saved.count) local session(s)")
        if let index = settings.selectedLocal { select(locals[index].id) }
    }

    private func startLocal(title: String, commandLine: String, selecting: Bool = true) {
        let session = LocalSession(title: title, commandLine: commandLine, terminal: makeTerminal())
        let id = session.id
        session.terminal.onExit = { [unowned self] in localExited(id) }
        session.terminal.onAttention = { [unowned self] in localAttention(id) }
        locals.append(session)
        layout()
        log("native shell: new \(title) session [\(id)]")
        session.terminal.start(commandLine, directory: ProcessInfo.processInfo.environment["USERPROFILE"])
        rebuild()
        if selecting { select(id) }
    }

    private func localExited(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        locals[index].exited = true
        rebuild()
    }

    /// localAttention marks a session that rang or notified while it was not in view, and flashes the taskbar button
    /// while the window is in the background.
    private func localAttention(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let inView = selected == id && GetForegroundWindow() == window
        if !inView {
            var flash = FLASHWINFO(cbSize: UINT(MemoryLayout<FLASHWINFO>.size), hwnd: window, dwFlags: DWORD(FLASHW_TRAY | FLASHW_TIMERNOFG),
                                   uCount: 0, dwTimeout: 0)
            FlashWindowEx(&flash)
        }
        guard selected != id, !locals[index].attention else { return }
        locals[index].attention = true
        rebuild()
    }

    private var serverLabel: String { "WSL \(remote.host.distribution)" }

    private func newServerSession() {
        guard remote.connected, let workspace = remote.store.currentWorkspaceID else { return }
        sessionsBeforeCreate = Set(remote.store.workspaces.flatMap(\.sessions).map(\.id))
        Task { @MainActor in
            let response = await remote.perform(.newSession(workspace: workspace))
            log("native shell: new session on \(serverLabel): \(response.ok ? "ok" : response.error ?? "failed")")
            if !response.ok {
                sessionsBeforeCreate = nil
                MessageBoxW(window, Array("New session on \(serverLabel) failed: \(response.error ?? "")".utf16) + [0],
                            Array("agterm".utf16) + [0], UINT(MB_ICONERROR))
            }
        }
    }

    private func closeServerSession(_ id: Foundation.UUID) {
        guard let session = remote.session(id) else { return }
        let question = NativeMenu.closeQuestion(session: session.displayName, server: serverLabel)
        guard session.ended || MessageBoxW(window, Array(question.utf16) + [0], Array("agterm".utf16) + [0],
                                           UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)) == IDOK else { return }
        Task { @MainActor in
            let response = await remote.perform(.closeSession(id, undoable: true))
            log("native shell: close \(session.displayName) on \(serverLabel): \(response.ok ? "ok" : response.error ?? "failed")")
        }
    }

    /// canRename is whether `id` takes a new name: a local session, or a server session while the server is connected.
    private func canRename(_ id: Foundation.UUID?) -> Bool {
        guard let id else { return false }
        return locals.contains { $0.id == id } || (remote.connected && remote.session(id) != nil)
    }

    private func name(of id: Foundation.UUID) -> String? {
        locals.first { $0.id == id }?.title ?? remote.session(id)?.displayName
    }

    private func startRename() {
        guard let tree, canRename(selected), let selected, let item = items[selected] else { return }
        nt_tree_edit(tree, item)
    }

    /// labelEdit answers the tree's in-place rename: it starts from the plain name, and a non-empty result renames
    /// the local session here or the server's session there.
    fileprivate func labelEdit(_ notification: LPARAM) -> LRESULT? {
        var tag: Int64 = 0
        var text = [UInt16](repeating: 0, count: 512)
        let stage = nt_tree_label_edit(Int(notification), &tag, &text, Int32(text.count))
        guard stage != 0 else { return nil }
        let id = tag > 0 && Int(tag) <= tagged.count ? tagged[Int(tag) - 1] : nil
        switch stage {
        case 1:
            guard let id, canRename(id), let tree, let name = name(of: id) else { return 1 }
            nt_tree_set_edit_text(tree, Array(name.utf16) + [0])
            return 0
        case 2:
            let name = String(decodingCString: text, as: UTF16.self)
            if let id, !name.isEmpty { rename(id, to: name) }
            focus()
            return 0
        default:
            focus()
            return 0
        }
    }

    private func rename(_ id: Foundation.UUID, to name: String) {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].title = name
            rebuild()
            return
        }
        Task { @MainActor in
            let response = await remote.perform(.renameSession(id, name: name))
            log("native shell: rename on \(serverLabel): \(response.ok ? "ok" : response.error ?? "failed")")
        }
    }

    private var canCloseSelected: Bool {
        locals.contains { $0.id == selected } || (remote.connected && selected.flatMap(remote.session) != nil)
    }

    private func closeSelected() {
        if let selected, remote.session(selected) != nil {
            closeServerSession(selected)
            return
        }
        guard let index = locals.firstIndex(where: { $0.id == selected }) else { return }
        let closing = locals.remove(at: index)
        DestroyWindow(closing.terminal.window)
        selected = nil
        rebuild()
        if let next = locals.indices.contains(index) ? locals[index].id : locals.last?.id {
            select(next)
        } else {
            catalogChanged()
        }
    }

    fileprivate func windowCommand(_ command: NativeMenu.Command) {
        log("native shell: \(command)")
        switch command {
        case .newSession: if let profile = profiles.first { newSession(profile) }
        case .newServerSession: newServerSession()
        case .renameSession: startRename()
        case .closeSession: closeSelected()
        case .nextSession, .previousSession:
            if let next = SessionSidebar.neighbor(of: selected, in: tagged, forward: command == .nextSession) {
                select(next)
                focus()
            }
        case .find: showFindBar()
        case .quit: if confirmQuit() { DestroyWindow(window) }
        default: visibleTerminal.perform(command)
        }
    }

    // MARK: sidebar

    private var sidebarWidth: Int32 { scaled(240) }
    private func scaled(_ value: Int32) -> Int32 { MulDiv(value, Int32(dpi), 96) }

    private func updateMenuFont() {
        if let menuFont { DeleteObject(menuFont) }
        menuFont = CreateFontW(-scaled(18), 0, 0, 0, FW_NORMAL, 0, 0, 0, DWORD(DEFAULT_CHARSET), DWORD(OUT_DEFAULT_PRECIS),
                               DWORD(CLIP_DEFAULT_PRECIS), DWORD(CLEARTYPE_QUALITY), DWORD(DEFAULT_PITCH), Array("Segoe UI Symbol".utf16) + [0])
    }

    private var terminalsShown: [NativeTerminal] { [remoteTerminal] + locals.map(\.terminal) }

    private var visibleTerminal: NativeTerminal { locals.first { $0.id == selected }?.terminal ?? remoteTerminal }

    private func layout() {
        guard let window else { return }
        var client = RECT()
        GetClientRect(window, &client)
        let width = sidebarWidth, height = client.bottom
        let noticeText = remote.mirror.state.windowNotice(host: "WSL \(remote.host.distribution)")
        let buttonSize = scaled(36)
        let noticeHeight = noticeText == nil ? 0 : scaled(56)
        MoveWindow(menuButton, 0, 0, buttonSize, buttonSize, true)
        ShowWindow(notice, noticeText == nil ? SW_HIDE : SW_SHOW)
        SetWindowTextW(notice, Array((noticeText ?? "").utf16) + [0])
        MoveWindow(notice, 8, buttonSize, width - 16, max(noticeHeight - 6, 0), true)
        let treeTop = buttonSize + noticeHeight
        MoveWindow(tree?.assumingMemoryBound(to: HWND__.self), 0, treeTop, width, height - treeTop, true)
        for terminal in terminalsShown {
            terminal.move(x: width, y: 0, width: max(client.right - width, 1), height: height)
        }
        let findWidth = min(scaled(280), max(client.right - width - scaled(24), scaled(80)))
        MoveWindow(findBar, client.right - findWidth - scaled(16), scaled(8), findWidth, scaled(28), true)
    }

    private func catalogChanged() {
        rebuild()
        layout()
        let workspaces = remote.store.workspaces
        if let before = sessionsBeforeCreate, let created = workspaces.flatMap(\.sessions).first(where: { !before.contains($0.id) }) {
            sessionsBeforeCreate = nil
            select(created.id)
            return
        }
        guard !locals.contains(where: { $0.id == selected }) else { return }
        let next = SessionSidebar.selection(current: selected, in: workspaces)
        log("native shell: \(workspaces.lazy.flatMap(\.sessions).count) session(s), selecting \(next?.uuidString ?? "none")")
        if let next { select(next) } else if let local = locals.last { select(local.id) } else { selected = nil }
    }

    private func rebuild() {
        guard let tree else { return }
        var sidebar = SessionSidebar.items(remote.store.workspaces)
        if !locals.isEmpty {
            let children = locals.map {
                SessionSidebar.Item(id: $0.id, title: SessionSidebar.localTitle($0.title, exited: $0.exited, attention: $0.attention),
                                    isWorkspace: false, ended: $0.exited, children: [])
            }
            sidebar.insert(SessionSidebar.Item(id: localWorkspaceID, title: "Local", isWorkspace: true, ended: false, children: children),
                           at: 0)
        }
        nt_tree_clear(tree)
        tagged = []
        dimmed = []
        items = [:]
        func add(_ item: SessionSidebar.Item, under parent: UnsafeMutableRawPointer?) {
            var tag: Int64 = 0
            if !item.isWorkspace {
                tagged.append(item.id)
                dimmed.append(item.ended ? 1 : 0)
                tag = Int64(tagged.count)
            }
            guard let node = nt_tree_add(tree, parent, Array(item.title.utf16) + [0], tag, 1) else { return }
            if !item.isWorkspace { items[item.id] = node }
            item.children.forEach { add($0, under: node) }
        }
        sidebar.forEach { add($0, under: nil) }
        if let selected, let item = items[selected] { nt_tree_select(tree, item) }
    }

    fileprivate func customDraw(_ notification: LPARAM) -> LRESULT? {
        let result = dimmed.withUnsafeBufferPointer { nt_tree_custom_draw(Int(notification), $0.baseAddress, Int64($0.count)) }
        return result < 0 ? nil : LRESULT(result)
    }

    fileprivate func userSelected(_ tag: Int64) {
        guard tag > 0, Int(tag) <= tagged.count else { return }
        select(tagged[Int(tag) - 1])
        focus()
    }

    private func select(_ id: Foundation.UUID) {
        selected = id
        if let index = locals.firstIndex(where: { $0.id == id }), locals[index].attention {
            locals[index].attention = false
            rebuild()
        }
        if let tree, let item = items[id] { nt_tree_select(tree, item) }
        let shown = visibleTerminal
        for terminal in terminalsShown { terminal.setVisible(terminal === shown) }
        guard !locals.contains(where: { $0.id == id }), let session = remote.session(id), id != running else { return }
        running = id
        remote.store.selectedSessionID = id
        switch SessionSidebar.launch(for: session, hostLabel: "WSL \(remote.host.distribution)") {
        case .command(let command):
            log("native shell: showing \(session.displayName) [\(id)]")
            remoteTerminal.start(command)
        case .notice(let text):
            remoteTerminal.show(notice: text)
        }
    }

    // MARK: window

    fileprivate func resized() { layout() }

    fileprivate func dpiChanged(_ dpi: UInt32, suggested: RECT) {
        self.dpi = dpi
        if let tree { nt_tree_set_dpi(tree, dpi) }
        if let findBar { nt_find_bar_set_dpi(UnsafeMutableRawPointer(findBar), dpi) }
        updateMenuFont()
        terminalsShown.forEach { $0.setDPI(dpi) }
        SetWindowPos(window, nil, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        layout()
    }

    fileprivate func staticColors(_ context: HDC?) -> LRESULT {
        SetTextColor(context, 0x5AB4E5)
        SetBkColor(context, 0x262525)
        return LRESULT(Int(bitPattern: darkBrush))
    }

    fileprivate func focus() { SetFocus(visibleTerminal.window) }

    /// windowMenu is the ☰ menu: new sessions from the launch profiles, the terminal's commands and the window's own.
    fileprivate func windowMenu() {
        var button = RECT()
        GetWindowRect(menuButton, &button)
        let entries = NativeMenu.window(profiles: profiles, server: serverLabel, serverConnected: remote.connected,
                                        canCloseSession: canCloseSelected, sessionCount: tagged.count, canRenameSession: canRename(selected), hasSelection: visibleTerminal.hasSelection,
                                        canPaste: IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)))
        run(showMenu(entries, owner: window, at: POINT(x: button.left, y: button.bottom)))
    }

    /// treeMenu is the sidebar's menu, for the session under the right click, which it selects first.
    fileprivate func treeMenu(x: Int32, y: Int32) {
        guard let tree else { return }
        var point = POINT(x: x, y: y)
        let tag = nt_tree_item_at(tree, &point.x, &point.y)
        if tag > 0, Int(tag) <= tagged.count { select(tagged[Int(tag) - 1]) }
        if x != -1 || y != -1 { point = POINT(x: x, y: y) }
        run(showMenu(NativeMenu.sessions(profiles: profiles, server: serverLabel, serverConnected: remote.connected,
                                         canCloseSession: canCloseSelected, sessionCount: tagged.count,
                                         canRenameSession: canRename(selected)),
                     owner: window, at: point))
    }

    private func run(_ pick: NativeMenu.Pick?) {
        log("native shell: menu picked \(pick.map { "\($0)" } ?? "nothing")")
        switch pick {
        case .command(let command)?: windowCommand(command)
        case .profile(let index)? where profiles.indices.contains(index): newSession(profiles[index])
        default: break
        }
        focus()
    }

    fileprivate func drawMenuButton(_ item: DRAWITEMSTRUCT) {
        var rect = item.rcItem
        let pressed = item.itemState & UINT(ODS_SELECTED) != 0
        let brush = pressed ? CreateSolidBrush(0x3E3D3D) : nil
        FillRect(item.hDC, &rect, brush ?? darkBrush)
        if let brush { DeleteObject(brush) }
        let previous = SelectObject(item.hDC, menuFont)
        SetBkMode(item.hDC, TRANSPARENT)
        SetTextColor(item.hDC, 0xCCCCCC)
        DrawTextW(item.hDC, Array("\u{2630}".utf16) + [0], -1, &rect, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        SelectObject(item.hDC, previous)
    }
}

private let shellWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    MainActor.assumeIsolated {
        switch message {
        case UINT(WM_SIZE):
            shell.resized()
            return 0
        case UINT(WM_SETFOCUS):
            shell.focus()
            return 0
        case UINT(WM_NOTIFY):
            if let result = shell.customDraw(lParam) { return result }
            if let result = shell.labelEdit(lParam) { return result }
            if let key = UnsafePointer<NMTVKEYDOWN>(bitPattern: Int(lParam)), key.pointee.hdr.code == UINT(TVN_KEYDOWN),
               key.pointee.wVKey == WORD(VK_F2) {
                shell.windowCommand(.renameSession)
                return 1
            }
            var tag: Int64 = 0
            if nt_tree_selection_changed(Int(lParam), &tag) != 0 { shell.userSelected(tag) }
            return 0
        case UINT(WM_COMMAND):
            if Int(wParam & 0xFFFF) == menuButtonID { shell.windowMenu() }
            if wParam >> 16 & 0xFFFF == WPARAM(EN_CHANGE) { shell.findChanged() }
            return 0
        case UINT(NT_FIND_NEXT):
            shell.findNext(newer: wParam != 0)
            return 0
        case UINT(NT_FIND_CLOSE):
            shell.closeFindBar()
            return 0
        case UINT(WM_CTLCOLOREDIT):
            return shell.editColors(HDC(bitPattern: UInt(wParam)))
        case UINT(WM_DRAWITEM):
            if let item = UnsafePointer<DRAWITEMSTRUCT>(bitPattern: UInt(lParam)), Int(item.pointee.CtlID) == menuButtonID {
                shell.drawMenuButton(item.pointee)
                return 1
            }
            return DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_CONTEXTMENU):
            let x = Int32(Int16(truncatingIfNeeded: lParam)), y = Int32(Int16(truncatingIfNeeded: lParam >> 16))
            shell.treeMenu(x: x, y: y)
            return 0
        case UINT(WM_CTLCOLORSTATIC):
            return shell.staticColors(HDC(bitPattern: UInt(wParam)))
        case UINT(WM_DPICHANGED):
            if let suggested = UnsafePointer<RECT>(bitPattern: UInt(lParam)) {
                shell.dpiChanged(UInt32(wParam >> 16 & 0xFFFF), suggested: suggested.pointee)
            }
            return 0
        case UINT(WM_CLOSE):
            if shell.confirmQuit() { DestroyWindow(window) }
            return 0
        case UINT(WM_DESTROY):
            shell.closing()
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}
