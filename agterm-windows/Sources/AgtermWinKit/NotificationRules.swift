import Foundation
import agtermCore

/// TaskbarFlash is what a notification does to the taskbar button while agterm is in the background, the Windows
/// counterpart of the macOS Dock bounce.
public enum TaskbarFlash: String, Codable, CaseIterable, Sendable {
    case off
    case once
    case untilFocused

    public var title: String {
        switch self {
        case .off: "Off"
        case .once: "Once"
        case .untilFocused: "Until agterm is in front"
        }
    }
}

/// NotificationSettings are Settings ▸ Notifications.
public struct NotificationSettings: Codable, Equatable, Sendable {
    /// banners shows a Windows notification; the sidebar marks the session either way.
    public var banners = true
    /// sound plays Windows' notification sound with a banner.
    public var sound = true
    public var flash = TaskbarFlash.untilFocused
    /// unseenCount writes how many notifications a session had since it was last in view beside its ● marker.
    public var unseenCount = true

    public init(banners: Bool = true, sound: Bool = true, flash: TaskbarFlash = .untilFocused, unseenCount: Bool = true) {
        self.banners = banners
        self.sound = sound
        self.flash = flash
        self.unseenCount = unseenCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        banners = try container.decodeIfPresent(Bool.self, forKey: .banners) ?? true
        sound = try container.decodeIfPresent(Bool.self, forKey: .sound) ?? true
        flash = (try? container.decodeIfPresent(TaskbarFlash.self, forKey: .flash)) ?? .untilFocused
        unseenCount = try container.decodeIfPresent(Bool.self, forKey: .unseenCount) ?? true
    }
}

/// NotificationRules are macOS agterm's notification rules as agterm-win applies them.
public enum NotificationRules {
    public enum Source: Sendable {
        /// terminal is OSC 9 or 777 from a session's program.
        case terminal
        /// control is `agtermctl notify`.
        case control
    }

    /// delivers drops a terminal notification from the session in view while its window is in front; a `notify` is
    /// never dropped, since a script asked for it.
    public static func delivers(_ source: Source, sessionInView: Bool, windowInFront: Bool) -> Bool {
        source == .control || TerminalNotification.shouldDeliver(firingIsFocused: sessionInView, appActive: windowInFront)
    }

    /// tag keeps a terminal's notifications and `notify`'s apart: each replaces only its own last banner, so a
    /// program's notification never hides a note a script sent.
    public static func tag(_ source: Source) -> String { source == .control ? "notify" : "terminal" }

    /// toast is the banner's XML: the title, else the session's name, then the body, and the session's name as the
    /// attribution line when the title took the first line.
    public static func toast(title: String, body: String, session: String, sound: Bool) -> String {
        let heading = title.isEmpty ? session : title
        let attribution = title.isEmpty ? "" : "<text placement=\"attribution\">\(escaped(session))</text>"
        return "<toast><visual><binding template=\"ToastGeneric\"><text>\(escaped(heading))</text><text>\(escaped(body))</text>"
            + attribution + "</binding></visual>" + (sound ? "" : "<audio silent=\"true\"/>") + "</toast>"
    }

    static func escaped(_ text: String) -> String {
        var result = ""
        for character in TerminalText.sanitized(text) {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// countLabel is the unseen count beside a session's marker, capped as the macOS badge is.
    public static func countLabel(_ unseen: Int) -> String { unseen > 99 ? "99+" : String(unseen) }
}
