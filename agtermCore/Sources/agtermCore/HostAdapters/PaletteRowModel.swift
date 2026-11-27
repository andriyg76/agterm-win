/// One command-palette row split into the fields a host renders separately (title | badge | shortcut), as macOS's
/// multi-field `PaletteItem` does. The shortcut renders in kitty syntax, which is what `keymap.conf` holds.
public struct PaletteRowModel: Equatable, Sendable {
    public let title: String
    /// The current keybind (`ctrl+shift+t`); nil when unbound.
    public let shortcut: String?
    /// A trailing pill, `custom` for a keymap command; nil for catalog rows.
    public let badge: String?
    public let indicator: AgentIndicator?
    public let enabled: Bool

    public init(title: String, shortcut: String? = nil, badge: String? = nil, indicator: AgentIndicator? = nil,
                enabled: Bool = true) {
        self.title = title
        self.shortcut = shortcut
        self.badge = badge
        self.indicator = indicator
        self.enabled = enabled
    }

    /// The keys `fuzzyRank` scores: the title, plus one composite of every visible field when there is more than
    /// a title. Not one key per field: `fuzzyScore` needs every query term to match the same key, so a cross-field
    /// query would match nothing, and a prefix scores 0, so a bare chord key would tie every `c…` query.
    public var searchKeys: [String] {
        guard shortcut != nil || badge != nil else { return [title] }
        return [title, [title, badge, shortcut].compactMap { $0 }.joined(separator: " ")]
    }

    /// A catalog command as the current state presents it; the context flips titles such as `Unflag Session`.
    /// A server window offers Reopen Closed from its origin's history, which the shared catalog disables.
    public static func action(_ command: PaletteCommand, in context: PaletteContext, chord: Chord?) -> PaletteRowModel {
        let enabled = if command == .reopenRecent, context.remoteWindow {
            context.remoteConnected && context.hasRecentClosed && !context.modalActive
        } else {
            command.isEnabled(in: context)
        }
        return PaletteRowModel(title: command.title(in: context), shortcut: chord?.displayString, enabled: enabled)
    }

    public static func window(name: String, isOpen: Bool) -> PaletteRowModel {
        PaletteRowModel(title: "\(isOpen ? "Switch to" : "Open") Window: \(name)")
    }

    /// A `keymap.conf` custom command with its raw keybind token; a blank one reads as unbound.
    public static func custom(_ command: CustomCommand) -> PaletteRowModel {
        PaletteRowModel(title: command.name, shortcut: command.shortcut.trimmedOrNil, badge: "custom")
    }

    /// rank orders rows for `query`. The attention palette's input order is its ranking (blocked first), so with
    /// nothing typed it is kept rather than re-sorted by title, as macOS does.
    public static func rank<Item>(_ items: [Item], query: String, preservesNaturalOrder: Bool,
                                  row: (Item) -> PaletteRowModel) -> [Item] {
        if preservesNaturalOrder, query.allSatisfy(\.isWhitespace) { return items }
        return fuzzyRank(query: query, items: items, keys: { row($0).searchKeys })
    }
}
