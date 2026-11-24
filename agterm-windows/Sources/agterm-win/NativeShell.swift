import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

private nonisolated(unsafe) var shell: NativeShell!
private let localWorkspaceID = Foundation.UUID()

/// NativeShell is the application window: a Win32 sidebar beside the selected native terminal. It holds local
/// sessions started from launch profiles, each with a terminal of its own, and the catalog of an agterm-server in
/// WSL, whose sessions share one terminal that attaches whichever is selected.
@MainActor
final class NativeShell {
    private struct LocalSession {
        let id = Foundation.UUID()
        /// fallback names the session until its program reports a title or a folder: its profile's name.
        let fallback: String
        var customName: String?
        var programTitle: String?
        /// directory is the folder the shell last reported, decoded.
        var directory: String?
        let commandLine: String
        let terminal: NativeTerminal
        var exited = false
        /// attention is a bell since the session was last in view.
        var attention = false
        /// unseen counts notifications since the session was last in view.
        var unseen = 0

        var name: String {
            SessionNaming.displayName(customName: customName, title: programTitle, directory: directory, fallback: fallback)
        }
    }

    private let remote: RemoteWindow
    private let settingsURL: URL
    private var settings: NativeSettings
    private var window: HWND?
    private var tree: UnsafeMutableRawPointer?
    private var notice: HWND?
    private var findBar: HWND?
    private var findFailed = false
    private var tooltip: UnsafeMutableRawPointer?
    private var palette: UnsafeMutableRawPointer?
    // the open palette, what it lists, and the rows its query leaves, which Enter's index refers to
    private var paletteMode: Palette.Mode?
    private var paletteRows: [Palette.Row] = []
    private var paletteShown: [Palette.Row] = []
    // the title bar's button under the mouse, and the one a press started on, which acts if the release is on it too
    private var hovered: TitleBar.Button?
    private var pressed: TitleBar.Button?
    private var windowActive = true
    private var shownTitle = "agterm"
    private var remoteTerminal: NativeTerminal!
    private var locals: [LocalSession] = []
    private var profiles = LaunchProfiles.available(wslDistributions: [], powerShell7: NativeShell.powerShell7())
    private var selected: Foundation.UUID?
    // the server's sessions before New Session on Server, so the one it adds is selected when the catalog shows it
    private var sessionsBeforeCreate: Set<Foundation.UUID>?
    private var running: Foundation.UUID?
    // what the remote terminal was last given, so a session that ends or comes back is shown again
    private var runningLaunch: SessionSidebar.Launch?
    // the tree's tags index these; 0 is a workspace row
    private var tagged: [Foundation.UUID] = []
    private var dimmed: [UInt8] = []
    private var items: [Foundation.UUID: UnsafeMutableRawPointer] = [:]
    private let darkBrush = CreateSolidBrush(0x262525)
    private var dpi: UInt32 = 96
    private var control: ControlSocket?
    private let version: String

    /// open shows the window; `profiles` name launch profiles to start local sessions from once they are known.
    static func open(remote: RemoteWindow, settings: URL, profiles: [String], version: String, installServer: Bool) {
        nt_init_process()
        shell = NativeShell(remote: remote, settingsURL: settings, version: version)
        shell.create(starting: profiles, installServer: installServer)
    }

    private init(remote: RemoteWindow, settingsURL: URL, version: String) {
        self.remote = remote
        self.settingsURL = settingsURL
        self.version = version
        settings = NativeSettings.load(from: settingsURL)
        TerminalAppearance.use(settings.appearance)
        applyGeneral()
    }

    private func create(starting requested: [String], installServer: Bool) {
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
        tooltip = nt_tooltip_create(UnsafeMutableRawPointer(window))
        palette = nt_palette_create(UnsafeMutableRawPointer(window), dpi)
        tree = nt_tree_create(UnsafeMutableRawPointer(window), dpi)
        notice = CreateWindowExW(0, Array("STATIC".utf16) + [0], nil, DWORD(WS_CHILD) | DWORD(SS_LEFT), 0, 0, 10, 10, window, nil,
                                 instance, nil)
        findBar = nt_find_bar_create(UnsafeMutableRawPointer(window), dpi)?.assumingMemoryBound(to: HWND__.self)
        remoteTerminal = makeTerminal()
        // OSC 9/777 of the server session this terminal attaches; the server sends only `notify` through its stream
        remoteTerminal.onNotification = { [unowned self] title, body in
            if let running { deliver(running, title: title, body: body, source: .terminal) }
        }
        control = ControlSocket.start(path: socketPath, host: self, version: version)
        startToasts()
        Keys.onReload = { [unowned self] in
            WinKeyHook.update(window: self.window)
            self.updateTips()
        }
        WinKeyHook.update(window: window)
        DispatchQueue.main.async { Keys.report(window) }
        // WM_NCCALCSIZE gives the caption to the client from here on; the taller client's WM_SIZE lays out every child,
        // so they all exist by now
        SetWindowPos(window, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        restorePlacement()
        layout()
        restoreLocals()
        discoverProfiles(then: requested)
        remote.changed = { [weak self] in self?.catalogChanged() }
        remote.onNotification = { [weak self] id, notification in
            self?.deliver(id, title: notification.title, body: notification.body, source: notification.source == "control" ? .control : .terminal)
        }
        if installServer {
            installRemoteServer()
        } else {
            catalogChanged()
            remote.start()
        }
    }

    /// Installs or upgrades the WSL server off the UI thread, then connects whether installation succeeded or not.
    private func installRemoteServer() {
        remoteTerminal.show(notice: "Installing agterm-server in WSL \(remote.host.distribution)…")
        let host = remote.host
        DispatchQueue.global().async {
            do {
                let release = try serverRelease()
                let code = try host.installServer(version: release.version, checksums: release.checksums) {
                    log("server install: \($0)")
                }
                log("server install exited \(code)")
            } catch {
                log("server install failed: \(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    shell.catalogChanged()
                    shell.remote.start()
                }
            }
        }
    }

    private func makeTerminal() -> NativeTerminal {
        let terminal = NativeTerminal(parent: window, points: settings.fontPoints)
        terminal.onWindowCommand = { [unowned self] in windowCommand($0) }
        terminal.onFontSize = { [unowned self] in setFontSize($0) }
        terminal.setDPI(dpi)
        return terminal
    }

    // MARK: settings

    private func setFontSize(_ points: Float) {
        settings.fontPoints = points
        shown.points = points
        terminalsShown.forEach { $0.setFontSize(points) }
        saveSettings()
    }

    // what the terminals draw with now: the saved appearance, or Settings' preview while it is open
    private lazy var shown = SettingsWindow.Values(appearance: settings.appearance, points: settings.fontPoints,
                                                    notifications: settings.notifications, general: settings.general)

    /// applyAppearance draws every terminal with `values`, without saving them.
    private func applyAppearance(_ values: SettingsWindow.Values) {
        let refit = TerminalAppearance.use(values.appearance)
        for terminal in terminalsShown {
            terminal.applyTheme()
            if refit { terminal.applyFontFamily() }
            if values.points != shown.points { terminal.setFontSize(values.points) }
        }
        shown = values
    }

    private func showSettings(tab: SettingsTab = .general) {
        let distributions = profiles.compactMap { $0.name.hasPrefix("WSL ") ? String($0.name.dropFirst(4)) : nil }
        SettingsWindow.show(owner: window, tab: tab, values: .init(appearance: settings.appearance, points: settings.fontPoints,
                                                         notifications: settings.notifications, general: settings.general),
                            themes: TerminalAppearance.themes.catalog.names, fonts: TerminalAppearance.monospaceFonts,
                            distributions: distributions,
                            preview: { [unowned self] in applyAppearance($0) },
                            finish: { [unowned self] kept in
                                guard let kept else { return }
                                settings.appearance = kept.appearance
                                settings.fontPoints = kept.points
                                settings.notifications = kept.notifications
                                settings.general = kept.general
                                applyGeneral()
                                saveSettings()
                                rebuild()
                            })
    }

    /// systemAppearanceChanged follows Windows switching between light and dark mode.
    fileprivate func systemAppearanceChanged() {
        guard shown.appearance.followsSystem else { return }
        applyAppearance(shown)
    }

    /// restorePlacement shows the window where it last was, or where Windows put it when that rectangle is on no monitor
    /// now, fitted inside its monitor's work area either way.
    private func restorePlacement() {
        var current = RECT()
        GetWindowRect(window, &current)
        var rect = settings.frame.map { RECT(left: $0.left, top: $0.top, right: $0.right, bottom: $0.bottom) } ?? current
        if MonitorFromRect(&rect, DWORD(MONITOR_DEFAULTTONULL)) == nil { rect = current }
        var monitor = MONITORINFO()
        monitor.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)
        if GetMonitorInfoW(MonitorFromRect(&rect, DWORD(MONITOR_DEFAULTTONEAREST)), &monitor) {
            let work = monitor.rcWork
            let fitted = NativeSettings.Frame(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
                .fitted(in: .init(left: work.left, top: work.top, right: work.right, bottom: work.bottom))
            rect = RECT(left: fitted.left, top: fitted.top, right: fitted.right, bottom: fitted.bottom)
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
        settings.localSessions = running.map {
            .init(title: $0.fallback, customName: $0.customName, commandLine: $0.commandLine, directory: $0.directory)
        }
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
        startLocal(fallback: fallbackName(for: profile), commandLine: profile.commandLine, directory: newSessionDirectory, placed: true)
    }

    /// newSessionDirectory is where Settings ▸ General starts a session from the menu or a key.
    private var newSessionDirectory: String {
        settings.general.startDirectory(current: locals.first { $0.id == selected }?.directory, home: Self.home, exists: Self.isFolder)
    }

    private static var home: String { ProcessInfo.processInfo.environment["USERPROFILE"] ?? "C:\\" }

    private static func isFolder(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }

    /// applyGeneral hands Settings ▸ General's mouse choices to every terminal.
    private func applyGeneral() {
        NativeTerminal.rightClickPastes = settings.general.rightClickPastes
        NativeTerminal.scrollLines = settings.general.scrollLines
    }

    private func fallbackName(for profile: LaunchProfile) -> String {
        let siblings = locals.filter { $0.fallback.hasPrefix(profile.name) }.count
        return siblings == 0 ? profile.name : "\(profile.name) \(siblings + 1)"
    }

    /// restoreLocals starts again the local sessions open at the last quit, fresh programs under their names.
    private func restoreLocals() {
        let saved = settings.localSessions
        guard !saved.isEmpty else { return }
        for session in saved {
            startLocal(fallback: session.title, customName: session.customName, commandLine: session.commandLine,
                       directory: session.directory, selecting: false)
        }
        log("native shell: restored \(saved.count) local session(s)")
        if let index = settings.selectedLocal { select(locals[index].id) }
    }

    private var stateDirectory: URL { settingsURL.deletingLastPathComponent() }

    private var socketPath: String { stateDirectory.appendingPathComponent("agterm.sock").path }

    /// sessionEnvironment is what a local session's programs inherit: the state directory, so agtermctl finds this
    /// window's socket, the session's id, and agtermctl's folder on PATH.
    private func sessionEnvironment(_ id: Foundation.UUID) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AGTERM_STATE_DIR"] = stateDirectory.path
        environment["AGTERM_SESSION_ID"] = id.uuidString
        if let folder = Bundle.main.executableURL?.deletingLastPathComponent().path {
            let key = environment.keys.first { $0.uppercased() == "PATH" } ?? "Path"
            environment[key] = folder + ";" + (environment[key] ?? "")
        }
        return environment
    }

    /// launch starts the session's program in the folder it was last in while that still exists, else the profile.
    private func launch(_ session: LocalSession) {
        var isFolder: ObjCBool = false
        let last = session.directory.flatMap { FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue ? $0 : nil }
        session.terminal.start(ShellIntegration.commandLine(session.commandLine),
                               directory: last ?? ProcessInfo.processInfo.environment["USERPROFILE"],
                               environment: sessionEnvironment(session.id))
    }

    /// startLocal starts a local session; `placed` puts it where Settings ▸ General says, otherwise it goes last.
    @discardableResult
    private func startLocal(fallback: String, customName: String? = nil, commandLine: String, directory: String? = nil,
                            selecting: Bool = true, placed: Bool = false) -> Foundation.UUID {
        let session = LocalSession(fallback: fallback, customName: customName, directory: directory, commandLine: commandLine,
                                   terminal: makeTerminal())
        let id = session.id
        session.terminal.onExit = { [unowned self] in localExited(id) }
        session.terminal.onAttention = { [unowned self] in localAttention(id) }
        session.terminal.onNotification = { [unowned self] in deliver(id, title: $0, body: $1, source: .terminal) }
        session.terminal.onNaming = { [unowned self] in localNaming(id) }
        let index = placed ? settings.general.insertionIndex(count: locals.count, selected: locals.firstIndex { $0.id == selected })
            : locals.count
        locals.insert(session, at: index)
        layout()
        log("native shell: new \(session.name) session [\(id)]")
        launch(session)
        rebuild()
        if selecting { select(id) }
        return id
    }

    private func localExited(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        locals[index].exited = true
        rebuild()
    }

    /// localNaming takes the title and folder the session's program reported; the sidebar changes only when its name does.
    private func localNaming(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let before = locals[index].name
        let terminal = locals[index].terminal
        locals[index].programTitle = SessionNaming.programTitle(terminal.title)
        if let directory = SessionNaming.directory(fromReported: terminal.reportedDirectory) { locals[index].directory = directory }
        if locals[index].name != before { rebuild() }
    }

    /// localAttention marks a session that rang or notified while it was not in view, and flashes the taskbar button
    /// while the window is in the background.
    private func localAttention(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        flashTaskbar()
        guard selected != id, !locals[index].attention else { return }
        locals[index].attention = true
        rebuild()
    }

    // MARK: notifications

    /// deliver shows a notification for session `id` under NotificationRules: the unseen count while the session is out
    /// of view, the taskbar flash while agterm is behind, and a banner when Settings allow one. It returns why no banner
    /// was shown, for `notify`'s reply.
    @discardableResult
    private func deliver(_ id: Foundation.UUID, title: String, body: String, source: NotificationRules.Source) -> String? {
        let inFront = GetForegroundWindow() == window
        guard NotificationRules.delivers(source, sessionInView: selected == id, windowInFront: inFront) else {
            log("notification: dropped for \(id), the session is in view")
            return nil
        }
        if selected != id || !inFront {
            if let index = locals.firstIndex(where: { $0.id == id }) {
                locals[index].unseen += 1
            } else {
                serverUnseen[id, default: 0] += 1
            }
            rebuild()
        }
        flashTaskbar()
        guard settings.notifications.banners else {
            log("notification: banners are off; \(title): \(body)")
            return ControlNotify.bannersOffNote
        }
        let xml = NotificationRules.toast(title: title, body: body, session: name(of: id) ?? "agterm", sound: settings.notifications.sound)
        let shown = toastsReady && nt_toast_show(Array(xml.utf16) + [0], Array(NotificationRules.tag(source).utf16) + [0],
                                                Array(id.uuidString.utf16) + [0]) != 0
        log("notification: \(shown ? "shown" : "not shown") for \(id): \(title): \(body)")
        return nil
    }

    /// flashTaskbar flashes the taskbar button as Settings say while agterm is behind another window.
    private func flashTaskbar() {
        guard GetForegroundWindow() != window else { return }
        let flags: DWORD, count: UINT
        switch settings.notifications.flash {
        case .off: return
        case .once: (flags, count) = (DWORD(FLASHW_TRAY), 3)
        case .untilFocused: (flags, count) = (DWORD(FLASHW_TRAY | FLASHW_TIMERNOFG), 0)
        }
        var flash = FLASHWINFO(cbSize: UINT(MemoryLayout<FLASHWINFO>.size), hwnd: window, dwFlags: flags, uCount: count, dwTimeout: 0)
        FlashWindowEx(&flash)
    }

    private var toastsReady = false
    // notifications each server session had out of view, kept here as a Mac keeps its own count for a remote row
    private var serverUnseen: [Foundation.UUID: Int] = [:]

    private func startToasts() {
        let icon = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
            .appendingPathComponent("agterm.png")
        let iconPath = FileManager.default.fileExists(atPath: icon.path) ? icon.path : ""
        toastsReady = nt_toast_init(UnsafeMutableRawPointer(window), Self.toastMessage, Array(Self.appUserModelID.utf16) + [0],
                                    Array("agterm".utf16) + [0], Array(iconPath.utf16) + [0]) != 0
        log("notification: banners \(toastsReady ? "ready" : "unavailable")\(nt_is_packaged() != 0 ? " (packaged)" : "")")
    }

    // agterm-win's identity outside the Store, under which Windows lists its notifications
    static let appUserModelID = "andriyg76.agterm-win"
    fileprivate static let toastMessage = UINT(WM_APP + 22)

    /// reveal answers a clicked banner: agterm comes to the front with the session selected.
    fileprivate func reveal(_ id: Foundation.UUID) {
        guard tagged.contains(id) else { return }
        if IsIconic(window) { ShowWindow(window, SW_RESTORE) }
        SetForegroundWindow(window)
        select(id)
        focus()
    }

    private var defaultProfile: Int { NativeMenu.defaultProfile(named: settings.defaultProfile, in: profiles) }

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
        locals.first { $0.id == id }?.name ?? remote.session(id)?.displayName
    }

    private func startRename() {
        guard let tree, canRename(selected), let selected, let item = items[selected] else { return }
        nt_tree_edit(tree, item)
    }

    /// labelEdit answers the tree's in-place rename: it starts from the plain name, and the result renames the local
    /// session here or the server's session there; an empty one restores the automatic name.
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
            if let id { rename(id, to: name) }
            focus()
            return 0
        default:
            focus()
            return 0
        }
    }

    private func rename(_ id: Foundation.UUID, to name: String) {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].customName = SessionNaming.customName(name)
            rebuild()
            return
        }
        Task { @MainActor in
            let response = await remote.perform(.renameSession(id, name: name))
            log("native shell: rename on \(serverLabel): \(response.ok ? "ok" : response.error ?? "failed")")
        }
    }

    /// canRestart is whether `id` is a session whose program ended: a local one, or a server one while it is connected.
    private func canRestart(_ id: Foundation.UUID?) -> Bool {
        guard let id else { return false }
        if let local = locals.first(where: { $0.id == id }) { return local.exited }
        return remote.connected && remote.session(id)?.ended == true
    }

    private func restartSelected() {
        guard canRestart(selected), let id = selected else { return }
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].exited = false
            launch(locals[index])
            rebuild()
            focus()
            return
        }
        Task { @MainActor in
            let response = await remote.perform(.restart(id, pane: .left, command: nil))
            log("native shell: restart on \(serverLabel): \(response.ok ? "ok" : response.error ?? "failed")")
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
        guard let selected, let session = locals.first(where: { $0.id == selected }) else { return }
        if settings.general.confirmCloseSession, !session.exited {
            let question = NativeMenu.closeLocalQuestion(session: session.name)
            guard MessageBoxW(window, Array(question.utf16) + [0], Array("agterm".utf16) + [0],
                              UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)) == IDOK else { return }
        }
        closeLocal(selected)
    }

    private func closeLocal(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let closing = locals.remove(at: index)
        DestroyWindow(closing.terminal.window)
        guard selected == id else {
            rebuild()
            return
        }
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
        case .newSession: if profiles.indices.contains(defaultProfile) { newSession(profiles[defaultProfile]) }
        case .newServerSession: newServerSession()
        case .renameSession: startRename()
        case .restartSession: restartSelected()
        case .closeSession: closeSelected()
        case .nextSession, .previousSession:
            if let next = SessionSidebar.neighbor(of: selected, in: tagged, forward: command == .nextSession) {
                select(next)
                focus()
            }
        case .find: showFindBar()
        case .sessionPalette: openPalette(.sessions)
        case .commandPalette: openPalette(.commands)
        case .quit: if confirmQuit() { DestroyWindow(window) }
        case .settings: showSettings()
        case .editKeymap: Keys.edit(owner: window)
        case .reloadKeymap: Keys.reload(owner: window)
        default: visibleTerminal.perform(command)
        }
    }

    // MARK: sidebar

    private var sidebarWidth: Int32 { scaled(240) }
    private func scaled(_ value: Int32) -> Int32 { MulDiv(value, Int32(dpi), 96) }

    private var terminalsShown: [NativeTerminal] { [remoteTerminal] + locals.map(\.terminal) }

    private var visibleTerminal: NativeTerminal { locals.first { $0.id == selected }?.terminal ?? remoteTerminal }

    private func layout() {
        guard let window else { return }
        var client = RECT()
        GetClientRect(window, &client)
        let width = sidebarWidth, height = client.bottom
        let noticeText = remote.mirror.state.windowNotice(host: "WSL \(remote.host.distribution)")
        let top = titleBar.height
        let noticeHeight = noticeText == nil ? 0 : scaled(56)
        ShowWindow(notice, noticeText == nil ? SW_HIDE : SW_SHOW)
        SetWindowTextW(notice, Array((noticeText ?? "").utf16) + [0])
        MoveWindow(notice, 8, top, width - 16, max(noticeHeight - 6, 0), true)
        let treeTop = top + noticeHeight
        MoveWindow(tree?.assumingMemoryBound(to: HWND__.self), 0, treeTop, width, height - treeTop, true)
        for terminal in terminalsShown {
            terminal.move(x: width, y: top, width: max(client.right - width, 1), height: max(height - top, 1))
        }
        let findWidth = min(scaled(280), max(client.right - width - scaled(24), scaled(80)))
        MoveWindow(findBar, client.right - findWidth - scaled(16), top + scaled(8), findWidth, scaled(28), true)
        updateTips()
        invalidateTitleBar()
        if paletteMode != nil { placePalette() }
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
        var sidebar = SessionSidebar.items(remote.store.workspaces, unseen: settings.notifications.unseenCount ? serverUnseen : [:])
        if !locals.isEmpty {
            let children = locals.map {
                SessionSidebar.Item(id: $0.id, title: SessionSidebar.localTitle($0.name, exited: $0.exited, attention: $0.attention || $0.unseen > 0,
                                                                         unseen: settings.notifications.unseenCount ? $0.unseen : 0),
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
        titleChanged()
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
        if let index = locals.firstIndex(where: { $0.id == id }), locals[index].attention || locals[index].unseen > 0 {
            locals[index].attention = false
            locals[index].unseen = 0
            rebuild()
        }
        if serverUnseen.removeValue(forKey: id) != nil { rebuild() }
        // banners already shown for the session say nothing new once it is in view
        if toastsReady { nt_toast_remove_group(Array(id.uuidString.utf16) + [0]) }
        if let tree, let item = items[id] { nt_tree_select(tree, item) }
        titleChanged()
        let shown = visibleTerminal
        for terminal in terminalsShown { terminal.setVisible(terminal === shown) }
        guard !locals.contains(where: { $0.id == id }), let session = remote.session(id) else {
            remote.store.selectedSessionID = nil
            return
        }
        let launch = SessionSidebar.launch(for: session, hostLabel: serverLabel)
        guard id != running || launch != runningLaunch else { return }
        running = id
        runningLaunch = launch
        remote.store.selectedSessionID = id
        switch launch {
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
        if let palette { nt_palette_set_dpi(palette, dpi) }
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
    private func windowMenu() {
        var corner = POINT(x: titleBar.span(of: .menu).left, y: titleBar.height)
        ClientToScreen(window, &corner)
        run(showMenu(windowEntries, owner: window, at: corner))
    }

    /// windowEntries is the ☰ menu as it stands now, which the command palette lists too.
    private var windowEntries: [NativeMenu.Entry] {
        NativeMenu.window(profiles: profiles, defaultProfile: defaultProfile, server: serverLabel, serverConnected: remote.connected,
                          canCloseSession: canCloseSelected, sessionCount: tagged.count, canRenameSession: canRename(selected),
                          canRestartSession: canRestart(selected), hasSelection: visibleTerminal.hasSelection,
                          canPaste: IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)), shortcuts: Keys.keymap.shortcuts)
    }

    /// treeMenu is the sidebar's menu, for the session under the right click, which it selects first.
    fileprivate func treeMenu(x: Int32, y: Int32) {
        guard let tree else { return }
        var point = POINT(x: x, y: y)
        let tag = nt_tree_item_at(tree, &point.x, &point.y)
        if tag > 0, Int(tag) <= tagged.count { select(tagged[Int(tag) - 1]) }
        if x != -1 || y != -1 { point = POINT(x: x, y: y) }
        run(showMenu(NativeMenu.sessions(profiles: profiles, defaultProfile: defaultProfile, server: serverLabel, serverConnected: remote.connected,
                                         canCloseSession: canCloseSelected, sessionCount: tagged.count,
                                         canRenameSession: canRename(selected), canRestartSession: canRestart(selected),
                                         shortcuts: Keys.keymap.shortcuts),
                     owner: window, at: point))
    }

    /// run does what a menu or palette picked. The terminal takes focus first, so Find, Rename and the palettes keep
    /// the focus they move to their own field.
    private func run(_ pick: NativeMenu.Pick?) {
        log("native shell: menu picked \(pick.map { "\($0)" } ?? "nothing")")
        focus()
        switch pick {
        case .command(let command)?: windowCommand(command)
        case .profile(let index)? where profiles.indices.contains(index): newSession(profiles[index])
        case .defaultProfile(let index)? where profiles.indices.contains(index):
            settings.defaultProfile = profiles[index].name
            saveSettings()
        default: break
        }
    }

    // MARK: palettes

    private func openPalette(_ mode: Palette.Mode) {
        guard let palette else { return }
        paletteMode = mode
        paletteRows = rows(for: mode)
        let cue = Array(mode.cue.utf16) + [0]
        let (left, top, width) = paletteFrame
        nt_palette_open(palette, cue, left, top, width)
        paletteQueryChanged()
        log("native shell: \(mode) palette, \(paletteRows.count) row(s)")
    }

    private func rows(for mode: Palette.Mode) -> [Palette.Row] {
        switch mode {
        case .sessions:
            let counting = settings.notifications.unseenCount
            let localRows = locals.map {
                Palette.Local(id: $0.id, name: $0.name, exited: $0.exited, attention: $0.attention || $0.unseen > 0,
                              unseen: counting ? $0.unseen : 0)
            }
            return Palette.sessionRows(locals: localRows, server: remote.store.workspaces, serverLabel: serverLabel,
                                       unseen: counting ? serverUnseen : [:])
        case .commands:
            return Palette.commandRows(windowEntries)
        }
    }

    /// paletteFrame centres the palette over the terminal, under the title bar.
    private var paletteFrame: (Int32, Int32, Int32) {
        var client = RECT()
        GetClientRect(window, &client)
        let area = max(client.right - sidebarWidth, 1)
        let width = max(min(scaled(640), area - scaled(32)), min(area, scaled(240)))
        return (sidebarWidth + (area - width) / 2, titleBar.height + scaled(8), width)
    }

    private func placePalette() {
        guard let palette else { return }
        let (left, top, width) = paletteFrame
        nt_palette_place(palette, left, top, width)
    }

    fileprivate func paletteQueryChanged() {
        guard let palette, paletteMode != nil else { return }
        var text = [UInt16](repeating: 0, count: 512)
        let length = nt_palette_query(palette, &text, Int32(text.count))
        paletteShown = Palette.filter(paletteRows, query: String(decoding: text.prefix(Int(max(length, 0))), as: UTF16.self))
        let lines = paletteShown.map { (Array($0.title.utf16) + [0], Array($0.subtitle.utf16) + [0], Array($0.detail.utf16) + [0], $0.enabled) }
        withPaletteRows(lines) { nt_palette_set_rows(palette, $0, Int32(lines.count), 0) }
    }

    /// withPaletteRows lends the shim pointers into `lines`, valid for the call only.
    private func withPaletteRows(_ lines: [([UInt16], [UInt16], [UInt16], Bool)], _ body: (UnsafePointer<nt_palette_row>?) -> Void) {
        var rows: [nt_palette_row] = []
        func lend(_ index: Int) {
            guard index < lines.count else { return rows.withUnsafeBufferPointer { body($0.baseAddress) } }
            lines[index].0.withUnsafeBufferPointer { title in
                lines[index].1.withUnsafeBufferPointer { subtitle in
                    lines[index].2.withUnsafeBufferPointer { detail in
                        rows.append(nt_palette_row(title: title.baseAddress, subtitle: subtitle.baseAddress, detail: detail.baseAddress,
                                                   enabled: lines[index].3 ? 1 : 0))
                        lend(index + 1)
                    }
                }
            }
        }
        lend(0)
    }

    /// paletteRun runs the highlighted row if it can still act: a row is checked again against the window as it is
    /// now, and an inert one leaves the palette open, as on a Mac.
    fileprivate func paletteRun(_ index: Int) {
        guard let mode = paletteMode, paletteShown.indices.contains(index) else { return }
        let row = paletteShown[index]
        guard let live = rows(for: mode).first(where: { $0.target == row.target }), live.enabled else {
            log("native shell: palette row \(row.title) cannot run now")
            return
        }
        closePalette(refocus: false)
        switch row.target {
        case .session(let id):
            select(id)
            focus()
        case .pick(let pick):
            run(pick)
        }
    }

    fileprivate func closePalette(refocus: Bool) {
        guard paletteMode != nil else { return }
        paletteMode = nil
        paletteRows = []
        paletteShown = []
        if let palette { nt_palette_close(palette) }
        if refocus { focus() }
    }

    // MARK: title bar

    private var titleBar: TitleBar { titleBar(of: window) }

    /// titleBar(of:) reads the window it is given: the frame messages arrive while CreateWindowExW has not returned.
    private func titleBar(of window: HWND?) -> TitleBar {
        var client = RECT()
        GetClientRect(window, &client)
        return TitleBar(width: client.right, sidebarWidth: sidebarWidth, dpi: dpi)
    }

    private func invalidateTitleBar() {
        guard let window else { return }
        var rect = RECT(left: 0, top: 0, right: titleBar.width, bottom: titleBar.height)
        InvalidateRect(window, &rect, false)
    }

    /// titleChanged shows the selected session's name in the title bar and on the taskbar.
    private func titleChanged() {
        let title = selected.flatMap(name(of:)) ?? "agterm"
        guard let window, title != shownTitle else { return }
        shownTitle = title
        SetWindowTextW(window, Array(title.utf16) + [0])
        invalidateTitleBar()
    }

    private func updateTips() {
        let bar = titleBar
        for button in TitleBar.Button.allCases where !button.isCaption {
            let span = bar.span(of: button)
            let tip = Array((button.tip(Keys.keymap.shortcuts) ?? "").utf16) + [0]
            nt_tooltip_set(tooltip, UnsafeMutableRawPointer(window), UInt(button.rawValue + 1), span.left, 0, span.right, bar.height, tip)
        }
    }

    /// frameThickness is the resize band Windows gives a sizable frame, the part it hangs off the monitor when maximized.
    fileprivate static func frameThickness(_ window: HWND?) -> Int32 {
        let dpi = GetDpiForWindow(window)
        return GetSystemMetricsForDpi(SM_CYFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi)
    }

    /// clientArea answers WM_NCCALCSIZE: the client takes the caption and keeps the side and bottom frame Windows resizes
    /// from; maximized, its top comes down by the frame that hangs above the monitor.
    fileprivate static func clientArea(_ window: HWND?, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        guard wParam != 0, let params = UnsafeMutablePointer<NCCALCSIZE_PARAMS>(bitPattern: Int(lParam)) else {
            return DefWindowProcW(window, UINT(WM_NCCALCSIZE), wParam, lParam)
        }
        let top = params.pointee.rgrc.0.top
        let result = DefWindowProcW(window, UINT(WM_NCCALCSIZE), wParam, lParam)
        params.pointee.rgrc.0.top = top + (IsZoomed(window) ? frameThickness(window) : 0)
        return result
    }

    /// hitTest answers WM_NCHITTEST: Windows' own frame at the sides and bottom, then the title bar's top edge, caption
    /// buttons and drag area; its action buttons and everything below are client.
    fileprivate func hitTest(_ window: HWND?, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
        let frame = DefWindowProcW(window, UINT(WM_NCHITTEST), wParam, lParam)
        guard frame == hitClient else { return frame }
        var point = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        ScreenToClient(window, &point)
        switch titleBar(of: window).hit(x: point.x, y: point.y, topBorder: IsZoomed(window) ? 0 : Self.frameThickness(window)) {
        case .top: return hitTop
        case .caption: return hitCaption
        case .button(let button): return button.hitCode ?? hitClient
        case .outside: return hitClient
        }
    }

    /// clientButton is the action button under a client point; caption buttons are the frame's, never the client's.
    private func clientButton(_ lParam: LPARAM) -> TitleBar.Button? {
        let x = Int32(Int16(truncatingIfNeeded: lParam)), y = Int32(Int16(truncatingIfNeeded: lParam >> 16))
        guard case .button(let button) = titleBar.hit(x: x, y: y, topBorder: 0), !button.isCaption else { return nil }
        return button
    }

    /// hover lights `button`; Windows reports leaving the client and the frame separately, so each clears only its own.
    fileprivate func hover(_ button: TitleBar.Button?, frame: Bool) {
        var track = TRACKMOUSEEVENT(cbSize: DWORD(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: frame ? trackLeaveFrame : trackLeave,
                                    hwndTrack: window, dwHoverTime: 0)
        TrackMouseEvent(&track)
        guard button != hovered else { return }
        hovered = button
        invalidateTitleBar()
    }

    fileprivate func left(frame: Bool) {
        guard let hovered, hovered.isCaption == frame else { return }
        if pressed == hovered && frame { pressed = nil }
        self.hovered = nil
        invalidateTitleBar()
    }

    fileprivate func mouseMoved(_ lParam: LPARAM) { hover(clientButton(lParam), frame: false) }

    fileprivate func mouseDown(_ lParam: LPARAM) {
        guard let button = clientButton(lParam) else { return }
        pressed = button
        SetCapture(window)
        invalidateTitleBar()
    }

    fileprivate func mouseUp(_ lParam: LPARAM) {
        guard let button = pressed, !button.isCaption else { return }
        pressed = nil
        ReleaseCapture()
        invalidateTitleBar()
        if clientButton(lParam) == button { PostMessageW(window, Self.titleActionMessage, WPARAM(button.rawValue), 0) }
    }

    /// frameDown takes a caption button's press so DefWindowProc does not run its own, which draws the classic buttons.
    fileprivate func frameDown(_ wParam: WPARAM) -> Bool {
        guard let button = TitleBar.Button(hitCode: LRESULT(truncatingIfNeeded: wParam)) else { return false }
        pressed = button
        invalidateTitleBar()
        return true
    }

    fileprivate func frameUp(_ wParam: WPARAM) -> Bool {
        guard let button = pressed, button.isCaption else { return false }
        pressed = nil
        invalidateTitleBar()
        if TitleBar.Button(hitCode: LRESULT(truncatingIfNeeded: wParam)) == button {
            PostMessageW(window, Self.titleActionMessage, WPARAM(button.rawValue), 0)
        }
        return true
    }

    /// titleActionMessage carries a released button's action out of the mouse message, as the Win-key hook posts its
    /// command: a new session or a menu then runs with no button message or capture in flight.
    fileprivate static let titleActionMessage = UINT(WM_APP + 23)

    fileprivate func act(_ button: TitleBar.Button) {
        switch button {
        case .menu: windowMenu()
        case .minimize: ShowWindow(window, SW_MINIMIZE)
        case .maximize: ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE)
        case .close: PostMessageW(window, UINT(WM_CLOSE), 0, 0)
        case .newSession:
            windowCommand(.newSession)
            focus()
        case .find: windowCommand(.find)
        }
    }

    fileprivate func activated(_ active: Bool) {
        windowActive = active
        invalidateTitleBar()
    }

    /// fromKeyboard is whether a WM_CONTEXTMENU came from the keyboard, whose point is (-1, -1).
    fileprivate static func fromKeyboard(_ lParam: LPARAM) -> Bool {
        Int16(truncatingIfNeeded: lParam) == -1 && Int16(truncatingIfNeeded: lParam >> 16) == -1
    }

    /// systemMenu shows the window menu at a WM_CONTEXTMENU's point: DefWindowProc finds no caption in a frame that has
    /// none, so the drag area shows it itself, with what the window's state allows enabled.
    fileprivate func systemMenu(_ lParam: LPARAM) {
        guard let menu = GetSystemMenu(window, false) else { return }
        let zoomed = IsZoomed(window)
        for (item, enabled) in [(SC_RESTORE, zoomed), (SC_MOVE, !zoomed), (SC_SIZE, !zoomed), (SC_MINIMIZE, true), (SC_MAXIMIZE, !zoomed),
                                (SC_CLOSE, true)] {
            EnableMenuItem(menu, UINT(item), UINT(MF_BYCOMMAND) | UINT(enabled ? MF_ENABLED : MF_GRAYED))
        }
        let picked = nt_track_menu(UnsafeMutableRawPointer(menu), UnsafeMutableRawPointer(window), Int32(Int16(truncatingIfNeeded: lParam)),
                                   Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        if picked != 0 { PostMessageW(window, UINT(WM_SYSCOMMAND), WPARAM(picked), 0) }
    }

    /// inCaption is whether a WM_CONTEXTMENU's screen point is on the title bar's drag area, which shows the window menu.
    fileprivate func inCaption(_ lParam: LPARAM) -> Bool {
        hitTest(window, 0, lParam) == hitCaption
    }

    /// onTitleButton is whether a WM_CONTEXTMENU's screen point is on one of the title bar's buttons, which have none.
    fileprivate func onTitleButton(_ lParam: LPARAM) -> Bool {
        var point = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        ScreenToClient(window, &point)
        if case .button = titleBar.hit(x: point.x, y: point.y, topBorder: 0) { return true }
        return false
    }

    fileprivate func paint() {
        let bar = titleBar
        let maximized = IsZoomed(window)
        let buttons = TitleBar.Button.allCases.map { button in
            let span = bar.span(of: button)
            let lit = hovered == button && (pressed == nil || pressed == button)
            return nt_title_button(left: span.left, right: span.right, glyph: button.glyph(maximized: maximized),
                                   kind: button == .close ? 2 : button.isCaption ? 1 : 0, state: lit ? (pressed == button ? 2 : 1) : 0)
        }
        buttons.withUnsafeBufferPointer { buttons in
            nt_title_bar_paint(UnsafeMutableRawPointer(window), dpi, bar.height, Array(shownTitle.utf16) + [0], bar.title.left,
                               bar.title.right, buttons.baseAddress, Int32(buttons.count), windowActive ? 1 : 0)
        }
    }
}

private let hitClient: LRESULT = 1
private let hitCaption: LRESULT = 2
private let hitTop: LRESULT = 12
private let trackLeave = DWORD(0x2)        // TME_LEAVE
private let trackLeaveFrame = DWORD(0x12)  // TME_LEAVE | TME_NONCLIENT
private let messageNCMouseMove = UINT(0x00A0)
private let messageNCLeftDown = UINT(0x00A1)
private let messageNCLeftUp = UINT(0x00A2)
private let messageNCMouseLeave = UINT(0x02A2)
private let messageMouseLeave = UINT(0x02A3)

private extension TitleBar.Button {
    /// hitCode is what WM_NCHITTEST answers for a caption button (HTMINBUTTON, HTMAXBUTTON, HTCLOSE).
    var hitCode: LRESULT? {
        switch self {
        case .minimize: 8
        case .maximize: 9
        case .close: 20
        default: nil
        }
    }

    init?(hitCode: LRESULT) {
        guard let button = Self.allCases.first(where: { $0.hitCode == hitCode }) else { return nil }
        self = button
    }

    func glyph(maximized: Bool) -> UInt16 {
        switch self {
        case .menu: 0xE700
        case .newSession: 0xE710
        case .find: 0xE721
        case .minimize: 0xE921
        case .maximize: maximized ? 0xE923 : 0xE922
        case .close: 0xE8BB
        }
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
               let chord = Keys.chord(virtualKey: Int32(key.pointee.wVKey)) {
                switch Keys.keymap.press(chord) {
                case .command(let command):
                    shell.windowCommand(command)
                    return 1
                case .consumed: return 1
                case .pass: break
                }
            }
            var tag: Int64 = 0
            if nt_tree_selection_changed(Int(lParam), &tag) != 0 { shell.userSelected(tag) }
            return 0
        case UINT(WM_NCCALCSIZE):
            return NativeShell.clientArea(window, wParam, lParam)
        case UINT(WM_NCHITTEST):
            return shell.hitTest(window, wParam, lParam)
        case UINT(WM_PAINT):
            shell.paint()
            return 0
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_ACTIVATE):
            shell.activated(wParam & 0xFFFF != WPARAM(WA_INACTIVE))
            return DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_MOUSEMOVE):
            shell.mouseMoved(lParam)
            return 0
        case UINT(WM_LBUTTONDOWN):
            shell.mouseDown(lParam)
            return 0
        case UINT(WM_LBUTTONUP):
            shell.mouseUp(lParam)
            return 0
        case messageMouseLeave:
            shell.left(frame: false)
            return 0
        case messageNCMouseMove:
            shell.hover(TitleBar.Button(hitCode: LRESULT(truncatingIfNeeded: wParam)), frame: true)
            return DefWindowProcW(window, message, wParam, lParam)
        case messageNCMouseLeave:
            shell.left(frame: true)
            return DefWindowProcW(window, message, wParam, lParam)
        case messageNCLeftDown:
            return shell.frameDown(wParam) ? 0 : DefWindowProcW(window, message, wParam, lParam)
        case messageNCLeftUp:
            return shell.frameUp(wParam) ? 0 : DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_COMMAND):
            if wParam >> 16 & 0xFFFF == WPARAM(EN_CHANGE) { shell.findChanged() }
            return 0
        case NativeShell.titleActionMessage:
            if let button = TitleBar.Button(rawValue: Int(wParam)) { shell.act(button) }
            return 0
        case UINT(NT_PALETTE_QUERY):
            shell.paletteQueryChanged()
            return 0
        case UINT(NT_PALETTE_RUN):
            shell.paletteRun(Int(Int32(truncatingIfNeeded: wParam)))
            return 0
        case UINT(NT_PALETTE_CLOSE):
            shell.closePalette(refocus: wParam == 0)
            return 0
        case UINT(NT_FIND_NEXT):
            shell.findNext(newer: wParam != 0)
            return 0
        case UINT(NT_FIND_CLOSE):
            shell.closeFindBar()
            return 0
        case UINT(WM_CTLCOLOREDIT):
            return shell.editColors(HDC(bitPattern: UInt(wParam)))
        case UINT(WM_CONTEXTMENU) where !NativeShell.fromKeyboard(lParam) && shell.inCaption(lParam):
            shell.systemMenu(lParam)
            return 0
        case UINT(WM_CONTEXTMENU) where !NativeShell.fromKeyboard(lParam) && shell.onTitleButton(lParam):
            return 0
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
        case UINT(WM_SETTINGCHANGE):
            if let area = UnsafePointer<UInt16>(bitPattern: Int(lParam)), String(decodingCString: area, as: UTF16.self) == "ImmersiveColorSet" {
                shell.systemAppearanceChanged()
            }
            return DefWindowProcW(window, message, wParam, lParam)
        case NativeShell.toastMessage:
            if let text = UnsafeMutablePointer<UInt16>(bitPattern: Int(lParam)) {
                let group = String(decodingCString: text, as: UTF16.self)
                nt_toast_free(text)
                if let id = Foundation.UUID(uuidString: group) { shell.reveal(id) }
            }
            return 0
        case WinKeyHook.commandMessage:
            if let command = NativeMenu.Command(rawValue: Int(wParam)) { shell.windowCommand(command) }
            return 0
        case UINT(WM_DESTROY):
            WinKeyHook.remove()
            shell.closing()
            PostQuitMessage(0)
            return 0
        default:
            return DefWindowProcW(window, message, wParam, lParam)
        }
    }
}

// MARK: control

extension NativeShell: NativeControlHost {
    var localSessions: [NativeControl.Local] {
        locals.map {
            NativeControl.Local(id: $0.id, name: $0.name, commandLine: $0.commandLine, exited: $0.exited, attention: $0.attention, unseen: $0.unseen,
                                cwd: $0.directory ?? "", title: $0.programTitle)
        }
    }

    var selectedSession: Foundation.UUID? { selected }

    var serverWorkspaces: [ControlWorkspaceNode] {
        remote.connected ? remote.store.controlTree(paneForeground: { _ in nil }).workspaces : []
    }

    func isServerSession(_ id: Foundation.UUID) -> Bool { remote.session(id) != nil }

    func newLocalSession(name: String?, command: String?, cwd: String?, select: Bool) -> Foundation.UUID? {
        let customName = name.flatMap(SessionNaming.customName)
        if let command {
            return startLocal(fallback: "Session \(locals.count + 1)", customName: customName, commandLine: command, directory: cwd,
                              selecting: select)
        }
        guard profiles.indices.contains(defaultProfile) else { return nil }
        let profile = profiles[defaultProfile]
        return startLocal(fallback: fallbackName(for: profile), customName: customName, commandLine: profile.commandLine, directory: cwd,
                          selecting: select)
    }

    func newServerSession() async -> ControlResponse {
        guard remote.connected, let workspace = remote.store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no connection to \(serverLabel)")
        }
        sessionsBeforeCreate = Set(remote.store.workspaces.flatMap(\.sessions).map(\.id))
        let response = await remote.perform(.newSession(workspace: workspace))
        if !response.ok { sessionsBeforeCreate = nil }
        return response
    }

    func closeSession(_ id: Foundation.UUID) async -> ControlResponse {
        if locals.contains(where: { $0.id == id }) {
            closeLocal(id)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        return await remote.perform(.closeSession(id, undoable: true))
    }

    func renameSession(_ id: Foundation.UUID, to name: String) async -> ControlResponse {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].customName = SessionNaming.customName(name)
            rebuild()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        return await remote.perform(.renameSession(id, name: name))
    }

    /// restartSession runs a local session's program again, ended or not, as `session.restart` replaces a live pane's.
    func restartSession(_ id: Foundation.UUID) async -> ControlResponse {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].exited = false
            launch(locals[index])
            rebuild()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        return await remote.perform(.restart(id, pane: .left, command: nil))
    }

    func selectSession(_ id: Foundation.UUID) { select(id) }

    /// terminal is the terminal showing `id`: its own for a local session, the shared one while it shows a server one.
    private func terminal(of id: Foundation.UUID) -> NativeTerminal? {
        locals.first { $0.id == id }?.terminal ?? (running == id ? remoteTerminal : nil)
    }

    func type(_ text: String, into id: Foundation.UUID) -> Bool { terminal(of: id)?.type(text) ?? false }

    func screen(of id: Foundation.UUID) -> (lines: [String], rows: Int)? { terminal(of: id)?.screen }

    func notify(_ id: Foundation.UUID, title: String, body: String) -> String? {
        deliver(id, title: title, body: body, source: .control)
    }

    var fontPoints: Float { settings.fontPoints }

    var keymap: ControlKeymap { Keys.keymap.control }

    var appearance: Appearance { settings.appearance }

    var themeCatalog: ThemeCatalog { TerminalAppearance.themes.catalog }

    var systemIsDark: Bool { TerminalAppearance.isDark }

    func openSettings(tab: SettingsTab) { showSettings(tab: tab) }

    func setAppearance(_ appearance: Appearance) {
        settings.appearance = appearance
        saveSettings()
        applyAppearance(.init(appearance: appearance, points: shown.points, notifications: settings.notifications, general: settings.general))
    }

    func reloadKeymap() -> Int { Keys.reload(owner: window, quiet: true) }

    func setFontPoints(_ points: Float) { setFontSize(points) }
}
