/// ServerLaunch is what the user chose for a WSL distribution's agterm-server when agterm opens. No choice yet means it
/// waits to be started from the menu, and the first start asks; WSL never starts on its own before that.
public enum ServerLaunch: String, Codable, Equatable, Sendable {
    /// atLaunch starts the server whenever agterm opens.
    case atLaunch
    /// manual waits for the menu and never asks again.
    case manual

    /// Answer is a button of the question the first start asks.
    public enum Answer: CaseIterable, Sendable {
        case atLaunch, notNow, neverAsk

        public var title: String {
            switch self {
            case .atLaunch: "Yes, start it at launch"
            case .notNow: "No"
            case .neverAsk: "No, and don't ask again"
            }
        }
    }

    /// asks is whether starting the server asks first: only while nothing is chosen.
    public static func asks(_ choice: ServerLaunch?) -> Bool { choice == nil }

    /// choice is what `answer` leaves chosen; No keeps nothing chosen, so the next start asks again.
    public static func choice(after answer: Answer) -> ServerLaunch? {
        switch answer {
        case .atLaunch: .atLaunch
        case .notNow: nil
        case .neverAsk: .manual
        }
    }

    /// atLaunch is the distributions whose server starts as agterm opens, A→Z.
    public static func atLaunch(_ choices: [String: ServerLaunch]) -> [String] {
        choices.filter { $0.value == .atLaunch }.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// choices is `choices` after Settings listed `listed` with `checked` ticked: a ticked one starts at launch, and one
    /// that did is unticked to manual, a choice that never asks; an untouched one keeps what it had, asking included.
    public static func choices(_ choices: [String: ServerLaunch], checked: Set<String>, listed: [String]) -> [String: ServerLaunch] {
        var result = choices
        for distribution in listed {
            if checked.contains(distribution) {
                result[distribution] = .atLaunch
            } else if result[distribution] == .atLaunch {
                result[distribution] = .manual
            }
        }
        return result
    }

    /// listed is what Settings lists: the distributions WSL has, then any chosen to start at launch that it no longer lists.
    public static func listed(available: [String], choices: [String: ServerLaunch]) -> [String] {
        available + atLaunch(choices).filter { !available.contains($0) }
    }

    public static func question(server: String) -> (title: String, text: String) {
        ("Start agterm-server in \(server) whenever agterm opens?",
         "It starts now either way. You can change this later in Settings ▸ General.")
    }

    public static let notStartedNotice = "No agterm-server is started. Start one from ☰ ▸ New Session ▸ Start agterm-server in."
}
