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

    /// startsAtLaunch is whether agterm starts the server as it opens.
    public static func startsAtLaunch(_ choice: ServerLaunch?) -> Bool { choice == .atLaunch }

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

    /// toggled is the menu's Start at Launch check flipped; clearing it is a choice too, so it never asks again.
    public static func toggled(_ choice: ServerLaunch?) -> ServerLaunch {
        choice == .atLaunch ? .manual : .atLaunch
    }

    public static func question(server: String) -> (title: String, text: String) {
        ("Start agterm-server in \(server) whenever agterm opens?",
         "It starts now either way. You can change this later: ☰ ▸ Start agterm-server at Launch.")
    }

    /// notStartedNotice is what the server's terminal shows until the server is started.
    public static func notStartedNotice(server: String) -> String {
        "agterm-server in \(server) is not started. Start it from ☰ ▸ New Session ▸ Start agterm-server in \(server)."
    }
}
