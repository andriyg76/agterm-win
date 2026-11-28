import agtermCore

/// TintChoice is one Tint submenu pick: a palette color (nil clears), the row's own custom hex, or where the color shows.
public enum TintChoice: Hashable, Sendable {
    case color(TintColor?)
    case custom
    case parts(Set<TintPart>)

    var offset: Int {
        switch self {
        case .color(nil): 0
        case .color(let color?): 1 + (TintColor.allCases.firstIndex(of: color) ?? 0)
        case .custom: 50
        case .parts(let parts): 100 + TintPart.allCases.enumerated().reduce(0) { parts.contains($1.element) ? $0 | 1 << $1.offset : $0 }
        }
    }

    init?(offset: Int) {
        let parts = Set(TintPart.allCases.enumerated().filter { (offset - 100) & 1 << $0.offset != 0 }.map(\.element))
        switch offset {
        case 0: self = .color(nil)
        case 1...TintColor.allCases.count: self = .color(TintColor.allCases[offset - 1])
        case 50: self = .custom
        case 101..<(100 + 1 << TintPart.allCases.count): self = .parts(parts)
        default: return nil
        }
    }

    /// applied is the tint a row with `current` gets, the Mac menu's rule: a color keeps a tinted row's parts and
    /// starts an untinted one on `placement`; Show On moves a tinted row's color and leaves an untinted one alone.
    public func applied(to current: SidebarTint?, startingOn placement: Set<TintPart>) -> SidebarTint? {
        switch self {
        case .color(let color): color.map { SidebarTint.recolor(current, to: .named($0), startingOn: placement) }
        case .custom: current
        case .parts(let parts): SidebarTint.place(current, on: parts)
        }
    }
}

extension NativeMenu {
    /// tint is the Mac's Tint submenu for the structure's targets: None, the palette with swatches and a row's own hex,
    /// then Show On, which acts only on tinted rows; an entry is checked only when every target shares it.
    static func tint(_ structure: Structure) -> [Entry] {
        guard let current = structure.tints else { return [] }
        func choice(_ title: String, _ pick: TintChoice, checked: Bool, swatch: TintValue? = nil, enabled: Bool = true) -> Entry {
            var entry = Entry(title: title, shortcut: "", pick: .tint(pick), enabled: enabled, children: [])
            entry.checked = checked
            entry.swatch = swatch
            return entry
        }
        let colors = Set(current.map { $0?.color })
        var entries = [choice("None", .color(nil), checked: colors == [nil])]
        entries += TintColor.allCases.map { choice($0.rawValue.capitalized, .color($0), checked: colors == [.named($0)], swatch: .named($0)) }
        if colors.count == 1, case let .hex(hex)?? = colors.first {
            entries.append(choice("Custom \(hex)", .custom, checked: true, swatch: .hex(hex)))
        }
        let tinted = current.allSatisfy { $0 != nil }
        let placements = Set(current.map { $0.map { Set($0.parts) } ?? structure.tintPlacement })
        let options: [(String, Set<TintPart>)] = [("Icon", [.icon]), ("Name", [.name]), ("Icon and Name", [.icon, .name])]
        entries += [.separator, Entry(title: "Show On", shortcut: "", pick: nil, enabled: false, children: [])]
            + options.map { choice($0.0, .parts($0.1), checked: placements == [$0.1], enabled: tinted) }
        return [Entry(title: "Tint", shortcut: "", pick: nil, enabled: structure.canTint, children: entries)]
    }

    /// sessionTints are the Mac palette's "Tint Session: <color>" entries and None, for the selected session.
    public static func sessionTints(enabled: Bool) -> [Entry] {
        ([TintColor?](TintColor.allCases) + [nil]).map { color in
            Entry(title: "Tint Session: \(color?.rawValue.capitalized ?? "None")", shortcut: "", pick: .tint(.color(color)), enabled: enabled,
                  children: [])
        }
    }
}

extension TintValue {
    /// rgb is the color as 0xRRGGBB. A name takes the macOS system color of that name for the light or dark chrome, so
    /// a row tinted on a Mac reads the same here; a hex is fixed.
    public func rgb(dark: Bool) -> UInt32 {
        switch self {
        case .hex(let hex): UInt32(hex.dropFirst(), radix: 16) ?? 0
        case .named(let color):
            switch color {
            case .red: dark ? 0xFF453A : 0xFF3B30
            case .orange: dark ? 0xFF9F0A : 0xFF9500
            case .yellow: dark ? 0xFFD60A : 0xFFCC00
            case .green: dark ? 0x30D158 : 0x34C759
            case .blue: dark ? 0x0A84FF : 0x007AFF
            case .purple: dark ? 0xBF5AF2 : 0xAF52DE
            case .gray: dark ? 0x98989D : 0x8E8E93
            case .teal: dark ? 0x40C8E0 : 0x30B0C7
            case .pink: dark ? 0xFF375F : 0xFF2D55
            case .brown: dark ? 0xAC8E68 : 0xA2845E
            case .indigo: dark ? 0x5E5CE6 : 0x5856D6
            case .mint: dark ? 0x63E6E2 : 0x00C7BE
            }
        }
    }
}
