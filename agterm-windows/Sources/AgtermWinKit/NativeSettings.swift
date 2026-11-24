import Foundation
import agtermCore

/// NativeSettings is what the native window keeps between launches, in its state directory.
public struct NativeSettings: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public var left, top, right, bottom: Int32

        public init(left: Int32, top: Int32, right: Int32, bottom: Int32) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        /// fitted is this rectangle moved, and shrunk when it is larger, to lie inside `area` (a monitor's work area).
        public func fitted(in area: Frame) -> Frame {
            let width = min(right - left, area.right - area.left), height = min(bottom - top, area.bottom - area.top)
            let x = min(max(left, area.left), area.right - width), y = min(max(top, area.top), area.bottom - height)
            return Frame(left: x, top: y, right: x + width, bottom: y + height)
        }
    }

    /// LocalSession is a local session to start again at the next launch: the name it falls back to, the user's own
    /// name, what it ran, and the folder it was last in, where it starts again.
    public struct LocalSession: Codable, Equatable, Sendable {
        public var title: String
        public var customName: String?
        public var commandLine: String
        public var directory: String?
        /// split is the session's second pane, started again in its folder; nil without one.
        public var split: Split?

        public init(title: String, customName: String? = nil, commandLine: String, directory: String? = nil, split: Split? = nil) {
            self.title = title
            self.customName = customName
            self.commandLine = commandLine
            self.directory = directory
            self.split = split
        }
    }

    /// Split is a saved split: its layout, and the folder its pane was last in.
    public struct Split: Codable, Equatable, Sendable {
        public var axis: SplitAxis
        public var ratio: Double
        public var shown: Bool
        public var focused: Bool
        public var directory: String?

        public init(_ split: NativeSplit, directory: String?) {
            axis = split.axis
            ratio = split.ratio
            shown = split.shown
            focused = split.focused
            self.directory = directory
        }

        public var layout: NativeSplit { NativeSplit(axis: axis, ratio: ratio, shown: shown, focused: focused) }
    }

    public var fontPoints: Float = NativeMenu.defaultPoints
    public var appearance = Appearance()
    public var notifications = NotificationSettings()
    public var general = GeneralSettings()
    /// frame is the window's restored (not maximized) rectangle in screen pixels.
    public var frame: Frame?
    public var maximized = false
    public var localSessions: [LocalSession] = []
    /// defaultProfile names the launch profile New Session's shortcut starts; nil is the first.
    public var defaultProfile: String?
    /// selectedLocal indexes `localSessions` when one was in view at quit; nil leaves the selection to the server's.
    public var selectedLocal: Int?
    /// serverLaunch is the choice made for each WSL distribution's agterm-server, by distribution name.
    public var serverLaunch: [String: ServerLaunch] = [:]

    public init() {}

    /// load reads `url`, falling back to the defaults for a missing or unreadable file, and for a font size out of range.
    public static func load(from url: URL) -> NativeSettings {
        guard let data = try? Data(contentsOf: url), var settings = try? JSONDecoder().decode(NativeSettings.self, from: data) else {
            return NativeSettings()
        }
        if !NativeMenu.pointRange.contains(settings.fontPoints) { settings.fontPoints = NativeMenu.defaultPoints }
        if let frame = settings.frame, frame.right <= frame.left || frame.bottom <= frame.top { settings.frame = nil }
        settings.localSessions.removeAll { $0.commandLine.isEmpty }
        if let index = settings.selectedLocal, !settings.localSessions.indices.contains(index) { settings.selectedLocal = nil }
        return settings
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // decodes a file from an older build, which lacks later fields, with their defaults
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontPoints = try container.decodeIfPresent(Float.self, forKey: .fontPoints) ?? NativeMenu.defaultPoints
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? Appearance()
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? GeneralSettings()
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        maximized = try container.decodeIfPresent(Bool.self, forKey: .maximized) ?? false
        localSessions = try container.decodeIfPresent([LocalSession].self, forKey: .localSessions) ?? []
        selectedLocal = try container.decodeIfPresent(Int.self, forKey: .selectedLocal)
        defaultProfile = try container.decodeIfPresent(String.self, forKey: .defaultProfile)
        serverLaunch = try container.decodeIfPresent([String: ServerLaunch].self, forKey: .serverLaunch) ?? [:]
    }
}
