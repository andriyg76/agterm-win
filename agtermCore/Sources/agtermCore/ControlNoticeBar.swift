import Foundation

/// ControlNoticeBar is agterm-win's window notice bar: where it sits and what it holds, most important first.
/// The bar shows the first notice that is not dismissed, and nothing when every one is.
public struct ControlNoticeBar: Codable, Sendable, Equatable {
    /// position is `top` or `bottom`.
    public let position: String
    public let notices: [ControlNotice]

    public init(position: String, notices: [ControlNotice]) {
        self.position = position
        self.notices = notices
    }
}

public struct ControlNotice: Codable, Sendable, Equatable {
    public let text: String
    /// severity is `info`, `progress` or `error`.
    public let severity: String
    /// actions name the bar's buttons for the notice, omitted at none.
    public let actions: [String]?
    /// dismissed is set while the user closed the notice and it has not changed since, omitted otherwise.
    public let dismissed: Bool?

    public init(text: String, severity: String, actions: [String]? = nil, dismissed: Bool? = nil) {
        self.text = text
        self.severity = severity
        self.actions = actions
        self.dismissed = dismissed
    }
}
