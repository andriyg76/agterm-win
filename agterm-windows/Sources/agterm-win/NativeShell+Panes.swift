import AgtermWinKit
import Foundation
import NativeShim
import WinSDK
import agtermCore

/// A local session's split and scratch, the dashboard and the quick terminal, as agterm on a Mac has them.
extension NativeShell {
    typealias Rect = NativeOverlay.Rect

    static let quickHotkey: Int32 = 1

    func local(_ id: Foundation.UUID?) -> LocalSession? { locals.first { $0.id == id } }

    /// canSplit is whether `id` takes a split and a scratch: a local session; a server session's panes are not shown here.
    func canSplit(_ id: Foundation.UUID) -> Bool { locals.contains { $0.id == id } }

    /// sessionArea is the terminal area beside the sidebar and between the title bar and the notice bar, which a
    /// session's panes share.
    var sessionArea: Rect {
        let content = contentSpan
        return Rect(x: sidebarWidth, y: content.top, width: max(clientRect.right - sidebarWidth, 1), height: content.bottom - content.top)
    }

    var dividerThickness: Int32 { scaled(4) }

    var viewState: NativeMenu.View {
        let session = local(selected)
        return NativeMenu.View(canSplit: session != nil && dashboard == nil, hasSplit: session?.splitTerminal != nil,
                               scratchShown: session?.scratchShown == true, quickShown: quickShown, canDashboard: !locals.isEmpty,
                               dashboardOpen: dashboard != nil, canToggleOverlay: selectedOverlayHidden != nil,
                               overlayShown: selectedOverlayHidden == false)
    }

    /// enabled is whether a title bar button can act now; one that cannot stays in place, drawn dimmed.
    func enabled(_ button: TitleBar.Button) -> Bool {
        switch button {
        case .split, .scratch: viewState.canSplit
        case .overlays: viewState.canToggleOverlay
        case .dashboard: dashboard != nil || !locals.isEmpty
        default: true
        }
    }

    func buttonIsActive(_ button: TitleBar.Button) -> Bool {
        switch button {
        case .scratch: viewState.scratchShown
        case .split: local(selected)?.split?.shown == true
        case .overlays: selectedOverlayHidden == true
        case .dashboard: viewState.dashboardOpen
        case .quick: viewState.quickShown
        default: false
        }
    }

    /// wirePane hands a pane's program events to its session; they find the pane by its terminal, which a swap moves.
    func wirePane(_ terminal: NativeTerminal, of id: Foundation.UUID) {
        terminal.onExit = { [unowned self, weak terminal] _ in if let terminal { paneExited(id, terminal) } }
        terminal.onAttention = { [unowned self] in localAttention(id) }
        terminal.onNotification = { [unowned self] in deliver(id, title: $0, body: $1, source: .terminal) }
        terminal.onNaming = { [unowned self, weak terminal] in if let terminal { localNaming(id, terminal) } }
        terminal.onFocus = { [unowned self, weak terminal] in if let terminal { paneFocused(id, terminal) } }
        terminal.onKeystroke = { [unowned self, weak terminal] in if let terminal { paneTyped(id, terminal, $0) } }
    }

    /// paneTyped clears an agent's status by the keystroke, in the pane the terminal is now: Settings has no status
    /// reset choice yet, so it is a Mac's default, the first key.
    private func paneTyped(_ id: Foundation.UUID, _ terminal: NativeTerminal, _ keystroke: StatusKeystroke) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let session = locals[index]
        let pane: StatusPane = terminal === session.scratch ? .scratch : terminal === session.splitTerminal ? .right : .left
        let before = session.activity
        locals[index].activity.clear(by: keystroke, pane: pane, reset: .firstKey)
        if locals[index].activity.indicator != before.indicator { rebuild() }
    }

    // MARK: placement

    /// placeSessions shows the selected session's panes, its scratch over them, or the dashboard's grid, and hides the
    /// rest; overlays then go over them.
    func placeSessions() {
        guard window != nil else { return }
        let area = sessionArea
        if let dashboard {
            placeDashboard(dashboard, in: area)
        } else {
            let localInView = local(selected) != nil
            for terminal in remoteTerminals {
                terminal.move(x: area.x, y: area.y, width: area.width, height: area.height)
                show(terminal, terminal === remoteTerminal && !localInView)
            }
            for session in locals {
                let inView = session.id == selected
                let covered = session.scratchShown && session.scratch != nil
                let layout = PaneLayout(area: area, split: session.splitTerminal == nil ? nil : session.split, divider: dividerThickness)
                place(session.terminal, layout.primary, shown: inView && !covered)
                if let split = session.splitTerminal { place(split, layout.split, shown: inView && !covered) }
                if let scratch = session.scratch { place(scratch, area, shown: inView && covered) }
            }
        }
        placeOverlays()
        invalidateTitleBar()
    }

    private func place(_ terminal: NativeTerminal, _ rect: Rect?, shown: Bool) {
        if let rect { terminal.move(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
        show(terminal, shown && rect != nil)
    }

    private func show(_ terminal: NativeTerminal, _ shown: Bool) {
        if IsWindowVisible(terminal.window) != shown { terminal.setVisible(shown) }
    }

    // MARK: split

    /// splitKey is a split key or button: over a shown scratch it hides the scratch, else it toggles the split on `axis`.
    func splitKey(_ axis: SplitAxis?) {
        guard let selected, let session = local(selected) else { return }
        if session.scratchShown {
            setScratch(selected, shown: false, command: nil)
            return
        }
        if let next = NativeSplit.next(session.splitTerminal == nil ? nil : session.split, mode: .toggle, axis: axis ?? session.split?.axis ?? .leftRight) { setSplit(selected, next) }
    }

    func focusPaneKey(split: Bool) {
        guard let selected, var layout = local(selected)?.split, local(selected)?.splitTerminal != nil else { return }
        layout.focused = split
        setSplit(selected, layout)
    }

    /// setSplit gives the session `split`, starting its second shell in the primary pane's folder when it has none.
    func setSplit(_ id: Foundation.UUID, _ split: NativeSplit) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let hadFocus = hasFocus(id)
        if locals[index].splitTerminal == nil {
            addSplit(index, split, directory: locals[index].directory)
        } else {
            locals[index].split = split
            placeSessions()
        }
        rebuild()
        if hadFocus || id == selected && GetFocus() != nil { focus() }
    }

    func restoreSplit(_ id: Foundation.UUID, _ split: NativeSplit, directory: String?) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        addSplit(index, split, directory: directory ?? locals[index].directory)
    }

    private func addSplit(_ index: Int, _ split: NativeSplit, directory: String?) {
        let id = locals[index].id
        let terminal = makeTerminal()
        wirePane(terminal, of: id)
        locals[index].split = split
        locals[index].splitTerminal = terminal
        locals[index].splitDirectory = directory
        // placed first, so the shell starts at its pane's grid
        placeSessions()
        terminal.start(ShellIntegration.commandLine(locals[index].commandLine), directory: existingFolder(directory),
                       environment: sessionEnvironment(id, pane: .right))
        log("native shell: split \(split.axisName) in [\(id)]")
        if dashboard != nil { dashboardSessionsChanged() }
    }

    func closeSplit(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }), let terminal = locals[index].splitTerminal else { return }
        let hadFocus = hasFocus(id)
        locals[index].split = nil
        locals[index].splitTerminal = nil
        locals[index].splitTitle = nil
        locals[index].splitDirectory = nil
        locals[index].activity.paneEnded(.right)
        retire(terminal)
        placeSessions()
        rebuild()
        if dashboard != nil { dashboardSessionsChanged() }
        if hadFocus { focus() }
    }

    func swapPanes(_ id: Foundation.UUID) {
        guard let index = locals.firstIndex(where: { $0.id == id }), let split = locals[index].splitTerminal else { return }
        var session = locals[index]
        (session.terminal, session.splitTerminal) = (split, session.terminal)
        (session.programTitle, session.splitTitle) = (session.splitTitle, session.programTitle)
        let directory = session.directory
        session.directory = session.splitDirectory ?? directory
        session.splitDirectory = directory
        session.split?.focused.toggle()
        session.activity.swapped()
        locals[index] = session
        placeSessions()
        rebuild()
    }

    /// paneFocused follows a click into the other pane of a shown split.
    private func paneFocused(_ id: Foundation.UUID, _ terminal: NativeTerminal) {
        guard let index = locals.firstIndex(where: { $0.id == id }), locals[index].splitTerminal != nil,
              let focused = locals[index].split?.focused else { return }
        let inSplit = terminal === locals[index].splitTerminal
        guard inSplit || terminal === locals[index].terminal, inSplit != focused else { return }
        locals[index].split?.focused = inSplit
        rebuild()
    }

    /// paneExited closes the pane whose program ended: a split or scratch goes; a primary pane with a split hands its
    /// place to the split, as a Mac promotes it; a lone primary pane stays, exited, to restart.
    private func paneExited(_ id: Foundation.UUID, _ terminal: NativeTerminal) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        if terminal === locals[index].scratch {
            dropScratch(index)
        } else if terminal === locals[index].splitTerminal {
            closeSplit(id)
        } else if terminal === locals[index].terminal, locals[index].splitTerminal != nil {
            let hadFocus = hasFocus(id)
            swapPanes(id)
            closeSplit(id)
            if hadFocus { focus() }
        } else if terminal === locals[index].terminal {
            localExited(id)
        }
    }

    /// retire destroys a terminal once the message that ended it has returned.
    private func retire(_ terminal: NativeTerminal) {
        ShowWindow(terminal.window, SW_HIDE)
        DispatchQueue.main.async { if let window = terminal.window { DestroyWindow(window) } }
    }

    private func existingFolder(_ path: String?) -> String? {
        var isFolder: ObjCBool = false
        if let path, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { return path }
        return ProcessInfo.processInfo.environment["USERPROFILE"]
    }

    // MARK: divider

    private func point(_ lParam: LPARAM) -> (x: Int32, y: Int32) {
        (Int32(Int16(truncatingIfNeeded: lParam)), Int32(Int16(truncatingIfNeeded: lParam >> 16)))
    }

    /// selectedLayout is the selected session's panes while its split is shown and nothing covers them.
    private var selectedLayout: (id: Foundation.UUID, split: NativeSplit, layout: PaneLayout)? {
        guard dashboard == nil, let session = local(selected), session.splitTerminal != nil, let split = session.split, split.shown,
              !session.scratchShown, session.overlay.map({ $0.state.hidden }) != false else { return nil }
        return (session.id, split, PaneLayout(area: sessionArea, split: split, divider: dividerThickness))
    }

    /// bodyMouseDown takes a press below the title bar: on a dashboard cell it jumps there, on a divider it starts a
    /// drag, and a double-click on one evens the split.
    func bodyMouseDown(_ lParam: LPARAM, double: Bool) -> Bool {
        let (x, y) = point(lParam)
        guard y >= titleBar.contentTop else { return false }
        if onSidebarDivider(x: x) {
            sidebarDragging = true
            SetCapture(window)
            return true
        }
        if let dashboard {
            let cells = NativeDashboard.cells(in: sessionArea, count: dashboard.members.count, gap: scaled(6), caption: scaled(22))
            if let index = NativeDashboard.cell(at: x, y, in: cells) { jump(to: dashboard.members[index]) }
            return true
        }
        guard let shown = selectedLayout, shown.layout.onDivider(x: x, y: y, slop: scaled(2)) else { return false }
        if double {
            var even = shown.split
            even.ratio = NativeSplit.defaultRatio
            setSplit(shown.id, even)
        } else {
            dragging = (shown.id, sessionArea)
            SetCapture(window)
        }
        return true
    }

    func dragDivider(_ lParam: LPARAM) -> Bool {
        if sidebarDragging {
            sidebarResizeDrag(x: point(lParam).x)
            return true
        }
        guard let dragging, let index = locals.firstIndex(where: { $0.id == dragging.id }), let axis = locals[index].split?.axis else { return false }
        let (x, y) = point(lParam)
        locals[index].split?.ratio = PaneLayout.ratio(at: x, y, area: dragging.area, axis: axis, divider: dividerThickness)
        placeSessions()
        return true
    }

    func endDividerDrag() -> Bool {
        if sidebarDragging {
            sidebarDragging = false
            ReleaseCapture()
            return true
        }
        guard dragging != nil else { return false }
        dragging = nil
        ReleaseCapture()
        return true
    }

    /// dividerCursor shows the resize arrows over a divider and while dragging one.
    func dividerCursor() -> Bool {
        var cursor = POINT()
        GetCursorPos(&cursor)
        ScreenToClient(window, &cursor)
        if sidebarDragging || (cursor.y >= titleBar.contentTop && onSidebarDivider(x: cursor.x)) {
            SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32644))) // IDC_SIZEWE
            return true
        }
        let axis: SplitAxis
        if let dragging, let split = local(dragging.id)?.split {
            axis = split.axis
        } else if let shown = selectedLayout, shown.layout.onDivider(x: cursor.x, y: cursor.y, slop: scaled(2)) {
            axis = shown.split.axis
        } else {
            return false
        }
        SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: axis == .leftRight ? 32644 : 32645))) // IDC_SIZEWE, IDC_SIZENS
        return true
    }

    // MARK: scratch

    /// setScratch shows or hides the session's scratch, starting its shell in the session's folder, or `command` beside the
    /// session as an overlay's runs, when it has none; a `command` replaces a running one.
    func setScratch(_ id: Foundation.UUID, shown: Bool, command: String?) {
        guard let index = locals.firstIndex(where: { $0.id == id }) else { return }
        let hadFocus = hasFocus(id)
        if command != nil, let running = locals[index].scratch {
            locals[index].scratch = nil
            retire(running)
        }
        locals[index].scratchShown = shown
        if shown, locals[index].scratch == nil {
            let terminal = makeTerminal()
            wirePane(terminal, of: id)
            let session = locals[index]
            locals[index].scratch = terminal
            locals[index].scratchDirectory = session.directory
            placeSessions()
            if let command {
                let launch = NativeOverlay.launch(command, sessionCommandLine: session.commandLine, cwd: nil, directory: session.directory)
                terminal.start(launch.commandLine, directory: existingFolder(launch.directory),
                               environment: sessionEnvironment(id, pane: .scratch))
            } else {
                terminal.start(ShellIntegration.commandLine(session.commandLine), directory: existingFolder(session.directory),
                               environment: sessionEnvironment(id, pane: .scratch))
            }
            log("native shell: scratch in [\(id)]")
        } else {
            placeSessions()
        }
        if hadFocus || id == selected && GetFocus() != nil { focus() }
    }

    private func dropScratch(_ index: Int) {
        guard let scratch = locals[index].scratch else { return }
        let hadFocus = hasFocus(locals[index].id)
        locals[index].scratch = nil
        locals[index].scratchShown = false
        locals[index].activity.paneEnded(.scratch)
        retire(scratch)
        placeSessions()
        if hadFocus { focus() }
    }

    // MARK: dashboard

    /// toggleDashboard opens the grid on the most recently used local sessions, the cell font scaled to it, or closes it.
    func toggleDashboard() {
        if dashboard != nil {
            closeDashboard()
            return
        }
        let ids = locals.map(\.id)
        let recent = recentSessions.filter(ids.contains)
        let ordered = recent + ids.filter { !recent.contains($0) }
        let members = NativeDashboard.members(for: ordered.map { .init(session: $0, pane: nil) }, hasSplit: { local($0)?.splitTerminal != nil }).members
        guard !members.isEmpty else { return }
        openDashboard(members, fontMode: .auto)
    }

    func openDashboard(_ members: [DashboardMember], fontMode: DashboardFontMode) {
        if dashboard != nil { closeDashboard(refocus: false) }
        quick?.hide()
        let inView = local(selected).map { DashboardMember(session: $0.id, surface: $0.split?.focused == true && $0.splitTerminal != nil ? .split : .primary) }
        let size = fontMode.appliedFontSize(memberCount: members.count, base: Double(settings.fontPoints))
        dashboard = NativeControl.Dashboard(members: members, highlighted: inView.flatMap { members.contains($0) ? $0 : nil } ?? members.first,
                                            fontMode: fontMode, fontSize: size)
        if let size { members.compactMap(memberTerminal).forEach { $0.setFontSize(Float(size)) } }
        let instance = GetModuleHandleW(nil)
        captions = members.map { _ in
            CreateWindowExW(0, Array("STATIC".utf16) + [0], nil, DWORD(WS_CHILD) | DWORD(SS_LEFT) | DWORD(SS_CENTERIMAGE) | DWORD(SS_ENDELLIPSIS),
                            0, 0, 1, 1, window, nil, instance, nil)
        }.compactMap { $0 }
        log("native shell: dashboard of \(members.count) pane(s)")
        placeSessions()
        focus()
    }

    func closeDashboard() { closeDashboard(refocus: true) }

    func closeDashboard(refocus: Bool) {
        guard let open = dashboard else { return }
        dashboard = nil
        if open.fontSize != nil { open.members.compactMap(memberTerminal).forEach { $0.setFontSize(settings.fontPoints) } }
        captions.forEach { DestroyWindow($0) }
        captions = []
        placeSessions()
        if refocus { focus() }
    }

    /// dashboardSessionsChanged drops the cells whose pane is gone, and closes a grid left with none.
    func dashboardSessionsChanged() {
        guard let open = dashboard else { return }
        let survivors = open.members.filter { memberTerminal($0) != nil }
        guard survivors != open.members else { return }
        closeDashboard(refocus: false)
        if !survivors.isEmpty { openDashboard(survivors, fontMode: open.fontMode) }
    }

    private func memberTerminal(_ member: DashboardMember) -> NativeTerminal? {
        local(member.session)?.pane(member.surface == .split ? .split : .primary)
    }

    private func placeDashboard(_ dashboard: NativeControl.Dashboard, in area: Rect) {
        let shown = Set(dashboard.members.compactMap { memberTerminal($0).map(ObjectIdentifier.init) })
        for terminal in terminalsShown where !shown.contains(ObjectIdentifier(terminal)) { show(terminal, false) }
        let cells = NativeDashboard.cells(in: area, count: dashboard.members.count, gap: scaled(6), caption: scaled(22))
        for (index, member) in dashboard.members.enumerated() where cells.indices.contains(index) {
            guard let terminal = memberTerminal(member) else { continue }
            place(terminal, cells[index].terminal, shown: true)
            guard captions.indices.contains(index), let session = local(member.session) else { continue }
            let strip = cells[index].caption
            let text = " " + NativeDashboard.caption(name: session.name, member: member, split: session.splitTerminal == nil ? nil : session.split?.axis)
            SetWindowTextW(captions[index], Array(text.utf16) + [0])
            MoveWindow(captions[index], strip.x, strip.y, strip.width, strip.height, true)
            ShowWindow(captions[index], SW_SHOW)
            InvalidateRect(captions[index], nil, true)
        }
    }

    /// dashboardKey answers a key while the grid has the keyboard: arrows move the highlight, Enter jumps, Esc closes,
    /// and the keymap's chords run their commands.
    func dashboardKey(_ key: Int32) -> Bool {
        guard var open = dashboard else { return false }
        let direction: DashboardLayout.Direction? = switch key {
        case VK_LEFT: .left
        case VK_RIGHT: .right
        case VK_UP: .up
        case VK_DOWN: .down
        default: nil
        }
        if let direction, let highlighted = open.highlighted, let from = open.members.firstIndex(of: highlighted) {
            let (columns, _) = DashboardLayout.grid(count: open.members.count)
            open.highlighted = open.members[DashboardLayout.move(from: from, direction: direction, cols: columns, count: open.members.count)]
            dashboard = open
            captions.forEach { InvalidateRect($0, nil, true) }
            return true
        }
        switch key {
        case VK_RETURN:
            if let highlighted = open.highlighted { jump(to: highlighted) }
            return true
        case VK_ESCAPE:
            closeDashboard()
            return true
        default:
            guard let chord = Keys.chord(virtualKey: key) else { return false }
            switch Keys.keymap.press(chord) {
            case .command(let command):
                windowCommand(command)
                return true
            case .consumed: return true
            case .pass: return false
            }
        }
    }

    /// jump closes the grid into `member`'s session with that pane focused.
    private func jump(to member: DashboardMember) {
        closeDashboard(refocus: false)
        select(member.session)
        if var split = local(member.session)?.split, local(member.session)?.splitTerminal != nil {
            split.focused = member.surface == .split
            setSplit(member.session, split)
        }
        focus()
    }

    // MARK: quick terminal

    var quickShown: Bool { quick?.shown ?? false }

    /// toggleQuick is the quick terminal's key, button and global hotkey: a person's summon, dismissed by clicking away.
    func toggleQuick() {
        if quickShown {
            quick?.hide()
            return
        }
        // the click on the button that toggles it is what just took the keyboard from it
        if let quick, Date().timeIntervalSince(quick.resignedAt) < 0.4 { return }
        showQuick(pinned: false)
    }

    func showQuick(pinned: Bool) {
        if quick == nil {
            let made = QuickWindow(points: { [unowned self] in settings.fontPoints }, configure: { [unowned self] terminal in
                terminal.onWindowCommand = { [unowned self] command in
                    if command == .quickTerminal || command == .closeSession { quick?.hide() } else { windowCommand(command) }
                }
                terminal.onFontSize = { [unowned self] in setFontSize($0) }
                terminal.onAttention = nil
            }, start: { [unowned self] terminal in startQuickShell(terminal) })
            made.onVisibility = { [unowned self] in invalidateTitleBar() }
            quick = made
        }
        quick?.show(pinned: pinned)
    }

    /// startQuickShell runs the default profile in the selected local session's folder, else the user's home.
    private func startQuickShell(_ terminal: NativeTerminal) {
        let commandLine = quickProfileCommandLine ?? "cmd.exe"
        var environment = ProcessInfo.processInfo.environment
        environment["AGTERM_STATE_DIR"] = stateDirectory.path
        terminal.start(ShellIntegration.commandLine(commandLine), directory: existingFolder(local(selected)?.directory), environment: environment)
        log("native shell: quick terminal started")
    }

    func registerGlobalHotkey() {
        UnregisterHotKey(window, Self.quickHotkey)
        guard let hotkey = Keys.keymap.globalHotkey else { return }
        if !RegisterHotKey(window, Self.quickHotkey, UINT(hotkey.modifiers), UINT(hotkey.key)) {
            log("native shell: global-hotkey is taken by another application (\(GetLastError()))")
        }
    }
}
