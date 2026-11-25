/// ControlMetadataRejection is the refusal text of a `session.status`, `session.context` or `session.info` request.
public struct ControlMetadataRejection: Error, Equatable, Sendable {
    public let message: String
}

/// ControlSessionMetadata parses the session metadata writes once, for `ControlDispatcher` and for agterm-win, which
/// serves them without one, so both refuse the same input with the same text.
public enum ControlSessionMetadata {
    public static func status(_ args: ControlArgs?) -> Result<ControlSessionStatusUpdate, ControlMetadataRejection> {
        guard let status = AgentStatus(rawValue: args?.status ?? "") else { return .failure(.init(message: "invalid status")) }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return .failure(.init(message: "invalid color (expected #rrggbb)"))
        }
        var shape: StatusShape?
        if let raw = args?.shape {
            guard let parsed = StatusShape(rawValue: raw) else {
                return .failure(.init(message: "invalid shape: \(raw) (\(StatusShape.validNamesList))"))
            }
            shape = parsed
        }
        var pane: StatusPane?
        if let raw = args?.pane {
            guard let parsed = StatusPane(controlName: raw) else { return .failure(.init(message: "--pane must be left, right, or scratch")) }
            pane = parsed
        }
        return .success(ControlSessionStatusUpdate(status: status, blink: args?.blink, autoReset: args?.autoReset, sound: args?.sound,
                                                   color: args?.color, shape: shape, pane: pane, paneID: args?.paneID,
                                                   ifIdle: args?.ifIdle ?? false))
    }

    /// context is the value a `session.context` write leaves, nil for `clear`. The mode is required rather than
    /// inferred from `text`, so "both" and "neither" are errors a raw socket client can reach.
    public static func context(_ args: ControlArgs?) -> Result<String?, ControlMetadataRejection> {
        switch args?.mode ?? "" {
        case "set":
            guard let text = args?.text else { return .failure(.init(message: "session.context set requires text")) }
            switch Session.validateContext(text) {
            case .valid(let value): return .success(value)
            case .invalid(let message): return .failure(.init(message: message))
            }
        case "clear":
            guard args?.text == nil else { return .failure(.init(message: "session.context clear takes no text")) }
            return .success(nil)
        default:
            return .failure(.init(message: "invalid context mode: \(args?.mode ?? "") (set|clear)"))
        }
    }

    /// info is the line a `session.info` write leaves, nil for `clear`.
    public static func info(_ args: ControlArgs?) -> Result<SessionInfo?, ControlMetadataRejection> {
        switch args?.mode ?? "" {
        case "set":
            guard let text = args?.text else { return .failure(.init(message: "session.info set requires text")) }
            switch SessionInfo.make(source: text, markdown: args?.markdown ?? false, hideAfter: args?.hideAfter ?? 0) {
            case .success(let info): return .success(info)
            case .failure(let rejection): return .failure(.init(message: "session.info: \(rejection.message)"))
            }
        case "clear":
            guard args?.text == nil, args?.markdown == nil, args?.hideAfter == nil else {
                return .failure(.init(message: "session.info clear takes no text, markdown or hide-after"))
            }
            return .success(nil)
        default:
            return .failure(.init(message: "invalid info mode: \(args?.mode ?? "") (set|clear)"))
        }
    }
}
