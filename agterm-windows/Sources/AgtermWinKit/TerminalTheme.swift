import Foundation
import agtermCore

/// TerminalTheme is a ghostty theme file's colors, the format and names agterm's macOS themes use. A color the file
/// leaves out stays the terminal's default.
public struct TerminalTheme: Equatable, Sendable {
    public var foreground: UInt32?
    public var background: UInt32?
    public var cursor: UInt32?
    public var cursorText: UInt32?
    public var selectionBackground: UInt32?
    public var selectionForeground: UInt32?
    /// palette holds the indices the file sets, of the 256.
    public var palette: [Int: UInt32] = [:]

    public init() {}

    /// parse reads the color keys of `key = value` lines and skips every other line.
    public init(parsing text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "foreground": foreground = Self.color(value)
            case "background": background = Self.color(value)
            case "cursor-color": cursor = Self.color(value)
            case "cursor-text": cursorText = Self.color(value)
            case "selection-background": selectionBackground = Self.color(value)
            case "selection-foreground": selectionForeground = Self.color(value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let index = Int(parts[0]), (0..<256).contains(index), let color = Self.color(parts[1]) {
                    palette[index] = color
                }
            default: continue
            }
        }
    }

    /// color is `#rrggbb` or `rrggbb` as 0xRRGGBB.
    static func color(_ value: String) -> UInt32? {
        let hex = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
        guard hex.count == 6 else { return nil }
        return UInt32(hex, radix: 16)
    }
}

/// TerminalThemes finds themes by name: the user's folder first, as ghostty looks in its user themes directory
/// before the bundled one, then the themes agterm-win ships.
public struct TerminalThemes: Sendable {
    public let userDirectory: URL
    public let bundledDirectory: URL?

    public init(userDirectory: URL, bundledDirectory: URL?) {
        self.userDirectory = userDirectory
        self.bundledDirectory = bundledDirectory
    }

    /// catalog lists every name either folder holds once, in agtermCore's order.
    public var catalog: ThemeCatalog {
        let names = [userDirectory.path, bundledDirectory?.path].compactMap { $0 }.flatMap(ThemeCatalog.names(in:))
        return ThemeCatalog(names: Array(Set(names.filter { $0 != "LICENSE" && !$0.hasPrefix(".") })))
    }

    /// theme reads `name`; nil when no folder has it, which leaves the terminal on its defaults.
    public func theme(named name: String) -> TerminalTheme? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { return nil }
        for directory in [userDirectory, bundledDirectory].compactMap({ $0 }) {
            if let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) {
                return TerminalTheme(parsing: text)
            }
        }
        return nil
    }
}

/// Appearance is what the settings choose for every terminal: a theme, or a light and a dark one that follow Windows'
/// app mode, and the font.
public struct Appearance: Codable, Equatable, Sendable {
    /// theme is the light, or only, theme; nil is the built-in colors.
    public var theme: String?
    /// darkTheme is used in dark mode while `followsSystem`.
    public var darkTheme: String?
    public var followsSystem = false
    /// fontFamily nil is Cascadia Mono, then Consolas.
    public var fontFamily: String?

    public init(theme: String? = nil, darkTheme: String? = nil, followsSystem: Bool = false, fontFamily: String? = nil) {
        self.theme = theme
        self.darkTheme = darkTheme
        self.followsSystem = followsSystem
        self.fontFamily = fontFamily
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decodeIfPresent(String.self, forKey: .theme)
        darkTheme = try container.decodeIfPresent(String.self, forKey: .darkTheme)
        followsSystem = try container.decodeIfPresent(Bool.self, forKey: .followsSystem) ?? false
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
    }

    /// activeTheme is the theme on screen in the given app mode.
    public func activeTheme(dark: Bool) -> String? {
        followsSystem && dark ? darkTheme ?? theme : theme
    }

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case both
        case unknown(String)

        public var description: String {
            switch self {
            case .both: "theme.set takes either a name or --light, not both"
            case .unknown(let name): "unknown theme: \(name)"
            }
        }
    }

    /// setting applies `theme.set`'s arguments as the macOS app does: a name or --light sets the light slot (none resets
    /// to the built-in colors), --dark sets the dark one and follows the system while both are set, `--dark none` stops
    /// following.
    public func setting(name: String?, light: String?, dark: String?, catalog: ThemeCatalog) -> Result<Appearance, Refusal> {
        let name = ThemeCatalog.resolvedName(name), light = ThemeCatalog.resolvedName(light), dark = ThemeCatalog.resolvedName(dark)
        if name != nil, light != nil { return .failure(.both) }
        let lightSlot = name ?? light
        let clearDark = dark?.lowercased() == "none"
        for theme in [lightSlot, clearDark ? nil : dark].compactMap({ $0 }) where !catalog.contains(name: theme) {
            return .failure(.unknown(theme))
        }
        var next = self
        if clearDark {
            next.darkTheme = nil
            next.followsSystem = false
            if lightSlot != nil { next.theme = lightSlot }
        } else if let dark {
            if let lightSlot { next.theme = lightSlot }
            next.darkTheme = dark
            next.followsSystem = true
        } else {
            next.theme = lightSlot
        }
        return .success(next)
    }
}
