/// SettingsTab names the Settings tab `settings.open` shows, a Windows-only command.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case appearance
    case notifications

    /// parse reads a tab name, ignoring case; no name is General, an unknown one nil.
    public static func parse(_ name: String?) -> SettingsTab? {
        guard let name, !name.isEmpty else { return .general }
        return SettingsTab(rawValue: name.lowercased())
    }

    public static var acceptedNames: String { allCases.map(\.rawValue).joined(separator: "|") }
}
