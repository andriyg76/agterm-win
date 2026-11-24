import Foundation

/// ControlWSLServer is one WSL distribution's agterm-server as agterm for Windows reports it.
public struct ControlWSLServer: Codable, Sendable, Equatable {
    public let distribution: String
    /// started is whether the server was started this launch; connected whether its catalog is up now.
    public let started: Bool
    public let connected: Bool
    /// launch is `atLaunch` or `manual`, the user's choice; omitted while none is made, when the next start from
    /// the menu asks.
    public let launch: String?

    public init(distribution: String, started: Bool, connected: Bool, launch: String?) {
        self.distribution = distribution
        self.started = started
        self.connected = connected
        self.launch = launch
    }
}

/// ControlWSL parses the `wsl.*` commands, which only agterm for Windows serves.
public enum ControlWSL {
    public enum Request: Equatable, Sendable {
        case list
        case start(String)
        /// launch sets whether the distribution's server starts as agterm opens; off is a choice that never asks.
        case launch(String, Bool)
    }

    public struct Rejection: Error, Equatable, Sendable {
        public let message: String
    }

    public static func parse(_ request: ControlRequest) -> Result<Request, Rejection> {
        switch request.cmd {
        case .wslList:
            return .success(.list)
        case .wslStart, .wslLaunch:
            guard let name = request.args?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                return .failure(Rejection(message: "\(request.cmd.rawValue) requires a distribution"))
            }
            guard request.cmd == .wslLaunch else { return .success(.start(name)) }
            switch request.args?.mode {
            case "on": return .success(.launch(name, true))
            case "off": return .success(.launch(name, false))
            default: return .failure(Rejection(message: "wsl.launch requires on or off"))
            }
        default:
            return .failure(Rejection(message: "\(request.cmd.rawValue) is not a wsl command"))
        }
    }

    /// refusal is what a Mac and agterm-server answer: they have no WSL.
    public static func refusal(_ command: Command) -> String {
        "\(command.rawValue) is only available in agterm for Windows"
    }
}
