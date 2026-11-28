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

/// UserManagerState is what a just-booted distribution's systemd user manager answers, which a start or install needs.
public enum UserManagerState: Equatable, Sendable {
    case ready
    /// the manager runs but its bus is unreachable, as under WSLg's mount over /run/user/<uid>; waiting does not help
    case busHidden
    case notRunning
    /// wsl.exe could not run the distribution at all; neither a wait nor another install reaches it
    case unreachable
}

public enum WSLServerEnsure {
    /// The first wsl.exe call boots a stopped distribution, and its systemd user manager comes up after it, so a start or
    /// install that runs at once fails on the missing bus (#143). These bound the wait for it and the install's retries.
    public static let userManagerWait: TimeInterval = 30
    public static let busHiddenWait: TimeInterval = 5
    public static let installAttempts = 3

    /// waitsForUserManager is whether a probe `state`, `elapsed` seconds into the wait and `hiddenFor` seconds into a run
    /// of `busHidden` answers, is worth another probe.
    public static func waitsForUserManager(_ state: UserManagerState, elapsed: TimeInterval, hiddenFor: TimeInterval) -> Bool {
        switch state {
        case .ready, .unreachable: false
        case .busHidden: hiddenFor < busHiddenWait && elapsed < userManagerWait
        case .notRunning: elapsed < userManagerWait
        }
    }

    public static func waitingText(label: String, seconds: Int) -> String {
        "\(label): waiting for the systemd user manager… \(seconds) s"
    }

    public static func retryText(attempt: Int) -> String {
        "agterm-server did not install; retrying (\(attempt)/\(installAttempts))…"
    }

    /// retriesInstall is whether an install that ended with `notice` gets another attempt: a failure offering the install
    /// again does, success and exit 4 (the bus is hidden, which only a restart of the distribution fixes) do not, and
    /// neither does any failure on a distribution wsl.exe cannot run.
    public static func retriesInstall(_ notice: NoticeBar.Message?, manager: UserManagerState) -> Bool {
        manager != .unreachable && notice?.actions.contains(.install) == true
    }
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
        case 4: return "\(label): agterm-server installed, but WSLg hides the systemd user bus; restart the distribution to start it."
        default: return "\(label): install exited \(exitCode). See agterm-win.log."
        }
    }

    /// installNotice is `installOutcome` as the notice bar shows it: an error offering the install again and the log, or for
    /// exit 4 a restart of the distribution, whose user manager then starts the enabled server.
    public static func installNotice(exitCode: Int32, error: String?, label: String, source: String) -> NoticeBar.Message {
        let text = installOutcome(exitCode: exitCode, error: error, label: label)
        guard error?.isEmpty == false || (exitCode != 0 && exitCode != 3) else { return NoticeBar.Message(source: source, text: text, severity: .info) }
        if exitCode == 4, error?.isEmpty != false {
            return NoticeBar.Message(source: source, text: text, severity: .error, actions: [.restartDistribution, .openLog])
        }
        return NoticeBar.Message(source: source, text: text, severity: .error, actions: [.install, .openLog])
    }
}
