import Foundation
import agtermCore

/// The `session.overlay.*` program overlay of a local session, in the Mac's wording and reply shapes; pages, split
/// panes and point sizes are refused by name.
extension NativeControl {
    static func overlay(_ request: ControlRequest, host: NativeControlHost) async -> ControlResponse {
        let args = request.args
        if let refusal = overlayRefusal(request) { return failure(refusal) }
        let id: UUID
        switch resolve(request.target, host: host) {
        case .failure(let refusal): return failure(refusal.message)
        case .success(let resolved): id = resolved
        }
        if host.isServerSession(id) { return failure(NativeOverlay.serverRefusal) }
        guard let local = host.localSessions.first(where: { $0.id == id }) else { return failure("no such session: \(id.uuidString)") }
        let done = ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        switch request.cmd {
        case .sessionOverlayOpen:
            if local.overlay?.hidden == true { return failure(OverlayVisibilityError.hidden) }
            if local.overlay != nil { return failure("overlay already open") }
            host.openOverlay(id, NativeOverlay.Open(command: args?.command ?? "", cwd: args?.cwd, wait: args?.wait == true,
                                                    sizePercent: args?.sizePercent, background: NativeOverlay.background(args?.color)))
            if args?.follow == true { host.selectSession(id) }
            return done
        case .sessionOverlayResult:
            if local.overlay != nil { return failure(OverlayResultError.stillRunning) }
            guard let code = local.overlayExitCode else { return failure(OverlayResultError.noResult) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        default:
            break
        }
        guard let overlay = local.overlay else { return failure("no overlay") }
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

    /// overlayRefusal checks what needs no session, in the order the Mac's dispatcher does.
    private static func overlayRefusal(_ request: ControlRequest) -> String? {
        let args = request.args
        if args?.pane != nil {
            return request.cmd == .sessionOverlayResize ? PaneOverlayError.resizeUnsupported : NativeOverlay.paneRefusal
        }
        if args?.width != nil || args?.height != nil { return NativeOverlay.pointsRefusal }
        switch request.cmd {
        case .sessionOverlayOpen:
            let page = [args?.html, args?.url, args?.image, args?.markdownFile, args?.textFile].contains { $0 != nil }
                || [args?.navigation, args?.javascript, args?.chromeless, args?.persistent, args?.browse].contains(true)
            if page { return NativeOverlay.pageRefusal }
            if args?.command?.isEmpty != false { return "session.overlay.open requires a command" }
            if let color = args?.color, !WatermarkConfig.isValidColorHex(color) { return "invalid color: \(color) (#rrggbb)" }
            if let percent = args?.sizePercent, !(1...100).contains(percent) { return "session.overlay.open: --size-percent must be 1...100" }
        case .sessionOverlayResize:
            let full = args?.full == true, percent = args?.sizePercent
            if full, percent != nil { return "session.overlay.resize: --full is mutually exclusive with --size-percent" }
            if !full, percent == nil { return "session.overlay.resize requires --size-percent, --width/--height or --full" }
            if let percent, !(1...100).contains(percent) { return "session.overlay.resize: --size-percent must be 1...100" }
        case .sessionOverlayResult:
            // no page can have been opened here
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
