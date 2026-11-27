import Foundation

/// A terminal notification (OSC 9/777) a pane raised, with what the host knew about focus when it fired.
public struct TerminalNotificationRecord: Sendable, Equatable {
    public let sessionID: UUID
    public let windowID: UUID
    public let pane: PaneRole
    public let title: String
    public let body: String
    public let firingIsFocused: Bool
    public let appActive: Bool

    public init(sessionID: UUID, windowID: UUID, pane: PaneRole, title: String, body: String,
                firingIsFocused: Bool, appActive: Bool) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.pane = pane
        self.title = title
        self.body = body
        self.firingIsFocused = firingIsFocused
        self.appActive = appActive
    }
}

/// What the host posts to the desktop for a recorded notification; `identity` replaces an earlier post from the same pane.
public struct NotificationDelivery: Sendable, Equatable {
    public let title: String
    public let body: String
    public let identity: String
}

/// Which pane a notification click focuses: the pane that fired it while that pane still exists, else the primary.
public enum NotificationRevealFocus: Sendable, Equatable {
    case primary
    case split
    case overlay

    public static func resolve(pane: PaneRole, sessionExists: Bool, hasSplit: Bool,
                               coverActive: Bool) -> NotificationRevealFocus? {
        guard sessionExists else { return nil }
        switch pane {
        case .split where hasSplit: return .split
        case .overlay where coverActive: return .overlay
        default: return .primary
        }
    }
}

extension AppStore {
    /// recordTerminalNotification counts an unseen notification on its session and returns the desktop post, or nil
    /// when the session is gone or the user is already looking at the firing pane.
    @discardableResult
    public func recordTerminalNotification(_ record: TerminalNotificationRecord) -> NotificationDelivery? {
        guard let session = session(withID: record.sessionID),
              TerminalNotification.shouldDeliver(firingIsFocused: record.firingIsFocused, appActive: record.appActive)
        else { return nil }
        session.unseenCount += 1
        return NotificationDelivery(
            title: record.title, body: record.body,
            identity: TerminalNotification.identity(windowID: record.windowID, sessionID: record.sessionID, pane: record.pane))
    }
}
