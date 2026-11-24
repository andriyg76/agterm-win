import Foundation
import agtermCore

/// GeneralSettings are Settings ▸ General: the macOS General choices that apply to agterm-win. The tab's agterm-server
/// check boxes are `NativeSettings.serverLaunch`.
public struct GeneralSettings: Codable, Equatable, Sendable {
    /// newSessionDirectory is an `AppSettings.NewSessionDirectory` raw value, as macOS stores it; nil is home.
    public var newSessionDirectory: String?
    /// newSessionCustomDirectory is the folder `custom` names; a missing one falls back to home.
    public var newSessionCustomDirectory: String?
    /// newSessionPlacement is an `AppSettings.NewSessionPlacement` raw value; nil is the end of the list.
    public var newSessionPlacement: String?
    /// confirmCloseSession asks before a menu, key or sidebar close ends a local session; `session.close` never asks.
    public var confirmCloseSession = false
    /// rightClickPastes pastes on a right click, Shift+right click opening the menu; off keeps the menu, Windows'
    /// convention, where macOS agterm, which has no terminal menu, pastes.
    public var rightClickPastes = false
    /// scrollLines is how far a wheel notch scrolls, macOS's `mouse-scroll-multiplier`.
    public var scrollLines = GeneralSettings.defaultScrollLines

    public static let defaultScrollLines = 3
    public static let scrollLineRange = 1...10

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        newSessionDirectory = try container.decodeIfPresent(String.self, forKey: .newSessionDirectory)
        newSessionCustomDirectory = try container.decodeIfPresent(String.self, forKey: .newSessionCustomDirectory)
        newSessionPlacement = try container.decodeIfPresent(String.self, forKey: .newSessionPlacement)
        confirmCloseSession = try container.decodeIfPresent(Bool.self, forKey: .confirmCloseSession) ?? false
        rightClickPastes = try container.decodeIfPresent(Bool.self, forKey: .rightClickPastes) ?? false
        let lines = try container.decodeIfPresent(Int.self, forKey: .scrollLines) ?? Self.defaultScrollLines
        scrollLines = Self.scrollLineRange.contains(lines) ? lines : Self.defaultScrollLines
    }

    public var directory: AppSettings.NewSessionDirectory {
        newSessionDirectory.flatMap(AppSettings.NewSessionDirectory.init(rawValue:)) ?? .home
    }

    public var placement: AppSettings.NewSessionPlacement {
        newSessionPlacement.flatMap(AppSettings.NewSessionPlacement.init(rawValue:)) ?? .end
    }

    /// startDirectory is where a new session from the menu or a key starts: home, the selected session's folder, or the
    /// custom folder, each only while it exists, else home.
    public func startDirectory(current: String?, home: String, exists: (String) -> Bool) -> String {
        let wanted: String? = switch directory {
        case .home: nil
        case .currentSession: current
        case .custom: newSessionCustomDirectory
        }
        guard let wanted, !wanted.isEmpty, exists(wanted) else { return home }
        return wanted
    }

    /// insertionIndex is where a new session goes among `count` sessions: the end, or right after the selected one.
    public func insertionIndex(count: Int, selected: Int?) -> Int {
        guard placement == .afterCurrent, let selected, (0..<count).contains(selected) else { return count }
        return selected + 1
    }
}
