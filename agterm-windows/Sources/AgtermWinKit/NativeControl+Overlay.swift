import Foundation
import agtermCore

/// The `session.overlay.*` surface for local and connected catalog sessions, in the Mac's wording and reply shapes.
extension NativeControl {
    static func overlay(_ request: ControlRequest, host: NativeControlHost) async -> ControlResponse {
        let args = request.args
        if let refusal = overlayRefusal(request) { return failure(refusal) }
        let id: UUID
        switch resolve(request.target, host: host) {
        case .failure(let refusal): return failure(refusal.message)
        case .success(let resolved): id = resolved
        }
        let slot: OverlaySlot
        if host.isServerSession(id) {
            guard host.isConnectedServerSession(id) else { return failure(NativeOverlay.serverDisconnectedRefusal) }
            let state = host.serverOverlayState(for: id) ?? (nil, nil)
            let page = host.serverPageOverlay(for: id)
            slot = OverlaySlot(program: state.overlay, exitCode: state.exitCode, page: page?.page,
                               pageHidden: page?.hidden ?? false)
        } else if let local = host.localSessions.first(where: { $0.id == id }) {
            slot = OverlaySlot(program: local.overlay, exitCode: local.overlayExitCode, page: local.htmlOverlay, pageHidden: local.pageOverlayHidden)
        } else {
            return failure("no such session: \(id.uuidString)")
        }
        let done = ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        switch request.cmd {
        case .sessionOverlayOpen:
            if slot.pageHidden || slot.program?.hidden == true { return failure(OverlayVisibilityError.hidden) }
            if slot.occupied { return failure("overlay already open") }
            switch ControlOverlayOpen.parse(command: args?.command ?? "", args: args) {
            case .failure(let reason): return failure(reason.message)
            case .success(let source):
                if let source {
                    guard !host.isServerSession(id) else { return failure(NativeOverlay.serverRefusal) }
                    guard pageSupported(source) else { return failure(NativeOverlay.pageRefusal) }
                    let page = HtmlOverlay(source: source, navigation: args?.navigation ?? false, javascript: args?.javascript ?? false,
                                           chromeless: args?.chromeless ?? false, persistent: args?.persistent ?? false,
                                           browse: args?.browse ?? false)
                    host.openPageOverlay(id, page, sizePercent: args?.sizePercent)
                } else {
                    host.openOverlay(id, NativeOverlay.Open(command: args?.command ?? "", cwd: args?.cwd, wait: args?.wait == true,
                                                            sizePercent: args?.sizePercent,
                                                            background: NativeOverlay.background(args?.color)))
                }
                if args?.follow == true { host.selectSession(id) }
                return done
            }
        case .sessionOverlayResult:
            if slot.page != nil { return failure(OverlayHtmlError.noResult) }
            if slot.program != nil { return failure(OverlayResultError.stillRunning) }
            guard let code = slot.exitCode else { return failure(OverlayResultError.noResult) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        default:
            break
        }
        if let page = slot.page {
            switch request.cmd {
            case .sessionOverlayClose:
                host.closeOverlay(id)
            case .sessionOverlayResize:
                host.resizeOverlay(id, sizePercent: args?.full == true ? nil : args?.sizePercent)
            case .sessionOverlayText, .sessionOverlayCopy:
                return failure(OverlayHtmlError.noRead)
            case .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
                let hidden = request.cmd == .sessionOverlayHide || request.cmd == .sessionOverlayToggle && !slot.pageHidden
                host.setOverlayHidden(id, hidden)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: hidden ? "hidden" : "shown"))
            default:
                break
            }
            return done
        }
        guard let overlay = slot.program else { return failure("no overlay") }
        switch request.cmd {
        case .sessionOverlayClose:
            host.closeOverlay(id)
        case .sessionOverlayResize:
            host.resizeOverlay(id, sizePercent: args?.full == true ? nil : args?.sizePercent)
        case .sessionOverlayText:
            guard let screen = host.overlayScreen(of: id) else { return failure("overlay not realized") }
            return ControlResponse(ok: true, result: ControlResult(text: text(screen.lines, rows: screen.rows, all: args?.all == true, last: args?.lines)))
        case .sessionOverlayCopy:
            guard let selection = host.overlaySelection(of: id), !selection.isEmpty else { return failure("no selection") }
            return ControlResponse(ok: true, result: ControlResult(text: selection))
        case .sessionOverlayHide, .sessionOverlayShow, .sessionOverlayToggle:
            let hidden = request.cmd == .sessionOverlayHide || request.cmd == .sessionOverlayToggle && !overlay.hidden
            host.setOverlayHidden(id, hidden)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: hidden ? "hidden" : "shown"))
        default:
            break
        }
        return done
    }

    private struct OverlaySlot {
        var program: NativeOverlay?
        var exitCode: Int?
        var page: HtmlOverlay?
        var pageHidden: Bool
        var occupied: Bool { program != nil || page != nil }
    }

    private static func pageSupported(_ source: HtmlSource) -> Bool {
        switch source {
        case .file, .url, .image: return true
        default: return false
        }
    }

    /// overlayRefusal checks what needs no session, in the order the Mac's dispatcher does.
    private static func overlayRefusal(_ request: ControlRequest) -> String? {
        let args = request.args
        if args?.pane != nil {
            return request.cmd == .sessionOverlayResize ? PaneOverlayError.resizeUnsupported : NativeOverlay.paneRefusal
        }
        if args?.width != nil || args?.height != nil { return NativeOverlay.pointsRefusal }
        switch request.cmd {
        case .sessionOverlayOpen:
            if args?.command?.isEmpty != false, args?.html == nil, args?.url == nil,
               args?.image == nil, args?.markdownFile == nil, args?.textFile == nil {
                return "session.overlay.open requires a command"
            }
            if let color = args?.color, !WatermarkConfig.isValidColorHex(color) { return "invalid color: \(color) (#rrggbb)" }
            if let percent = args?.sizePercent, !(1...100).contains(percent) { return "session.overlay.open: --size-percent must be 1...100" }
        case .sessionOverlayResize:
            let full = args?.full == true, percent = args?.sizePercent
            if full, percent != nil { return "session.overlay.resize: --full is mutually exclusive with --size-percent" }
            if !full, percent == nil { return "session.overlay.resize requires --size-percent, --width/--height or --full" }
            if let percent, !(1...100).contains(percent) { return "session.overlay.resize: --size-percent must be 1...100" }
        case .sessionOverlayResult:
            if args?.page != nil { return OverlayHtmlError.unknownPage }
        case .sessionOverlayText:
            if args?.all == true, args?.lines != nil { return "--all and --lines are exclusive" }
            if let lines = args?.lines, lines <= 0 { return "--lines must be positive" }
        default:
            break
        }
        return nil
    }
}