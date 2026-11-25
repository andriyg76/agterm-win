import Foundation

/// WSLServerHealth is what a probe of one distribution reported; `WSLServerEnsure` turns it into connect or install.
public enum WSLServerHealth: Equatable, Sendable {
    case distributionUnreachable(String)
    case missingInstall
    case versionUnknown(String)
    case versionMismatch(installed: String, expected: String)
    case serviceStopped(installedVersion: String)
    case ready(installedVersion: String)
}

public enum WSLServerEnsureAction: Equatable, Sendable {
    case connect
    case startServiceThenConnect
    case install(reason: String)
    case refuse(String)
}

public enum WSLServerEnsure {
    /// plan chooses the next step from a probe and the agterm release this agterm-win build ships for.
    public static func plan(health: WSLServerHealth, expectedVersion: String) -> WSLServerEnsureAction {
        switch health {
        case .distributionUnreachable(let detail):
            return .refuse("WSL distribution is not reachable: \(detail)")
        case .missingInstall:
            return .install(reason: "agterm-server is not installed in this distribution")
        case .versionUnknown(let detail):
            return .install(reason: "agterm-server did not answer (\(detail))")
        case .versionMismatch(let installed, let expected):
            return .install(reason: "agterm-server \(installed) is installed; this app needs \(expected)")
        case .serviceStopped(let version):
            if version == expectedVersion {
                return .startServiceThenConnect
            }
            return .install(reason: "agterm-server \(version) is installed but not running; upgrading to \(expectedVersion)")
        case .ready(let installed):
            if installed == expectedVersion { return .connect }
            return .install(reason: "agterm-server \(installed) is installed; this app needs \(expectedVersion)")
        }
    }

    /// summarize builds a single line for the window notice before install starts.
    public static func summarize(action: WSLServerEnsureAction, label: String) -> String {
        switch action {
        case .connect:
            return "Checking \(label)…"
        case .startServiceThenConnect:
            return "\(label): starting agterm-server…"
        case .install(let reason):
            return "\(label): \(reason). Installing…"
        case .refuse(let reason):
            return "\(label): \(reason)"
        }
    }

    /// installOutcome maps `install.sh`'s exit to a user-visible result line.
    public static func installOutcome(exitCode: Int32, error: String?, label: String) -> String {
        if let error, !error.isEmpty {
            return "\(label): install failed — \(error)"
        }
        switch exitCode {
        case 0: return "\(label): agterm-server installed."
        case 3: return "\(label): agterm-server installed; agent hooks are incomplete (run agterm-server install-hooks in WSL)."
        default: return "\(label): install exited \(exitCode). See agterm-win.log."
        }
    }

    /// installNotice is `installOutcome` as the notice bar shows it: an error offering the install again and the log.
    public static func installNotice(exitCode: Int32, error: String?, label: String, source: String) -> NoticeBar.Message {
        let text = installOutcome(exitCode: exitCode, error: error, label: label)
        guard error?.isEmpty == false || (exitCode != 0 && exitCode != 3) else { return NoticeBar.Message(source: source, text: text, severity: .info) }
        return NoticeBar.Message(source: source, text: text, severity: .error, actions: [.install, .openLog])
    }
}
