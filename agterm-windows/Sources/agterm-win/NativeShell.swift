import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

private nonisolated(unsafe) var shell: NativeShell!
private let localWorkspaceID = Foundation.UUID()
/// shellWindowID is the single agterm-win window for PickRegistry and SessionPickBook replica placement.
private let shellWindowID = Foundation.UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

/// NativeShell is the application window: a Win32 sidebar beside the selected native terminal. It holds local
/// sessions started from launch profiles, each with a terminal of its own, and the catalogs of the agterm-servers started
/// in WSL distributions, whose sessions share one terminal that attaches whichever is selected.
@MainActor
final class NativeShell {
    struct LocalSession {
        let id = Foundation.UUID()
        /// fallback names the session until its program reports a title or a folder: its profile's name.
        let fallback: String
        var customName: String?
        var programTitle: String?
        /// directory is the folder the shell last reported, decoded.
        var directory: String?
        let commandLine: String
        /// terminal is the primary pane's; a swap exchanges it with the split's.
        var terminal: NativeTerminal
        var exited = false
        /// attention is a bell since the session was last in view.
        var attention = false
        /// unseen counts notifications since the session was last in view.
        var unseen = 0
        var overlay: Overlay?
        var overlayExitCode: Int?
        var pageOverlay: (page: HtmlOverlay, sizePercent: Int?, hidden: Bool, frame: PageOverlayFrame)?
        /// split and its terminal are the second pane, both nil without one; a hidden split keeps its shell.
        var split: NativeSplit?
        var splitTerminal: NativeTerminal?
        var splitTitle: String?
        var splitDirectory: String?
        /// scratch is the session's third shell, kept while hidden; it covers the panes while `scratchShown`.
        var scratch: NativeTerminal?
        var scratchShown = false
        var scratchDirectory: String?

        /// name follows the focused pane's title and folder, as a Mac's split session's does.
        var name: String {
            let inSplit = split?.focused == true && splitTerminal != nil
            return SessionNaming.displayName(customName: customName, title: inSplit ? splitTitle : programTitle,
                                             directory: inSplit ? splitDirectory ?? directory : directory, fallback: fallback)
        }

        /// terminals are every terminal the session owns but its overlay's.
        var terminals: [NativeTerminal] { [terminal] + [splitTerminal, scratch].compactMap { $0 } }

        /// onScreen is the pane in view: a shown scratch, else the focused pane.
        var onScreen: NativeTerminal {
            switch NativePane.onScreen(split: splitTerminal == nil ? nil : split, scratchShown: scratchShown && scratch != nil) {
            case .scratch: scratch ?? terminal
            case .split: splitTerminal ?? terminal
            case .primary: terminal
            }
        }

        func pane(_ pane: NativePane) -> NativeTerminal? {
            switch pane {
            case .primary: terminal
            case .split: splitTerminal
            case .scratch: scratch
            }
        }
    }

    struct Overlay {
        var state: NativeOverlay
        let frame: OverlayFrame
        var terminal: NativeTerminal { frame.terminal }
    }

    /// ServerOverlay is a catalog session's program overlay, run in WSL through the job helper the origin handed over.
    private struct ServerOverlay {
        var state: NativeOverlay
        let frame: OverlayFrame
        let job: String
        var exitCode: Int?
        var terminal: NativeTerminal { frame.terminal }
    }

    private struct ServerPageOverlay {
        var page: HtmlOverlay
        var sizePercent: Int?
        var hidden: Bool
        let frame: PageOverlayFrame
        var channel: ReplicaPageServeClient?
        var offer: Int?
        var appliedSeq = 0
    }

    /// Server is an agterm-server started this launch, under its sidebar group.
    @MainActor
    private final class Server {
        let remote: RemoteWindow
        let group = Foundation.UUID()
        /// bootstrapNotice is shown in the title-bar strip until the catalog connects or install refuses.
        var bootstrapNotice: String?

        init(_ remote: RemoteWindow) { self.remote = remote }

        var distribution: String { remote.host.distribution }
        var label: String { NativeShell.label(of: distribution) }
    }

    /// servers are the started agterm-servers, in the order they started; a distribution's server is here only once
    /// started, so nothing runs wsl.exe for it before then.
    private var servers: [Server] = []
    /// distributions are the WSL distributions that can hold a server, once wsl.exe lists them.
    private var distributions: [String] = []
    // distributions whose first start is asking, so a Start the question's message loop delivers waits for the answer
    private var asking: Set<String> = []
    private let settingsURL: URL
    var settings: NativeSettings
    var window: HWND?
    var tree: UnsafeMutableRawPointer?
    private var notice: HWND?
    private var findBar: HWND?
    private var findFailed = false
    private var tooltip: UnsafeMutableRawPointer?
    var palette: UnsafeMutableRawPointer?
    // the open palette, what it lists, and the rows its query leaves, which Enter's index refers to
    private var paletteMode: Palette.Mode?
    private var paletteRows: [Palette.Row] = []
    private var paletteShown: [Palette.Row] = []
    // the title bar's button under the mouse, and the one a press started on, which acts if the release is on it too
    private var hovered: TitleBar.Button?
    private var pressed: TitleBar.Button?
    private var pressedMenuTab: Int?
    private var pressedAppIcon = false
    private var appIconHighlight = false
    private var windowActive = true
    private var shownTitle = "agterm"
    var remoteTerminal: NativeTerminal!
    var locals: [LocalSession] = []
    /// serverOverlays holds a program overlay per catalog session the presentation stream opened.
    private var serverOverlays: [Foundation.UUID: ServerOverlay] = [:]
    private var serverPageOverlays: [Foundation.UUID: ServerPageOverlay] = [:]
    /// ServerHud is a mirrored passive panel over a catalog session; it does not take the keyboard from the terminal.
    private struct ServerHud {
        let panel: HWND
        var hideTask: Task<Void, Never>?
    }
    private var serverHuds: [Foundation.UUID: ServerHud] = [:]
    private let pickController = PickController()
    /// pickPalette is set while the palette lists a replica pick; it shares the palette with the session and command lists.
    private var pickPalette: PendingPick?
    private var profiles = LaunchProfiles.available(wslDistributions: [], powerShell7: NativeShell.powerShell7())
    var selected: Foundation.UUID?
    // the server's sessions before New Session on Server, so the one it adds is selected when the catalog shows it
    private var sessionsBeforeCreate: Set<Foundation.UUID>?
    private var running: Foundation.UUID?
    // what the remote terminal was last given, so a session that ends or comes back is shown again
    private var runningLaunch: SessionSidebar.Launch?
    // the tree's tags index these; 0 is a workspace row
    private var tagged: [Foundation.UUID] = []
    private var dimmed: [UInt8] = []
    private var items: [Foundation.UUID: UnsafeMutableRawPointer] = [:]
    var darkBrush = CreateSolidBrush(0x262525)
    var dpi: UInt32 = 96
    private var control: ControlSocket?
    private let version: String
    /// quick is the quick terminal's panel, made on its first show.
    var quick: QuickWindow?
    /// dashboard is the open dashboard, nil while closed; captions are its cells' name strips.
    var dashboard: NativeControl.Dashboard?
    var captions: [HWND] = []
    /// recentSessions are the sessions most recently selected first, which the dashboard opens with.
    var recentSessions: [Foundation.UUID] = []
    /// dragging is the session whose divider the mouse is moving, and the area its panes share.
    var dragging: (id: Foundation.UUID, area: NativeOverlay.Rect)?
    /// sidebarDragging moves the sidebar divider in client pixels.
    var sidebarDragging = false
    var menuBarHighlight: Int?
    var highlightBrush = CreateSolidBrush(0x784F26)
    /// closeSessionCoalesced swallows a second Close Session chord right after one dismissed an overlay; arm64 can deliver two.
    private var closeSessionCoalesced: Date?

    /// open shows the window; `profiles` name launch profiles to start local sessions from once they are known.
    /// `server` (`--wsl`) starts that distribution's agterm-server as the menu does, installing it first when
    /// `installServer`; the others start as agterm opens only where the user chose that.
    static func open(settings: URL, profiles: [String], version: String, server: String?, installServer: Bool) {
        nt_init_process()
        shell = NativeShell(settingsURL: settings, version: version)
        shell.create(starting: profiles, server: server, installServer: installServer)
    }

    private init(settingsURL: URL, version: String) {
        self.settingsURL = settingsURL
        self.version = version
        settings = NativeSettings.load(from: settingsURL)
        TerminalAppearance.use(settings.appearance)
        applyGeneral()
        applyChrome()
    }

    private func create(starting requested: [String], server requestedServer: String?, installServer: Bool) {
        let instance = GetModuleHandleW(nil)
        let className = Array("agterm-shell".utf16) + [0]
        className.withUnsafeBufferPointer { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            // a divider's double-click evens its split
            windowClass.style = UINT(CS_DBLCLKS)
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
        PickRegistry.shared.register(shellWindowID, controller: pickController)
        control = ControlSocket.start(path: socketPath, host: self, version: version)
        startToasts()
        Keys.onReload = { [unowned self] in
            WinKeyHook.update(window: self.window)
            self.registerGlobalHotkey()
            self.updateTips()
        }
        WinKeyHook.update(window: window)
        registerGlobalHotkey()
        DispatchQueue.main.async { Keys.report(window) }
        // WM_NCCALCSIZE gives the caption to the client from here on; the taller client's WM_SIZE lays out every child,
        // so they all exist by now
        SetWindowPos(window, nil, 0, 0, 0, 0, UINT(SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE))
        restorePlacement()
        layout()
        restoreLocals()
        discoverProfiles(then: requested)
        catalogChanged()
        let starting = (requestedServer.map { [$0] } ?? []) + ServerLaunch.atLaunch(settings.serverLaunch).filter { $0 != requestedServer }
        if starting.isEmpty {
            remoteTerminal.show(notice: ServerLaunch.notStartedNotice)
            log("native shell: no agterm-server starts at launch")
        } else {
            // once the window is up, so the question a first start asks has it to sit on
            DispatchQueue.main.async { [self] in
                for distribution in starting {
                    startServer(distribution, installing: installServer && distribution == requestedServer)
                }
            }
        }
    }

    // MARK: agterm-server

    fileprivate static func label(of distribution: String) -> String { "WSL \(distribution)" }

    /// menuServers are the servers the menus offer: every distribution WSL lists, then any started that it does not.
    private var menuServers: [String] {
        distributions + servers.map(\.distribution).filter { !distributions.contains($0) }
    }

    private func server(_ distribution: String) -> Server? { servers.first { $0.distribution == distribution } }

    /// server(of:) is the server holding session `id`.
    private func server(of id: Foundation.UUID) -> Server? { servers.first { $0.remote.session(id) != nil } }

    private func serverSession(_ id: Foundation.UUID) -> Session? { servers.lazy.compactMap { $0.remote.session(id) }.first }

    /// currentServer is where New Session on Server opens one: the selected session's server, else the first connected.
    private var currentServer: Server? {
        selected.flatMap(server(of:)) ?? servers.first { $0.remote.connected }
    }

    private var serverEntries: [NativeMenu.Server] {
        let current = currentServer?.distribution
        return menuServers.map { distribution in
            let started = server(distribution)
            return NativeMenu.Server(label: Self.label(of: distribution), started: started != nil,
                                     connected: started?.remote.connected == true, current: distribution == current)
        }
    }

    /// startServer connects to `distribution`'s agterm-server, installing it first when `installing`; while nothing is
    /// chosen for the distribution, a start that is `asking` first asks whether the server starts at launch.
    private func startServer(_ distribution: String, installing: Bool = false, asking ask: Bool = true) {
        guard server(distribution) == nil, !asking.contains(distribution) else { return }
        if ask, ServerLaunch.asks(settings.serverLaunch[distribution]) {
            asking.insert(distribution)
            askServerLaunch(distribution)
            asking.remove(distribution)
        }
        let started = Server(RemoteWindow(host: WSLHost(distribution: distribution), stateDirectory: stateDirectory))
        started.remote.changed = { [weak self] in self?.catalogChanged() }
        started.remote.onNotification = { [weak self] id, notification in
            self?.deliver(id, title: notification.title, body: notification.body, source: notification.source == "control" ? .control : .terminal)
        }
        started.remote.onReplicaOverlay = { [weak self, weak started] id, overlay in
            guard let self, let started else { return false }
            return self.showReplicaOverlay(on: started, sessionID: id, overlay: overlay)
        }
        started.remote.onReplicaOverlayClose = { [weak self] id, change in
            self?.closeServerReplicaOverlay(id, change: change)
        }
        started.remote.onReplicaOverlayResize = { [weak self] id, change in
            self?.resizeServerReplicaOverlay(id, change: change)
        }
        started.remote.onPresentationStopped = { [weak self] id in
            self?.clearServerReplicaOverlay(id, notifyOrigin: false)
            self?.clearServerPageOverlay(id, notifyOrigin: false)
            self?.dismissReplicaAsk(ifShownFor: id)
            self?.clearServerHud(id)
            SessionPickBook.shared.dropReplicas(forSession: id)
        }
        started.remote.onReplicaPick = { [weak self, weak started] id, pick in
            guard let self, let started else { return false }
            return self.showReplicaPick(on: started, sessionID: id, pick: pick)
        }
        started.remote.onReplicaPickDismiss = { [weak self, weak started] id, ref in
            guard let self, let started else { return }
            self.dismissReplicaPick(on: started, sessionID: id, ref: ref)
        }
        started.remote.onReplicaHud = { [weak self, weak started] id, hud in
            guard let self, let started else { return }
            self.showReplicaHud(on: started, sessionID: id, hud: hud)
        }
        started.remote.onReplicaAsk = { [weak self, weak started] id, ask in
            guard let self, let started else { return false }
            return self.showReplicaAsk(on: started, sessionID: id, ask: ask)
        }
        started.remote.onReplicaAskDismiss = { [weak self, weak started] id, ref in
            guard let self, let started else { return }
            self.dismissReplicaAsk(on: started, sessionID: id, ref: ref)
        }
        started.remote.onReplicaPage = { [weak self, weak started] id, page in
            guard let self, let started else { return RemotePresentationClient.pagesUnsupported }
            return self.showReplicaPage(on: started, sessionID: id, page: page)
        }
        started.remote.onReplicaPageClose = { [weak self] id, change in
            self?.closeReplicaPage(sessionID: id, change: change)
        }
        started.remote.onReplicaPageCommand = { [weak self, weak started] id, command in
            guard let self, let started else { return }
            self.applyReplicaPageCommand(on: started, sessionID: id, command: command)
        }
        started.remote.store.onReplicaPageChanged = { [weak self] pageID in
            guard let self else { return }
            for (sessionID, slot) in self.serverPageOverlays where slot.page.id == pageID {
                self.reportReplicaPageState(sessionID: sessionID, local: pageID)
                return
            }
        }
        if HtmlOverlayReleases.shared.onReplicaRelease == nil {
            HtmlOverlayReleases.shared.onReplicaRelease = { [weak self] local, origin in
                self?.replicaPageReleased(local: local, origin: origin)
            }
        }
        servers.append(started)
        log("native shell: starting agterm-server in \(started.label)")
        if running == nil { remoteTerminal.show(notice: "") }
        catalogChanged()
        prepareAndConnect(started, forceInstall: installing)
    }

    private func askServerLaunch(_ distribution: String) {
        let question = ServerLaunch.question(server: Self.label(of: distribution))
        let answers = ServerLaunch.Answer.allCases
        let titles = answers.map { Array($0.title.utf16) + [0] }
        let picked = Int(withWideStrings(titles) {
            nt_ask_choice(UnsafeMutableRawPointer(window), Array("agterm".utf16) + [0], Array(question.title.utf16) + [0],
                          Array(question.text.utf16) + [0], $0, Int32(titles.count))
        })
        let answer = answers.indices.contains(picked) ? answers[picked] : .notNow
        settings.serverLaunch[distribution] = ServerLaunch.choice(after: answer)
        saveSettings()
        log("native shell: agterm-server in \(Self.label(of: distribution)) at launch: \(answer)")
    }

    /// prepareAndConnect probes agterm-server in WSL, installs or starts it when needed, then opens the catalog stream.
    private func prepareAndConnect(_ server: Server, forceInstall: Bool) {
        server.bootstrapNotice = "Checking \(server.label)…"
        layout()
        let host = server.remote.host
        let label = server.label
        DispatchQueue.global().async {
            let finish: (String?) -> Void = { notice in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        server.bootstrapNotice = notice
                        shell.layout()
                        shell.catalogChanged()
                        server.remote.start()
                    }
                }
            }
            let release: (version: String, checksums: String)
            do {
                release = try serverRelease()
            } catch {
                log("server release info unavailable: \(error)")
                let notice = "\(label): this build cannot download agterm-server (\(error)). Install from a release build or run install.sh in WSL."
                finish(notice)
                return
            }
            if forceInstall {
                finish(Self.runServerInstall(host: host, label: label, release: release))
                return
            }
            let inspection = host.inspect()
            log("wsl inspect \(host.distribution): \(inspection.health) — \(inspection.detail)")
            let action = WSLServerEnsure.plan(health: inspection.health, expectedVersion: release.version)
            log("wsl ensure \(host.distribution): \(action)")
            switch action {
            case .connect:
                finish(nil)
            case .startServiceThenConnect:
                Self.dispatchNotice(host.distribution, "\(label): starting agterm-server…")
                let start = host.startService()
                if start.ok {
                    finish(nil)
                } else {
                    log("wsl start service failed: \(start.message)")
                    finish(Self.runServerInstall(host: host, label: label, release: release,
                                                 preamble: "Service did not start (\(start.message)). Installing…"))
                }
            case .install(let reason):
                finish(Self.runServerInstall(host: host, label: label, release: release, preamble: reason))
            case .refuse(let reason):
                finish("\(label): \(reason)")
            }
        }
    }

    /// runServerInstall performs download, unpack and install.sh, reporting progress in the notice strip.
    nonisolated private static func runServerInstall(host: WSLHost, label: String, release: (version: String, checksums: String),
                                                        preamble: String? = nil) -> String? {
        if let preamble { dispatchNotice(host.distribution, "\(label): \(preamble)") }
        do {
            let code = try host.installServer(version: release.version, checksums: release.checksums) { line in
                log("server install: \(line)")
                dispatchNotice(host.distribution, "\(label): \(line)")
            }
            log("server install exited \(code)")
            return WSLServerEnsure.installOutcome(exitCode: code, error: nil, label: label)
        } catch {
            log("server install failed: \(error)")
            return WSLServerEnsure.installOutcome(exitCode: 1, error: String(describing: error), label: label)
        }
    }

    nonisolated private static func dispatchNotice(_ distribution: String, _ text: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let server = shell.server(distribution) else { return }
                server.bootstrapNotice = text
                shell.layout()
            }
        }
    }

    func makeTerminal() -> NativeTerminal {
        let terminal = NativeTerminal(parent: window, points: settings.fontPoints)
        terminal.onWindowCommand = { [unowned self] in windowCommand($0) }
        terminal.onFontSize = { [unowned self] in setFontSize($0) }
        terminal.setDPI(dpi)
        return terminal
    }

    // MARK: settings

    func setFontSize(_ points: Float) {
        settings.fontPoints = points
        shown.points = points
        allTerminals.forEach { $0.setFontSize(points) }
        saveSettings()
    }

    // what the terminals draw with now: the saved appearance, or Settings' preview while it is open
    private lazy var shown = SettingsWindow.Values(appearance: settings.appearance, points: settings.fontPoints,
                                                    notifications: settings.notifications, general: settings.general)

    /// applyAppearance draws every terminal with `values`, without saving them.
    private func applyAppearance(_ values: SettingsWindow.Values) {
        let refit = TerminalAppearance.use(values.appearance)
        applyChrome()
        for terminal in allTerminals {
            terminal.applyTheme()
            if refit { terminal.applyFontFamily() }
            if values.points != shown.points { terminal.setFontSize(values.points) }
        }
        shown = values
    }

    private func showSettings(tab: SettingsTab = .general) {
        let listed = ServerLaunch.listed(available: distributions, choices: settings.serverLaunch)
        SettingsWindow.show(owner: window, tab: tab, values: .init(appearance: settings.appearance, points: settings.fontPoints,
                                                         notifications: settings.notifications, general: settings.general,
                                                         serverAtLaunch: Set(ServerLaunch.atLaunch(settings.serverLaunch))),
                            themes: TerminalAppearance.themes.catalog.names, fonts: TerminalAppearance.monospaceFonts,
                            distributions: listed,
                            preview: { [unowned self] in applyAppearance($0) },
                            finish: { [unowned self] kept in
                                guard let kept else { return }
                                settings.appearance = kept.appearance
                                settings.fontPoints = kept.points
                                settings.notifications = kept.notifications
                                settings.general = kept.general
                                settings.serverLaunch = ServerLaunch.choices(settings.serverLaunch, checked: kept.serverAtLaunch, listed: listed)
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

    func saveSettings() {
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
        PickRegistry.shared.unregister(shellWindowID)
        for id in serverHuds.keys { clearServerHud(id) }
        var placement = WINDOWPLACEMENT()
        placement.length = UINT(MemoryLayout<WINDOWPLACEMENT>.size)
        if GetWindowPlacement(window, &placement) {
            let rect = placement.rcNormalPosition
            settings.frame = .init(left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom)
            settings.maximized = placement.showCmd == UINT(SW_SHOWMAXIMIZED)
        }
        let running = locals.filter { !$0.exited }
        settings.localSessions = running.map { session in
            let split = session.splitTerminal == nil ? nil : session.split.map { NativeSettings.Split($0, directory: session.splitDirectory) }
            return .init(title: session.fallback, customName: session.customName, commandLine: session.commandLine, directory: session.directory,
                         split: split)
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
        let palette = chromePalette
        SetTextColor(context, ChromePalette.colorref(findFailed ? palette.chromeAccent : palette.chromeText))
        SetBkColor(context, ChromePalette.colorref(palette.clientBg))
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
            // without WSL, or with no distribution, wsl.exe prints why on stdout and fails; that text names none
            var listing = Data()
            if let wsl = try? HiddenProcess(commandLine: "wsl.exe --list --quiet", captureErrors: false) {
                wsl.closeInput()
                let output = wsl.readToEnd()
                wsl.waitUntilExit()
                if wsl.terminationStatus == 0 { listing = output }
            }
            let distributions = LaunchProfiles.distributions(fromWSLList: listing)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    shell.profiles = LaunchProfiles.available(wslDistributions: distributions, powerShell7: powerShell7)
                    shell.distributions = LaunchProfiles.serverDistributions(distributions)
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
            let id = startLocal(fallback: session.title, customName: session.customName, commandLine: session.commandLine,
                                directory: session.directory, selecting: false)
            if let saved = session.split { restoreSplit(id, saved) }
        }
        log("native shell: restored \(saved.count) local session(s)")
        if let index = settings.selectedLocal { select(locals[index].id) }
    }

    var stateDirectory: URL { settingsURL.deletingLastPathComponent() }

    private var socketPath: String { stateDirectory.appendingPathComponent("agterm.sock").path }

    /// sessionEnvironment is what a local session's programs inherit: the state directory, so agtermctl finds this
    /// window's socket, the session's id, and agtermctl's folder on PATH.
    func sessionEnvironment(_ id: Foundation.UUID) -> [String: String] {
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
        wirePane(session.terminal, of: id)
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

    func localExited(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        locals[index].exited = true
        rebuild()
    }

    /// localNaming takes the title and folder a pane's program reported; the sidebar changes only when the name does.
    func localNaming(_ id: Foundation.UUID, _ terminal: NativeTerminal) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let before = locals[index].name
        let title = SessionNaming.programTitle(terminal.title)
        let directory = SessionNaming.directory(fromReported: terminal.reportedDirectory)
        if terminal === locals[index].terminal {
            locals[index].programTitle = title
            if let directory { locals[index].directory = directory }
        } else if terminal === locals[index].splitTerminal {
            locals[index].splitTitle = title
            if let directory { locals[index].splitDirectory = directory }
        } else if terminal === locals[index].scratch {
            if let directory { locals[index].scratchDirectory = directory }
        }
        if locals[index].name != before { rebuild() }
    }

    /// localAttention marks a session that rang or notified while it was not in view, and flashes the taskbar button
    /// while the window is in the background.
    func localAttention(_ id: Foundation.UUID) {
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
    func deliver(_ id: Foundation.UUID, title: String, body: String, source: NotificationRules.Source) -> String? {
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

    /// quickProfileCommandLine is what the quick terminal runs: the profile New Session's shortcut starts.
    var quickProfileCommandLine: String? { profiles.indices.contains(defaultProfile) ? profiles[defaultProfile].commandLine : nil }

    private func newServerSession(on server: Server?) {
        guard let server else { return }
        Task { @MainActor in
            let response = await newSession(on: server)
            log("native shell: new session on \(server.label): \(response.ok ? "ok" : response.error ?? "failed")")
            if !response.ok {
                MessageBoxW(window, Array("New session on \(server.label) failed: \(response.error ?? "")".utf16) + [0],
                            Array("agterm".utf16) + [0], UINT(MB_ICONERROR))
            }
        }
    }

    /// newSession asks `server` for a session in its current workspace, which is selected once its catalog shows it.
    private func newSession(on server: Server) async -> ControlResponse {
        guard server.remote.connected, let workspace = server.remote.store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no connection to \(server.label)")
        }
        sessionsBeforeCreate = Set(servers.flatMap { $0.remote.store.workspaces.flatMap(\.sessions) }.map(\.id))
        let response = await server.remote.perform(.newSession(workspace: workspace))
        if !response.ok { sessionsBeforeCreate = nil }
        return response
    }

    /// perform sends `operation` to the server holding session `id`.
    private func perform(_ operation: RemoteOperation, on id: Foundation.UUID) async -> ControlResponse {
        guard let server = server(of: id) else { return ControlResponse(ok: false, error: "no session \(id.uuidString) on a server") }
        let response = await server.remote.perform(operation)
        log("native shell: \(operation) on \(server.label): \(response.ok ? "ok" : response.error ?? "failed")")
        return response
    }

    /// serverConnected is whether session `id` is on a server that is connected now.
    private func serverConnected(_ id: Foundation.UUID) -> Bool { server(of: id)?.remote.connected == true }

    private func closeServerSession(_ id: Foundation.UUID) {
        guard let server = server(of: id), let session = server.remote.session(id) else { return }
        let question = NativeMenu.closeQuestion(session: session.displayName, server: server.label)
        guard session.ended || MessageBoxW(window, Array(question.utf16) + [0], Array("agterm".utf16) + [0],
                                           UINT(MB_OKCANCEL | MB_ICONWARNING | MB_DEFBUTTON2)) == IDOK else { return }
        Task { @MainActor in _ = await perform(.closeSession(id, undoable: true), on: id) }
    }

    /// canRename is whether `id` takes a new name: a local session, or a server session while the server is connected.
    private func canRename(_ id: Foundation.UUID?) -> Bool {
        guard let id else { return false }
        return locals.contains { $0.id == id } || serverConnected(id)
    }

    private func name(of id: Foundation.UUID) -> String? {
        locals.first { $0.id == id }?.name ?? serverSession(id)?.displayName
    }

    private var requestedSidebarRename: Foundation.UUID?

    private func startRename() {
        guard let tree, canRename(selected), let selected, let item = items[selected] else { return }
        requestedSidebarRename = selected
        defer { requestedSidebarRename = nil }
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
            guard let id, id == requestedSidebarRename, let tree, let name = name(of: id) else { return 1 }
            nt_tree_set_edit_text(tree, Array(name.utf16) + [0])
            return 0
        case 2:
            let name = String(decodingCString: text, as: UTF16.self)
            // A click on another row can end editing while TreeView is still handling that click.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let id { rename(id, to: name) }
                focus()
            }
            return 0
        default:
            DispatchQueue.main.async { [weak self] in self?.focus() }
            return 0
        }
    }

    private func rename(_ id: Foundation.UUID, to name: String) {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].customName = SessionNaming.customName(name)
            rebuild()
            return
        }
        Task { @MainActor in _ = await perform(.renameSession(id, name: name), on: id) }
    }

    /// canRestart is whether `id` is a session whose program ended: a local one, or a server one while it is connected.
    private func canRestart(_ id: Foundation.UUID?) -> Bool {
        guard let id else { return false }
        if let local = locals.first(where: { $0.id == id }) { return local.exited }
        return serverConnected(id) && serverSession(id)?.ended == true
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
        Task { @MainActor in _ = await perform(.restart(id, pane: .left, command: nil), on: id) }
    }

    private var canCloseSelected: Bool {
        locals.contains { $0.id == selected } || selected.map(serverConnected) == true
    }

    private func closeSelected() {
        if let selected, serverSession(selected) != nil {
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
        closing.overlay?.frame.destroy()
        closing.pageOverlay?.frame.destroy()
        closing.terminals.forEach { DestroyWindow($0.window) }
        recentSessions.removeAll { $0 == id }
        if dashboard?.members.contains(where: { $0.session == id }) == true { dashboardSessionsChanged() }
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

    var selectedOverlayHidden: Bool? {
        guard let selected else { return nil }
        if let overlay = serverOverlayState(for: selected)?.overlay { return overlay.hidden }
        let session = locals.first { $0.id == selected }
        return session?.pageOverlay?.hidden ?? session?.overlay?.state.hidden
    }

    func windowCommand(_ command: NativeMenu.Command) {
        log("native shell: \(command)")
        if dashboard != nil, ![.dashboard, .quickTerminal, .settings, .quit, .editKeymap, .reloadKeymap, .commandPalette].contains(command) {
            closeDashboard()
        }
        switch command {
        case .newSession:
            if let server = selected.flatMap(server(of:)) {
                newServerSession(on: server)
            } else if profiles.indices.contains(defaultProfile) {
                newSession(profiles[defaultProfile])
            }
        case .newServerSession: newServerSession(on: currentServer)
        case .renameSession: startRename()
        case .restartSession: restartSelected()
        case .closeSession:
            if let since = closeSessionCoalesced, Date().timeIntervalSince(since) < 0.25 { break }
            if dismissOverlayForCloseSession() {
                closeSessionCoalesced = Date()
            } else {
                closeSelected()
            }
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
        case .toggleSplit: splitKey(.leftRight)
        case .toggleHorizontalSplit: splitKey(.topBottom)
        case .closeSplit: if let selected { closeSplit(selected) }
        case .swapPanes: if let selected { swapPanes(selected) }
        case .focusLeftPane, .focusRightPane: focusPaneKey(split: command == .focusRightPane)
        case .toggleScratch: if let selected, canSplit(selected) { setScratch(selected, shown: !(local(selected)?.scratchShown ?? false), command: nil) }
        case .toggleOverlay:
            if let selected, let hidden = selectedOverlayHidden { setOverlayHidden(selected, !hidden) }
        case .quickTerminal: toggleQuick()
        case .dashboard: toggleDashboard()
        default: visibleTerminal.perform(command)
        }
    }

    // MARK: overlays

    /// placeOverlays lays each overlay over its session's area, shown only for the selected session while not hidden.
    /// A shown overlay disables the terminal under it, so a click beside a floating panel never reaches the session.
    func placeOverlays() {
        guard let window else { return }
        var client = RECT()
        GetClientRect(window, &client)
        let top = titleBar.height
        let area = NativeOverlay.Rect(x: sidebarWidth, y: top, width: max(client.right - sidebarWidth, 1), height: max(client.bottom - top, 1))
        var remoteEnabled = true
        for session in locals {
            refreshPageOverlayState(session)
            if let page = session.pageOverlay {
                let shown = session.id == selected && !page.hidden && dashboard == nil
                let floating = (page.sizePercent ?? 100) < 100
                page.frame.place(NativeOverlay.panel(in: area, sizePercent: page.sizePercent), border: floating ? scaled(1) : 0, shown: shown)
                session.terminals.forEach { EnableWindow($0.window, !shown && dashboard == nil) }
                continue
            }
            guard let overlay = session.overlay else {
                session.terminals.forEach { EnableWindow($0.window, dashboard == nil) }
                continue
            }
            let shown = session.id == selected && !overlay.state.hidden && dashboard == nil
            let floating = (overlay.state.sizePercent ?? 100) < 100
            overlay.frame.place(NativeOverlay.panel(in: area, sizePercent: overlay.state.sizePercent), border: floating ? scaled(1) : 0, shown: shown)
            session.terminals.forEach { EnableWindow($0.window, !shown && dashboard == nil) }
        }
        for (sessionID, overlay) in serverOverlays {
            let shown = sessionID == selected && running == sessionID && !overlay.state.hidden
            let floating = (overlay.state.sizePercent ?? 100) < 100
            overlay.frame.place(NativeOverlay.panel(in: area, sizePercent: overlay.state.sizePercent), border: floating ? scaled(1) : 0, shown: shown)
        }
        for (sessionID, page) in serverPageOverlays {
            refreshServerPageOverlayState(sessionID)
            let shown = sessionID == selected && running == sessionID && !page.hidden
            let floating = (page.sizePercent ?? 100) < 100
            page.frame.place(NativeOverlay.panel(in: area, sizePercent: page.sizePercent), border: floating ? scaled(1) : 0, shown: shown)
            if shown { remoteEnabled = false }
        }
        for (sessionID, hud) in serverHuds {
            guard let server = server(of: sessionID), let session = server.remote.session(sessionID) else { continue }
            let shown = sessionID == selected && running == sessionID
            let rect = NativeOverlay.panel(in: area, sizePercent: session.overlaySizePercent)
            let height = min(rect.height, scaled(120))
            let width = min(rect.width, scaled(400))
            let x = rect.x + (rect.width - width) / 2
            let y = rect.y + rect.height - height - scaled(24)
            MoveWindow(hud.panel, x, y, width, height, true)
            ShowWindow(hud.panel, shown ? SW_SHOW : SW_HIDE)
        }
        if let running, let overlay = serverOverlays[running], selected == running, !overlay.state.hidden { remoteEnabled = false }
        EnableWindow(remoteTerminal.window, remoteEnabled)
        // the find bar and the palette stay above an overlay placed after them
        for panel in [findBar, palette?.assumingMemoryBound(to: HWND__.self)] where panel.map({ IsWindowVisible($0) }) == true {
            SetWindowPos(panel, nil, 0, 0, 0, 0, UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE))
        }
    }

    /// hasFocus is whether the keyboard is in session `id`'s terminal or its overlay, which a change to the overlay
    /// then hands to whichever of them is in view.
    func hasFocus(_ id: Foundation.UUID) -> Bool {
        guard let focused = GetFocus() else { return false }
        if let overlay = serverOverlays[id] {
            if [overlay.terminal.window, overlay.frame.window].contains(focused) { return true }
        }
        guard let session = locals.first(where: { $0.id == id }) else { return false }
        return (session.terminals.map(\.window) + [session.overlay?.terminal.window, session.overlay?.frame.window]).contains(focused)
    }

    /// dismissOverlayForCloseSession ends a shown overlay before Close Session touches the session underneath it.
    @discardableResult
    private func dismissOverlayForCloseSession() -> Bool {
        if let focused = GetFocus() {
            for (sessionID, overlay) in serverOverlays where !overlay.state.hidden {
                if focused == overlay.terminal.window || focused == overlay.frame.window {
                    removeServerOverlay(sessionID, frame: overlay.frame, notifyOrigin: true)
                    return true
                }
            }
            for session in locals {
                guard let overlay = session.overlay, !overlay.state.hidden else { continue }
                if focused == overlay.terminal.window || focused == overlay.frame.window {
                    removeOverlay(session.id, frame: overlay.frame)
                    return true
                }
            }
        }
        if let selected, let overlay = serverOverlays[selected], !overlay.state.hidden {
            removeServerOverlay(selected, frame: overlay.frame, notifyOrigin: true)
            return true
        }
        guard let selected,
              let overlay = locals.first(where: { $0.id == selected })?.overlay,
              !overlay.state.hidden
        else { return false }
        removeOverlay(selected, frame: overlay.frame)
        return true
    }

    private func overlayExited(_ id: Foundation.UUID, frame: OverlayFrame, code: Int) {
        guard let index = locals.firstIndex(where: { $0.id == id }), let overlay = locals[index].overlay, overlay.frame === frame else { return }
        locals[index].overlayExitCode = code
        log("native shell: overlay of [\(id)] exited \(code)")
        if !overlay.state.wait { removeOverlay(id, frame: frame) }
    }

    // MARK: replica asks (catalog sessions)

    private func showReplicaAsk(on server: Server, sessionID: Foundation.UUID, ask: PresentationAsk) -> Bool {
        guard ask.pane == nil, ask.style == .terminal, !ask.needsFormSupport else { return false }
        guard ask.buttons.count >= 1, ask.buttons.count <= 8 else { return false }
        let answer: @MainActor (PresentationFrame.Body) -> Void = { [weak server] body in
            server?.remote.answerPresentation(sessionID, body)
        }
        guard server.remote.store.presentReplicaAsk(ask, forSession: sessionID, answer: answer) else { return false }
        if running != sessionID { select(sessionID) }
        presentReplicaAskDialog(on: server, sessionID: sessionID)
        rebuild()
        log("native shell: replica ask on server session [\(sessionID)]: \(ask.id)")
        return true
    }

    private func presentReplicaAskDialog(on server: Server, sessionID: Foundation.UUID) {
        guard let session = server.remote.session(sessionID), let ask = session.askPending else { return }
        let titles = ask.buttons.map { Array($0.label.utf16) + [0] }
        let picked = Int(withWideStrings(titles) {
            nt_ask_choice(UnsafeMutableRawPointer(window), Array("agterm".utf16) + [0], Array(ask.title.utf16) + [0],
                          Array((ask.message ?? "").utf16) + [0], $0, Int32(titles.count))
        })
        if picked >= 0 {
            _ = session.answerAsk(id: ask.id, buttonAt: picked)
        } else {
            _ = session.cancelAsk(id: ask.id)
        }
        SessionPickBook.shared.drain(pickController)
        if let pending = pickController.pending { openPickPalette(pending) }
        rebuild()
    }

    private func dismissReplicaAsk(on server: Server, sessionID: Foundation.UUID, ref: PresentationAskRef) {
        server.remote.store.dismissReplicaAsk(ref, forSession: sessionID)
        rebuild()
    }

    private func dismissReplicaAsk(ifShownFor sessionID: Foundation.UUID) {
        guard let server = server(of: sessionID), let session = server.remote.session(sessionID), session.askReplica else { return }
        session.releaseAsk()
        rebuild()
    }

    // MARK: replica picks (catalog sessions)

    private func showReplicaPick(on server: Server, sessionID: Foundation.UUID, pick: PresentationPick) -> Bool {
        guard pick.fitsFrame, !pick.items.isEmpty else { return false }
        let answer: @MainActor (PresentationFrame.Body) -> Void = { [weak server] body in
            server?.remote.answerPresentation(sessionID, body)
        }
        guard SessionPickBook.shared.openReplica(pick, session: sessionID, window: shellWindowID, controller: pickController,
                                               answer: answer) else { return false }
        if pick.follow == true { select(sessionID) }
        if let pending = pickController.pending, pending.id == pick.id {
            closePalette(refocus: false)
            openPickPalette(pending)
        }
        rebuild()
        log("native shell: replica pick on server session [\(sessionID)]: \(pick.id)")
        return true
    }

    private func dismissReplicaPick(on server: Server, sessionID: Foundation.UUID, ref: PresentationPickRef) {
        SessionPickBook.shared.dismissReplica(ref, session: sessionID)
        if pickController.pending?.id == ref.id {
            pickPalette = nil
            closePalette(refocus: false)
        }
        rebuild()
    }

    private func pickRows(for pick: PendingPick) -> [Palette.Row] {
        pick.items.map {
            Palette.Row(title: $0.label, subtitle: $0.subtitle ?? "", detail: "",
                        target: .pickChoice($0.id))
        }
    }

    private func openPickPalette(_ pick: PendingPick) {
        guard let palette else { return }
        pickPalette = pick
        paletteMode = nil
        paletteRows = pickRows(for: pick)
        let cue = Array((pick.prompt ?? "Pick one").utf16) + [0]
        let (left, top, width) = paletteFrame
        nt_palette_open(palette, cue, left, top, width)
        paletteQueryChanged()
    }

    private func resolvePickChoice(_ itemID: String) {
        guard let pick = pickController.pending else { return }
        guard let index = pick.items.firstIndex(where: { $0.id == itemID }) else { return }
        pickController.resolve(ControlPickResult(result: .picked, id: itemID, label: pick.items[index].label, index: index))
        pickPalette = nil
        closePalette(refocus: true)
        SessionPickBook.shared.drain(pickController)
        if let pending = pickController.pending { openPickPalette(pending) }
        rebuild()
    }

    // MARK: replica HUDs (catalog sessions)

    private func showReplicaHud(on server: Server, sessionID: Foundation.UUID, hud: PresentationHud?) {
        guard let session = server.remote.session(sessionID) else { return }
        if let hud, hud.pane != nil { return }
        guard let hud else {
            clearServerHud(sessionID)
            return
        }
        if hud.remaining == 0 {
            clearServerHud(sessionID)
            return
        }
        if serverOverlays[sessionID] != nil,
           !(session.hudActive && session.remotePresentation?.hudBridged == true) { return }
        let spec = HudSpec(message: hud.spec.message, detail: hud.spec.detail, spinner: hud.spec.spinner,
                             backgroundColor: hud.spec.backgroundColor, textColor: hud.spec.textColor,
                             sizePercent: hud.spec.sizePercent, position: hud.spec.position,
                             hideAfter: hud.remaining ?? hud.spec.hideAfter, markdown: hud.spec.markdown, fontSize: hud.spec.fontSize,
                             sticky: hud.spec.sticky, frame: hud.spec.frame)
        let bridged = session.hudActive && session.remotePresentation?.hudBridged == true
        if bridged {
            server.remote.store.markViewerHud(forSession: sessionID, spec: spec)
        } else if session.overlayActive && !session.hudActive {
            return
        } else {
            server.remote.store.markViewerHud(forSession: sessionID, spec: spec)
        }
        upsertServerHudPanel(sessionID, spec: spec)
        server.remote.store.markHudBridged(forSession: sessionID)
        armServerHudHide(sessionID, seconds: hud.remaining ?? hud.spec.hideAfter)
        if selected != sessionID { select(sessionID) }
        placeOverlays()
        rebuild()
        log("native shell: replica HUD on server session [\(sessionID)]")
    }

    private func upsertServerHudPanel(_ sessionID: Foundation.UUID, spec: HudSpec) {
        let text = [spec.message, spec.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let panel: HWND
        if let existing = serverHuds[sessionID]?.panel {
            panel = existing
        } else {
            let instance = GetModuleHandleW(nil)
            panel = CreateWindowExW(0, Array("STATIC".utf16) + [0], nil,
                                    DWORD(WS_CHILD) | DWORD(SS_LEFT) | DWORD(SS_NOPREFIX), 0, 0, 10, 10, window, nil,
                                    instance, nil) ?? HWND(bitPattern: 0)!
            serverHuds[sessionID] = ServerHud(panel: panel, hideTask: nil)
        }
        SetWindowTextW(panel, Array(text.utf16) + [0])
    }

    private func armServerHudHide(_ sessionID: Foundation.UUID, seconds: Double?) {
        serverHuds[sessionID]?.hideTask?.cancel()
        guard let seconds, seconds > 0, serverHuds[sessionID] != nil else { return }
        serverHuds[sessionID]?.hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.clearServerHud(sessionID)
        }
    }

    private func clearServerHud(_ sessionID: Foundation.UUID) {
        if let server = server(of: sessionID) {
            _ = server.remote.store.closeBridgedHud(forSession: sessionID)
        }
        if let hud = serverHuds.removeValue(forKey: sessionID) {
            hud.hideTask?.cancel()
            if IsWindow(hud.panel) { DestroyWindow(hud.panel) }
        }
        placeOverlays()
        rebuild()
    }

    // MARK: replica overlays (catalog sessions)

    private func showReplicaOverlay(on server: Server, sessionID: Foundation.UUID, overlay: PresentationOverlay) -> Bool {
        guard overlay.pane == nil, overlay.width == nil, overlay.height == nil else { return false }
        guard serverOverlays[sessionID] == nil, serverPageOverlays[sessionID] == nil else { return false }
        let remoteLine: String
        do {
            guard let line = try RemoteSession.runJobCommand(host: "wsl", job: overlay.job, token: overlay.token).last else { return false }
            remoteLine = line
        } catch {
            log("native shell: replica overlay for [\(sessionID)]: \(error)")
            return false
        }
        let command = server.remote.host.commandLine(remoteLine)
        let job = overlay.job
        guard server.remote.store.prepareReplicaOverlay(overlay, forSession: sessionID, closed: { [weak server] closedJob in
            server?.remote.answerPresentation(sessionID, .overlayClosed(PresentationOverlayChange(job: closedJob)))
        }) else { return false }
        server.remote.store.markViewerProgramOverlay(forSession: sessionID, command: command, sizePercent: overlay.sizePercent,
                                                   wait: overlay.wait)
        openServerReplicaOverlay(sessionID, job: job, command: command, wait: overlay.wait, sizePercent: overlay.sizePercent,
                                 background: NativeOverlay.background(overlay.backgroundColor))
        if overlay.follow { select(sessionID) }
        rebuild()
        log("native shell: replica overlay over server session [\(sessionID)]: \(job)")
        return true
    }

    private func openServerReplicaOverlay(_ id: Foundation.UUID, job: String, command: String, wait: Bool, sizePercent: Int?, background: UInt32?) {
        if selected != id { select(id) }
        let focused = hasFocus(id)
        let frame = OverlayFrame(parent: window, points: settings.fontPoints, dpi: dpi)
        let terminal = frame.terminal
        terminal.onWindowCommand = { [unowned self] in windowCommand($0) }
        terminal.onFontSize = { [unowned self] in setFontSize($0) }
        terminal.onExit = { [unowned self, weak frame] code in
            if let frame { serverOverlayExited(id, frame: frame, code: code) }
        }
        if wait {
            terminal.onCloseKey = { [unowned self, weak frame] in
                if let frame { removeServerOverlay(id, frame: frame, notifyOrigin: true) }
            }
        }
        terminal.background = background
        serverOverlays[id] = ServerOverlay(state: NativeOverlay(sizePercent: sizePercent, wait: wait), frame: frame, job: job)
        placeOverlays()
        terminal.start(command)
        if focused { focus() }
    }

    private func serverOverlayExited(_ id: Foundation.UUID, frame: OverlayFrame, code: Int) {
        guard var slot = serverOverlays[id], slot.frame === frame else { return }
        log("native shell: replica overlay of [\(id)] exited \(code)")
        let hasReplica = server(of: id)?.remote.session(id)?.overlayReplica != nil
        if slot.state.wait {
            slot.exitCode = code
            serverOverlays[id] = slot
            server(of: id)?.remote.session(id)?.overlayExitCode = code
        } else {
            removeServerOverlay(id, frame: frame, notifyOrigin: hasReplica == true)
        }
    }

    private func serverOverlayOriginNotify(_ id: Foundation.UUID) -> Bool {
        server(of: id)?.remote.session(id)?.overlayReplica != nil
    }

    private func closeServerReplicaOverlay(_ id: Foundation.UUID, change: PresentationOverlayChange) {
        guard let slot = serverOverlays[id], slot.job == change.job else { return }
        removeServerOverlay(id, frame: slot.frame, notifyOrigin: false)
        rebuild()
    }

    private func resizeServerReplicaOverlay(_ id: Foundation.UUID, change: PresentationOverlayChange) {
        guard var slot = serverOverlays[id], slot.job == change.job else { return }
        slot.state.sizePercent = change.sizePercent
        serverOverlays[id] = slot
        server(of: id)?.remote.session(id)?.overlaySizePercent = change.sizePercent
        placeOverlays()
        rebuild()
    }

    private func clearServerReplicaOverlay(_ id: Foundation.UUID, notifyOrigin: Bool) {
        guard let slot = serverOverlays[id] else { return }
        removeServerOverlay(id, frame: slot.frame, notifyOrigin: notifyOrigin)
        rebuild()
    }

    // MARK: replica pages (catalog sessions)

    private func showReplicaPage(on server: Server, sessionID: Foundation.UUID, page: PresentationPage) -> String? {
        guard page.pane == nil, page.width == nil, page.height == nil else { return PaneOverlayError.paneNotVisible }
        guard serverPageOverlays[sessionID] == nil, serverOverlays[sessionID] == nil else { return "overlay already open" }
        if case .forwarded = page.source { return "no free local port for the page's forward" }
        if let reason = server.remote.store.presentReplicaPage(page, forSession: sessionID) { return reason }
        guard let slot = server.remote.store.replicaPage(page.page, forSession: sessionID),
              slot.page.replicaOf != nil else { return "page not shown" }
        var channel: ReplicaPageServeClient?
        if page.source.usesChannel {
            do {
                channel = try ReplicaPageServeClient.start(host: server.remote.host, token: page.token)
            } catch {
                server.remote.store.closeReplicaPage(page.page, forSession: sessionID)
                return "the origin cannot be reached for this page"
            }
        }
        let frame = PageOverlayFrame(parent: window, dataFolder: stateDirectory.appendingPathComponent("WebView2"))
        var overlay = slot.page
        overlay.loadState = .loading
        serverPageOverlays[sessionID] = ServerPageOverlay(page: overlay, sizePercent: page.sizePercent, hidden: false,
                                                          frame: frame, channel: channel, offer: page.offer)
        loadServerPageContent(on: server, sessionID: sessionID, presentation: page, frame: frame, channel: channel)
        if page.follow { select(sessionID) }
        placeOverlays()
        rebuild()
        log("native shell: replica page over server session [\(sessionID)]: \(page.page)")
        return nil
    }

    private func loadServerPageContent(on server: Server, sessionID: Foundation.UUID, presentation: PresentationPage,
                                       frame: PageOverlayFrame, channel: ReplicaPageServeClient?) {
        guard let slot = serverPageOverlays[sessionID] else { return }
        let pageID = slot.page.id
        Task { @MainActor in
            defer { channel?.close() }
            do {
                switch presentation.source {
                case .url(let text):
                    guard let url = HtmlSource.webURL(text) else {
                        throw PageLoadFailure.invalidURL
                    }
                    frame.load(url: url)
                case .file(let path, _):
                    guard let channel else { throw PageLoadFailure.noChannel }
                    let fetched = try channel.fetch(path: path)
                    guard let html = String(data: fetched.data, encoding: .utf8) else {
                        throw PageLoadFailure.unreadable
                    }
                    frame.load(html: html)
                case .image(let path, _, _):
                    guard let channel else { throw PageLoadFailure.noChannel }
                    let fetched = try channel.fetch(path: path)
                    let file = try Self.writeTempPageData(fetched.data, path: path)
                    frame.load(file: file)
                case .markdown, .text, .document:
                    server.remote.store.failHtmlOverlay(pageID, error: NativeOverlay.pageRefusal)
                    return
                case .forwarded:
                    return
                }
            } catch {
                server.remote.store.failHtmlOverlay(pageID, error: String(describing: error))
            }
        }
    }

    private enum PageLoadFailure: Error {
        case invalidURL, noChannel, unreadable
    }

    private static func writeTempPageData(_ data: Data, path: String) throws -> String {
        let ext = (path as NSString).pathExtension
        let suffix = ext.isEmpty ? ".bin" : ".\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
        try data.write(to: url, options: .atomic)
        return url.path
    }

    private func refreshServerPageOverlayState(_ sessionID: Foundation.UUID) {
        guard var slot = serverPageOverlays[sessionID], let server = server(of: sessionID) else { return }
        var page = slot.page
        page.loadState = slot.frame.loadState()
        if let error = slot.frame.loadError() { page.loadError = error }
        if page.loadState == .loaded, let title = slot.frame.documentTitle() {
            page.current = HtmlPageInfo(page: title, title: title, canGoBack: false, canGoForward: false)
        }
        let prior = slot.page.loadState
        slot.page = page
        serverPageOverlays[sessionID] = slot
        guard page.replicaOf != nil else { return }
        server.remote.store.setHtmlLoadState(page.id, state: page.loadState, error: page.loadError)
        if let current = page.current { server.remote.store.setHtmlPage(page.id, current) }
        if page.loadState != prior || page.current != nil {
            reportReplicaPageState(sessionID: sessionID, local: page.id)
        }
    }

    private func reportReplicaPageState(sessionID: Foundation.UUID, local: Foundation.UUID) {
        guard let server = server(of: sessionID), let slot = serverPageOverlays[sessionID],
              var state = server.remote.store.replicaPageState(local, appliedSeq: slot.appliedSeq) else { return }
        state.offer = slot.offer
        server.remote.answerPresentation(sessionID, .pageState(state))
    }

    private func closeReplicaPage(sessionID: Foundation.UUID, change: PresentationPageChange) {
        if change.reason == PresentationPageChange.channelLost,
           let slot = serverPageOverlays[sessionID], slot.page.replicaOf?.uuidString == change.page {
            serverPageOverlays[sessionID]?.channel?.close()
        }
        server(of: sessionID)?.remote.store.closeReplicaPage(change.page, forSession: sessionID)
        rebuild()
    }

    private func applyReplicaPageCommand(on server: Server, sessionID: Foundation.UUID, command: PresentationPageCommand) {
        guard server.remote.store.replicaPage(command.page, forSession: sessionID) != nil else { return }
        switch command.action {
        case .hide, .show:
            server.remote.store.setReplicaPageHidden(command.page, forSession: sessionID, hidden: command.action == .hide)
            if var slot = serverPageOverlays[sessionID] {
                slot.hidden = server.remote.session(sessionID)?.overlayHidden ?? false
                serverPageOverlays[sessionID] = slot
                placeOverlays()
                rebuild()
            }
        case .resize:
            server.remote.store.resizeReplicaPage(command.page, forSession: sessionID, sizePercent: command.sizePercent,
                                                  points: command.points, merge: command.merge == true)
            if var slot = serverPageOverlays[sessionID] {
                slot.sizePercent = server.remote.session(sessionID)?.overlaySizePercent
                serverPageOverlays[sessionID] = slot
                placeOverlays()
                rebuild()
            }
        default:
            break
        }
        guard var slot = serverPageOverlays[sessionID] else { return }
        slot.appliedSeq = max(slot.appliedSeq, command.seq)
        serverPageOverlays[sessionID] = slot
        reportReplicaPageState(sessionID: sessionID, local: slot.page.id)
    }

    private func replicaPageReleased(local: Foundation.UUID, origin: Foundation.UUID) {
        guard let (sessionID, slot) = serverPageOverlays.first(where: { $0.value.page.id == local }) else { return }
        serverPageOverlays.removeValue(forKey: sessionID)
        slot.channel?.close()
        slot.frame.destroy()
        placeOverlays()
        rebuild()
        server(of: sessionID)?.remote.answerPresentation(sessionID, .pageClosed(PresentationPageChange(
            page: origin.uuidString, offer: slot.offer)))
    }

    private func clearServerPageOverlay(_ id: Foundation.UUID, notifyOrigin _: Bool) {
        if let slot = serverPageOverlays.removeValue(forKey: id) {
            slot.channel?.close()
            slot.frame.destroy()
        }
        if let session = server(of: id)?.remote.session(id) {
            server(of: id)?.remote.store.closeReplicaPages(of: session)
        }
        placeOverlays()
        rebuild()
    }

    private func removeServerOverlay(_ id: Foundation.UUID, frame: OverlayFrame, notifyOrigin: Bool) {
        guard let slot = serverOverlays[id], slot.frame === frame else { return }
        let focused = hasFocus(id)
        serverOverlays.removeValue(forKey: id)
        if let server = server(of: id) {
            server.remote.store.clearReplicaOverlay(forSession: id, notifyClosed: notifyOrigin)
            server.remote.store.clearViewerProgramOverlay(forSession: id, exitCode: slot.exitCode)
        }
        frame.destroy()
        placeOverlays()
        rebuild()
        if focused { focus() }
    }

    /// removeOverlay ends the overlay `frame` holds, if it is still the session's.
    private func removeOverlay(_ id: Foundation.UUID, frame: OverlayFrame) {
        guard let index = locals.firstIndex(where: { $0.id == id }), locals[index].overlay?.frame === frame else { return }
        let focused = hasFocus(id)
        locals[index].overlay = nil
        frame.destroy()
        placeOverlays()
        if focused { focus() }
    }

    // MARK: sidebar

    func scaled(_ value: Int32) -> Int32 { MulDiv(value, Int32(dpi), 96) }

    var terminalsShown: [NativeTerminal] { [remoteTerminal] + locals.flatMap(\.terminals) }

    /// allTerminals adds the overlays', server overlays', and the quick terminal's, which draw and size as the sessions' do.
    private var allTerminals: [NativeTerminal] {
        terminalsShown + locals.compactMap { $0.overlay?.terminal } + serverOverlays.values.map(\.terminal) + [quick?.terminal].compactMap { $0 }
    }

    /// selectedTerminal is the selected session's pane in view, under any overlay.
    private var selectedTerminal: NativeTerminal { locals.first { $0.id == selected }?.onScreen ?? remoteTerminal }

    /// visibleTerminal is what the keyboard and the terminal commands reach: a shown overlay, else the session.
    var visibleTerminal: NativeTerminal {
        if let selected, let overlay = serverOverlays[selected], running == selected, !overlay.state.hidden { return overlay.terminal }
        guard let overlay = locals.first(where: { $0.id == selected })?.overlay, !overlay.state.hidden else { return selectedTerminal }
        return overlay.terminal
    }

    func layout() {
        guard let window else { return }
        var client = RECT()
        GetClientRect(window, &client)
        let width = sidebarWidth, height = client.bottom
        let notices = servers.compactMap { server -> String? in
            if let bootstrap = server.bootstrapNotice, !bootstrap.isEmpty { return bootstrap }
            return server.remote.mirror.state.windowNotice(host: server.label)
        }
        let noticeText = notices.isEmpty ? nil : notices.joined(separator: "\n")
        let top = titleBar.height
        let noticeHeight = scaled(56) * Int32(notices.count)
        ShowWindow(notice, noticeText == nil ? SW_HIDE : SW_SHOW)
        SetWindowTextW(notice, Array((noticeText ?? "").utf16) + [0])
        MoveWindow(notice, 8, top, width - 16, max(noticeHeight - 6, 0), true)
        let treeTop = top + noticeHeight
        MoveWindow(tree?.assumingMemoryBound(to: HWND__.self), 0, treeTop, width, height - treeTop, true)
        placeSessions()
        let findWidth = min(scaled(280), max(client.right - width - scaled(24), scaled(80)))
        MoveWindow(findBar, client.right - findWidth - scaled(16), top + scaled(8), findWidth, scaled(28), true)
        updateTips()
        invalidateTitleBar()
        if paletteMode != nil || pickPalette != nil { placePalette() }
    }

    private func catalogChanged() {
        for server in servers where server.remote.connected {
            server.bootstrapNotice = nil
        }
        rebuild()
        layout()
        let workspaces = servers.flatMap { $0.remote.store.workspaces }
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

    func rebuild() {
        guard let tree else { return }
        let unseen = settings.notifications.unseenCount ? serverUnseen : [:]
        var sidebar = servers.map { SessionSidebar.server(id: $0.group, label: $0.label, workspaces: $0.remote.store.workspaces, unseen: unseen) }
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

    func select(_ id: Foundation.UUID) {
        if dashboard != nil { closeDashboard(refocus: false) }
        selected = id
        recentSessions.removeAll { $0 == id }
        recentSessions.insert(id, at: 0)
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
        placeSessions()
        let owner = locals.contains(where: { $0.id == id }) ? nil : server(of: id)
        for other in servers where other !== owner { other.remote.store.selectedSessionID = nil }
        guard let owner, let session = owner.remote.session(id) else { return }
        let launch = SessionSidebar.launch(for: session, hostLabel: owner.label)
        guard id != running || launch != runningLaunch else { return }
        running = id
        runningLaunch = launch
        owner.remote.store.selectedSessionID = id
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
        allTerminals.forEach { $0.setDPI(dpi) }
        SetWindowPos(window, nil, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top,
                     UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        layout()
    }

    fileprivate func staticColors(_ context: HDC?, _ control: HWND?) -> LRESULT {
        let palette = chromePalette
        if let control, let index = captions.firstIndex(of: control) {
            let lit = dashboard.map { $0.members.indices.contains(index) && $0.members[index] == $0.highlighted } ?? false
            SetTextColor(context, ChromePalette.colorref(palette.chromeText))
            SetBkColor(context, ChromePalette.colorref(lit ? palette.palSel : palette.clientBg))
            return LRESULT(Int(bitPattern: lit ? highlightBrush : darkBrush))
        }
        SetTextColor(context, 0x5AB4E5)
        SetBkColor(context, ChromePalette.colorref(palette.clientBg))
        return LRESULT(Int(bitPattern: darkBrush))
    }

    /// focus gives the keyboard to what is in view: the dashboard's grid takes it in the window itself.
    func focus() { SetFocus(dashboard != nil ? window : visibleTerminal.window) }

    private var menuShortcuts: NativeMenu.Shortcuts { Keys.keymap.shortcuts }

    /// menuBarEntries is one title-bar menu tab's popup, in the order MenuBarLayout lays them out.
    private func menuBarEntries(tab: Int) -> [NativeMenu.Entry] {
        let shortcuts = menuShortcuts
        switch tab {
        case 0:
            return NativeMenu.file(profiles: profiles, defaultProfile: defaultProfile, servers: serverEntries, canCloseSession: canCloseSelected,
                                   sessionCount: tagged.count, canRenameSession: canRename(selected),
                                   canRestartSession: canRestart(selected), hasSelection: visibleTerminal.hasSelection,
                                   canPaste: IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)), shortcuts: shortcuts)
        case 1: return NativeMenu.view(viewState, shortcuts: shortcuts)
        case 2: return NativeMenu.navigate(shortcuts: shortcuts)
        case 3: return NativeMenu.help(shortcuts: shortcuts)
        default: return []
        }
    }

    /// openMenuTab shows a title-bar menu tab under the label the user clicked.
    private func openMenuTab(_ index: Int) {
        let bar = titleBar
        let gap = bar.actionWidth / 4
        let limit = bar.span(of: .quick).left - gap
        let start = bar.span(of: .newSession).right + gap
        guard let span = MenuBarLayout.menuSpans(origin: start, limit: limit, dpi: dpi).first(where: { $0.index == index })?.span else { return }
        var corner = POINT(x: span.left, y: bar.height)
        ClientToScreen(window, &corner)
        run(showMenu(menuBarEntries(tab: index), owner: window, at: corner))
    }

    /// windowEntries is the ☰ menu as it stands now, which the command palette lists too.
    private var windowEntries: [NativeMenu.Entry] {
        NativeMenu.window(profiles: profiles, defaultProfile: defaultProfile, servers: serverEntries,
                          canCloseSession: canCloseSelected, sessionCount: tagged.count, canRenameSession: canRename(selected),
                          canRestartSession: canRestart(selected), hasSelection: visibleTerminal.hasSelection,
                          canPaste: IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)), view: viewState, shortcuts: Keys.keymap.shortcuts)
    }

    /// treeMenu is the sidebar's menu, for the session under the right click, which it selects first.
    fileprivate func treeMenu(x: Int32, y: Int32) {
        guard let tree else { return }
        var point = POINT(x: x, y: y)
        let tag = nt_tree_item_at(tree, &point.x, &point.y)
        if tag > 0, Int(tag) <= tagged.count { select(tagged[Int(tag) - 1]) }
        if x != -1 || y != -1 { point = POINT(x: x, y: y) }
        run(showMenu(NativeMenu.sessions(profiles: profiles, defaultProfile: defaultProfile, servers: serverEntries,
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
        case .startServer(let index)? where menuServers.indices.contains(index): startServer(menuServers[index])
        case .serverSession(let index)? where menuServers.indices.contains(index): newServerSession(on: server(menuServers[index]))
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
            return Palette.sessionRows(locals: localRows, servers: servers.map { (label: $0.label, workspaces: $0.remote.store.workspaces) },
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
        guard let palette, paletteMode != nil || pickPalette != nil else { return }
        if pickPalette == nil, let mode = paletteMode { paletteRows = rows(for: mode) }
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
        guard paletteShown.indices.contains(index) else { return }
        let row = paletteShown[index]
        if pickPalette != nil {
            guard case .pickChoice(let id) = row.target else { return }
            resolvePickChoice(id)
            return
        }
        guard let mode = paletteMode else { return }
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
        case .pickChoice:
            break
        }
    }

    fileprivate func closePalette(refocus: Bool) {
        guard paletteMode != nil || pickPalette != nil else { return }
        if let pick = pickPalette, pickController.pending?.id == pick.id {
            pickController.cancel()
            SessionPickBook.shared.drain(pickController)
        }
        pickPalette = nil
        paletteMode = nil
        paletteRows = []
        paletteShown = []
        if let palette { nt_palette_close(palette) }
        if refocus { focus() }
    }

    // MARK: title bar

    var titleBar: TitleBar { titleBar(of: window) }

    /// titleBar(of:) reads the window it is given: the frame messages arrive while CreateWindowExW has not returned.
    private func titleBar(of window: HWND?) -> TitleBar {
        var client = RECT()
        GetClientRect(window, &client)
        return TitleBar(width: client.right, sidebarWidth: sidebarWidth, dpi: dpi)
    }

    func invalidateTitleBar() {
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
        let icon = bar.appIcon
        let systemMenuTip = Array("System menu".utf16) + [0]
        systemMenuTip.withUnsafeBufferPointer { tip in
            nt_tooltip_set(tooltip, UnsafeMutableRawPointer(window), 100, icon.left, 0, icon.right, bar.height, tip.baseAddress)
        }
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
        case .appIcon, .menuTab: return hitClient
        case .outside: return hitClient
        }
    }

    /// clientButton is the action button under a client point; caption buttons are the frame's, never the client's.
    private func clientButton(_ lParam: LPARAM) -> TitleBar.Button? {
        let x = Int32(Int16(truncatingIfNeeded: lParam)), y = Int32(Int16(truncatingIfNeeded: lParam >> 16))
        guard case .button(let button) = titleBar.hit(x: x, y: y, topBorder: 0), !button.isCaption, enabled(button) else { return nil }
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

    private func titlePoint(_ lParam: LPARAM) -> (x: Int32, y: Int32) {
        (Int32(Int16(truncatingIfNeeded: lParam)), Int32(Int16(truncatingIfNeeded: lParam >> 16)))
    }

    private func menuTab(at x: Int32, y: Int32) -> Int? {
        let bar = titleBar
        guard y >= 0, y < bar.height else { return nil }
        let gap = bar.actionWidth / 4
        let limit = bar.span(of: .quick).left - gap
        return bar.menuTab(x: x, y: y, dpi: dpi, limit: limit)
    }

    private func refreshMenuBarHighlight(x: Int32, y: Int32) {
        let tab = menuTab(at: x, y: y)
        guard tab != menuBarHighlight else { return }
        menuBarHighlight = tab
        invalidateTitleBar()
    }

    private func refreshAppIconHighlight(x: Int32, y: Int32) {
        let lit = titleBar.hit(x: x, y: y, topBorder: 0) == .appIcon || pressedAppIcon
        guard lit != appIconHighlight else { return }
        appIconHighlight = lit
        invalidateTitleBar()
    }

    private func systemMenu(atClient x: Int32, y: Int32) {
        var point = POINT(x: x, y: y)
        ClientToScreen(window, &point)
        let lParam = LPARAM(Int(UInt16(truncatingIfNeeded: point.y)) << 16 | Int(UInt16(truncatingIfNeeded: point.x)))
        systemMenu(lParam)
    }

    fileprivate func mouseMoved(_ lParam: LPARAM) {
        if dragDivider(lParam) { return }
        let (x, y) = titlePoint(lParam)
        refreshMenuBarHighlight(x: x, y: y)
        refreshAppIconHighlight(x: x, y: y)
        hover(clientButton(lParam), frame: false)
    }

    fileprivate func mouseDown(_ lParam: LPARAM, double: Bool = false) {
        if bodyMouseDown(lParam, double: double) { return }
        let (x, y) = titlePoint(lParam)
        if y < titleBar.height, titleBar.hit(x: x, y: y, topBorder: 0) == .appIcon {
            pressedAppIcon = true
            appIconHighlight = true
            SetCapture(window)
            invalidateTitleBar()
            return
        }
        if y < titleBar.height, let tab = menuTab(at: x, y: y) {
            pressedMenuTab = tab
            menuBarHighlight = tab
            SetCapture(window)
            invalidateTitleBar()
            return
        }
        guard let button = clientButton(lParam) else { return }
        pressed = button
        SetCapture(window)
        invalidateTitleBar()
    }

    fileprivate func mouseUp(_ lParam: LPARAM) {
        if endDividerDrag() { return }
        if pressedAppIcon {
            pressedAppIcon = false
            ReleaseCapture()
            let (x, y) = titlePoint(lParam)
            if titleBar.hit(x: x, y: y, topBorder: 0) == .appIcon { systemMenu(atClient: x, y: y) }
            appIconHighlight = titleBar.hit(x: x, y: y, topBorder: 0) == .appIcon
            invalidateTitleBar()
            return
        }
        if let tab = pressedMenuTab {
            pressedMenuTab = nil
            ReleaseCapture()
            let (x, y) = titlePoint(lParam)
            if menuTab(at: x, y: y) == tab { openMenuTab(tab) }
            invalidateTitleBar()
            return
        }
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
        case .minimize: ShowWindow(window, SW_MINIMIZE)
        case .maximize: ShowWindow(window, IsZoomed(window) ? SW_RESTORE : SW_MAXIMIZE)
        case .close: PostMessageW(window, UINT(WM_CLOSE), 0, 0)
        case .newSession:
            windowCommand(.newSession)
            focus()
        case .find: windowCommand(.find)
        case .quick, .split, .dashboard, .settings:
            if enabled(button), let command = button.command { windowCommand(command) }
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

    fileprivate func onAppIcon(_ lParam: LPARAM) -> Bool {
        var point = POINT(x: Int32(Int16(truncatingIfNeeded: lParam)), y: Int32(Int16(truncatingIfNeeded: lParam >> 16)))
        ScreenToClient(window, &point)
        return titleBar.hit(x: point.x, y: point.y, topBorder: 0) == .appIcon
    }

    fileprivate func paint() {
        let bar = titleBar
        let maximized = IsZoomed(window)
        let buttons = TitleBar.Button.allCases.map { button in
            let span = bar.span(of: button)
            let lit = hovered == button && (pressed == nil || pressed == button)
            let state: Int32 = !enabled(button) ? 3 : lit ? (pressed == button ? 2 : 1) : 0
            return nt_title_button(left: span.left, right: span.right, glyph: button.glyph(maximized: maximized),
                                   kind: button == .close ? 2 : button.isCaption ? 1 : 0, state: state)
        }
        let gap = bar.actionWidth / 4
        let limit = bar.span(of: .quick).left - gap
        let start = bar.span(of: .newSession).right + gap
        let spans = MenuBarLayout.menuSpans(origin: start, limit: limit, dpi: dpi)
        var labels = spans.map { Array(MenuBarLayout.titles[$0.index].utf16) + [0] }
        var tabs = spans.enumerated().map { offset, entry in
            nt_menu_tab(left: entry.span.left, right: entry.span.right, label: nil,
                        lit: menuBarHighlight == entry.index || pressedMenuTab == entry.index ? 1 : 0)
        }
        let tabCount = Int32(spans.count)
        withMenuTabLabels(&labels, tabs: &tabs) { tabPtr in
            buttons.withUnsafeBufferPointer { buttons in
                let title = Array(shownTitle.utf16) + [0]
                title.withUnsafeBufferPointer { title in
                    let iconLit = appIconHighlight || pressedAppIcon
                    nt_title_bar_paint(UnsafeMutableRawPointer(window), dpi, bar.height, bar.appIcon.right, iconLit ? 1 : 0,
                                       title.baseAddress, bar.title.left, bar.title.right, buttons.baseAddress,
                                       Int32(buttons.count), windowActive ? 1 : 0, tabPtr, tabCount)
                }
            }
        }
    }

    /// withMenuTabLabels lends label pointers into `labels` for the paint call only.
    private func withMenuTabLabels(_ labels: inout [[UInt16]], tabs: inout [nt_menu_tab], _ body: (UnsafePointer<nt_menu_tab>?) -> Void) {
        func lend(_ index: Int) {
            guard index < labels.count else { return tabs.withUnsafeBufferPointer { body($0.baseAddress) } }
            labels[index].withUnsafeBufferPointer { label in
                tabs[index].label = label.baseAddress
                lend(index + 1)
            }
        }
        lend(0)
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
        case .newSession: 0xE710
        case .find: 0xE721
        case .quick: 0xE756
        case .split: 0xE8A0
        case .dashboard: 0xE8A9
        case .settings: 0xE713
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
        case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN):
            if shell.dashboardKey(Int32(truncatingIfNeeded: wParam)) { return 0 }
            return DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_SETCURSOR):
            if lParam & 0xFFFF == LPARAM(HTCLIENT), shell.dividerCursor() { return 1 }
            return DefWindowProcW(window, message, wParam, lParam)
        case UINT(WM_LBUTTONDBLCLK):
            shell.mouseDown(lParam, double: true)
            return 0
        case UINT(WM_HOTKEY):
            if wParam == WPARAM(NativeShell.quickHotkey) { shell.toggleQuick() }
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
        case UINT(NT_PAGE_STATE):
            shell.placeOverlays()
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
        case UINT(WM_CONTEXTMENU) where !NativeShell.fromKeyboard(lParam) && shell.onAppIcon(lParam):
            shell.systemMenu(lParam)
            return 0
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
            return shell.staticColors(HDC(bitPattern: UInt(wParam)), HWND(bitPattern: Int(lParam)))
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
            UnregisterHotKey(window, NativeShell.quickHotkey)
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
            var local = NativeControl.Local(id: $0.id, name: $0.name, commandLine: $0.commandLine, exited: $0.exited, attention: $0.attention,
                                            unseen: $0.unseen, cwd: $0.directory ?? "", title: $0.programTitle, overlay: $0.overlay?.state,
                                            overlayExitCode: $0.overlayExitCode, htmlOverlay: $0.pageOverlay?.page)
            local.pageOverlayHidden = $0.pageOverlay?.hidden ?? false
            local.pageOverlaySizePercent = $0.pageOverlay?.sizePercent
            local.split = $0.splitTerminal == nil ? nil : $0.split
            local.splitCwd = $0.splitDirectory
            local.scratch = $0.scratchShown && $0.scratch != nil
            local.scratchRunning = $0.scratch != nil
            local.scratchCwd = $0.scratchDirectory
            return local
        }
    }

    var selectedSession: Foundation.UUID? { selected }

    var serverWorkspaces: [ControlWorkspaceNode] {
        servers.filter { $0.remote.connected }.flatMap { $0.remote.store.controlTree(paneForeground: { _ in nil }).workspaces }
    }

    func isServerSession(_ id: Foundation.UUID) -> Bool { serverSession(id) != nil }

    func isConnectedServerSession(_ id: Foundation.UUID) -> Bool { serverConnected(id) }

    func serverPageOverlay(for id: Foundation.UUID) -> (page: HtmlOverlay, hidden: Bool)? {
        guard let slot = serverPageOverlays[id] else { return nil }
        return (slot.page, slot.hidden)
    }

    func serverOverlayState(for id: Foundation.UUID) -> (overlay: NativeOverlay?, exitCode: Int?)? {
        guard serverSession(id) != nil else { return nil }
        if let page = serverPageOverlays[id] {
            var overlay = NativeOverlay(sizePercent: page.sizePercent, wait: false)
            overlay.hidden = page.hidden
            return (overlay, nil)
        }
        if let slot = serverOverlays[id] { return (slot.state, slot.exitCode) }
        guard let session = server(of: id)?.remote.session(id), session.overlayActive else { return (nil, nil) }
        var overlay = NativeOverlay(sizePercent: session.overlaySizePercent, wait: session.overlayWait)
        overlay.hidden = session.overlayHidden
        return (overlay, session.overlayExitCode)
    }

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
        guard let server = currentServer else { return ControlResponse(ok: false, error: "no agterm-server is started") }
        return await newSession(on: server)
    }

    func closeSession(_ id: Foundation.UUID) async -> ControlResponse {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            if let overlay = locals[index].overlay, !overlay.state.hidden {
                removeOverlay(id, frame: overlay.frame)
            } else {
                closeLocal(id)
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        return await perform(.closeSession(id, undoable: true), on: id)
    }

    func renameSession(_ id: Foundation.UUID, to name: String) async -> ControlResponse {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].customName = SessionNaming.customName(name)
            rebuild()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        return await perform(.renameSession(id, name: name), on: id)
    }

    /// restartSession runs a local session's program again, ended or not, as `session.restart` replaces a live pane's.
    func restartSession(_ id: Foundation.UUID) async -> ControlResponse {
        if let index = locals.firstIndex(where: { $0.id == id }) {
            locals[index].exited = false
            launch(locals[index])
            rebuild()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
        return await perform(.restart(id, pane: .left, command: nil), on: id)
    }

    func selectSession(_ id: Foundation.UUID) { select(id) }

    /// terminal is the terminal showing `id`: its own for a local session, the shared one while it shows a server one.
    private func terminal(of id: Foundation.UUID, pane: NativePane?) -> NativeTerminal? {
        if let session = locals.first(where: { $0.id == id }) { return pane.map { session.pane($0) } ?? session.onScreen }
        guard pane == nil || pane == .primary else { return nil }
        return running == id ? remoteTerminal : nil
    }

    func type(_ text: String, into id: Foundation.UUID, pane: NativePane?) -> Bool { terminal(of: id, pane: pane)?.type(text) ?? false }

    func screen(of id: Foundation.UUID, pane: NativePane?) -> (lines: [String], rows: Int)? { terminal(of: id, pane: pane)?.screen }

    func setQuick(shown: Bool) {
        if shown { showQuick(pinned: true) } else { quick?.hide() }
    }

    func typeQuick(_ text: String) -> Bool { quick?.terminal?.type(text) ?? false }

    var quickScreen: (lines: [String], rows: Int)? { quick?.terminal?.screen }

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

    var wslServers: [ControlWSLServer] {
        ServerLaunch.listed(available: menuServers, choices: settings.serverLaunch).map { distribution in
            let started = server(distribution)
            return ControlWSLServer(distribution: distribution, started: started != nil, connected: started?.remote.connected == true,
                                    launch: settings.serverLaunch[distribution]?.rawValue)
        }
    }

    func startWSLServer(_ distribution: String) -> String? {
        guard !asking.contains(distribution) else { return "agterm-server in \(Self.label(of: distribution)) is asking whether it starts at launch" }
        if let existing = server(distribution) {
            if !existing.remote.connected { prepareAndConnect(existing, forceInstall: false) }
            return nil
        }
        startServer(distribution, asking: false)
        return nil
    }

    func setWSLLaunch(_ distribution: String, atLaunch: Bool) {
        settings.serverLaunch[distribution] = atLaunch ? .atLaunch : .manual
        saveSettings()
    }

    func openOverlay(_ id: Foundation.UUID, _ open: NativeOverlay.Open) {
        if serverSession(id) != nil {
            openServerCtlOverlay(id, open)
            return
        }
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        guard locals[index].pageOverlay == nil else { return }
        if selected != id { select(id) }
        let focused = hasFocus(id)
        let frame = OverlayFrame(parent: window, points: settings.fontPoints, dpi: dpi)
        let terminal = frame.terminal
        terminal.onWindowCommand = { [unowned self] in windowCommand($0) }
        terminal.onFontSize = { [unowned self] in setFontSize($0) }
        // weak: the frame owns the terminal that holds these
        terminal.onExit = { [unowned self, weak frame] code in
            if let frame { overlayExited(id, frame: frame, code: code) }
        }
        if open.wait {
            terminal.onCloseKey = { [unowned self, weak frame] in
                if let frame { removeOverlay(id, frame: frame) }
            }
        }
        terminal.background = open.background
        locals[index].overlay = Overlay(state: NativeOverlay(sizePercent: open.sizePercent, wait: open.wait), frame: frame)
        locals[index].overlayExitCode = nil
        // placed first, so the program starts at the panel's grid
        placeOverlays()
        let session = locals[index]
        let launch = NativeOverlay.launch(open.command, sessionCommandLine: session.commandLine, cwd: open.cwd, directory: session.directory)
        log("native shell: overlay over \(session.name) [\(id)]: \(launch.commandLine)")
        terminal.start(launch.commandLine, directory: launch.directory.flatMap { Self.isFolder($0) ? $0 : nil } ?? Self.home,
                       environment: sessionEnvironment(id))
        if focused { focus() }
    }

    private func refreshPageOverlayState(at index: Int) {
        guard var slot = locals[index].pageOverlay else { return }
        var page = slot.page
        let state = slot.frame.loadState()
        page.loadState = state
        if let error = slot.frame.loadError() { page.loadError = error }
        if state == .loaded, let title = slot.frame.documentTitle() {
            page.current = HtmlPageInfo(page: title, title: title, canGoBack: false, canGoForward: false)
        }
        slot.page = page
        locals[index].pageOverlay = slot
    }

    private func refreshPageOverlayState(_ session: LocalSession) {
        guard let index = locals.firstIndex(where: { $0.id == session.id }) else { return }
        refreshPageOverlayState(at: index)
    }

    func openPageOverlay(_ id: Foundation.UUID, _ overlay: HtmlOverlay, sizePercent: Int?) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        guard locals[index].overlay == nil else { return }
        if selected != id { select(id) }
        let frame = PageOverlayFrame(parent: window, dataFolder: stateDirectory.appendingPathComponent("WebView2"))
        var page = overlay
        page.loadState = .loading
        switch page.source {
        case .file(let path, _): frame.load(file: path)
        case .url(let address): frame.load(url: address)
        case .image(let path): frame.load(file: path)
        default: break
        }
        locals[index].pageOverlay = (page: page, sizePercent: sizePercent, hidden: false, frame: frame)
        placeOverlays()
        rebuild()
        log("native shell: page overlay over \(locals[index].name) [\(id)]")
    }

    private func removePageOverlay(_ id: Foundation.UUID, frame: PageOverlayFrame) {
        guard let index = locals.firstIndex(where: { $0.id == id }), locals[index].pageOverlay?.frame === frame else { return }
        let focused = hasFocus(id)
        locals[index].pageOverlay = nil
        frame.destroy()
        placeOverlays()
        rebuild()
        if focused { focus() }
    }

    private func openServerCtlOverlay(_ id: Foundation.UUID, _ open: NativeOverlay.Open) {
        guard serverConnected(id), serverOverlays[id] == nil, serverPageOverlays[id] == nil,
              let server = server(of: id), let session = server.remote.session(id) else { return }
        let launch = SessionSidebar.launch(for: session, hostLabel: server.label)
        guard case .command(let sessionCommand) = launch else { return }
        let started = NativeOverlay.launch(open.command, sessionCommandLine: sessionCommand, cwd: open.cwd, directory: session.effectiveCwd)
        server.remote.store.markViewerProgramOverlay(forSession: id, command: open.command, sizePercent: open.sizePercent, wait: open.wait)
        openServerReplicaOverlay(id, job: "ctl", command: started.commandLine, wait: open.wait, sizePercent: open.sizePercent, background: open.background)
        rebuild()
        log("native shell: ctl overlay over server session [\(id)]: \(started.commandLine)")
    }

    func closeOverlay(_ id: Foundation.UUID) {
        if let slot = serverOverlays[id] {
            removeServerOverlay(id, frame: slot.frame, notifyOrigin: serverOverlayOriginNotify(id))
            return
        }
        if let origin = serverPageOverlays[id]?.page.replicaOf?.uuidString {
            server(of: id)?.remote.store.closeReplicaPage(origin, forSession: id)
            return
        }
        if let page = locals.first(where: { $0.id == id })?.pageOverlay {
            removePageOverlay(id, frame: page.frame)
            return
        }
        guard let frame = locals.first(where: { $0.id == id })?.overlay?.frame else { return }
        removeOverlay(id, frame: frame)
    }

    func resizeOverlay(_ id: Foundation.UUID, sizePercent: Int?) {
        if var slot = serverOverlays[id] {
            slot.state.sizePercent = sizePercent
            serverOverlays[id] = slot
            server(of: id)?.remote.session(id)?.overlaySizePercent = sizePercent
            placeOverlays()
            rebuild()
            return
        }
        if var slot = serverPageOverlays[id] {
            slot.sizePercent = sizePercent
            serverPageOverlays[id] = slot
            if let origin = slot.page.replicaOf?.uuidString {
                server(of: id)?.remote.store.resizeReplicaPage(origin, forSession: id, sizePercent: sizePercent)
            }
            placeOverlays()
            rebuild()
            return
        }
        if let index = locals.firstIndex(where: { $0.id == id }), locals[index].pageOverlay != nil {
            locals[index].pageOverlay?.sizePercent = sizePercent
            placeOverlays()
            rebuild()
            return
        }
        guard let index = locals.firstIndex(where: { $0.id == id }), locals[index].overlay != nil else { return }
        locals[index].overlay?.state.sizePercent = sizePercent
        placeOverlays()
    }

    func setOverlayHidden(_ id: Foundation.UUID, _ hidden: Bool) {
        if var slot = serverOverlays[id] {
            let focused = hasFocus(id)
            slot.state.hidden = hidden
            serverOverlays[id] = slot
            server(of: id)?.remote.session(id)?.overlayHidden = hidden
            placeOverlays()
            if focused { focus() }
            rebuild()
            return
        }
        if var slot = serverPageOverlays[id] {
            let focused = hasFocus(id)
            if let origin = slot.page.replicaOf?.uuidString {
                server(of: id)?.remote.store.setReplicaPageHidden(origin, forSession: id, hidden: hidden)
            }
            slot.hidden = hidden
            serverPageOverlays[id] = slot
            placeOverlays()
            rebuild()
            if focused { focus() }
            return
        }
        if let index = locals.firstIndex(where: { $0.id == id }), locals[index].pageOverlay != nil {
            let focused = hasFocus(id)
            locals[index].pageOverlay?.hidden = hidden
            placeOverlays()
            rebuild()
            if focused { focus() }
            return
        }
        guard let index = locals.firstIndex(where: { $0.id == id }), locals[index].overlay != nil else { return }
        let focused = hasFocus(id)
        locals[index].overlay?.state.hidden = hidden
        placeOverlays()
        if focused { focus() }
    }

    func overlayScreen(of id: Foundation.UUID) -> (lines: [String], rows: Int)? {
        serverOverlays[id]?.terminal.screen ?? locals.first { $0.id == id }?.overlay?.terminal.screen
    }

    func overlaySelection(of id: Foundation.UUID) -> String? {
        serverOverlays[id]?.terminal.selection ?? locals.first { $0.id == id }?.overlay?.terminal.selection
    }
}

/// withWideStrings lends `strings`, each NUL-terminated, to `body` as one array of pointers, valid for the call only.
private func withWideStrings<Result>(_ strings: [[UInt16]], _ body: (UnsafePointer<UnsafePointer<UInt16>?>) -> Result) -> Result {
    var pointers: [UnsafePointer<UInt16>?] = []
    func lend(_ index: Int) -> Result {
        guard index < strings.count else { return pointers.withUnsafeBufferPointer { body($0.baseAddress!) } }
        return strings[index].withUnsafeBufferPointer { buffer in
            pointers.append(buffer.baseAddress)
            return lend(index + 1)
        }
    }
    return lend(0)
}
