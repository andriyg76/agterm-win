import Foundation
import agtermCore

/// ZmxClient runs the zmx commands agterm-win needs against its own socket directory, as macOS `ZmxClient` does. The
/// runner is the window's: a console program needs a hidden window on Windows, which only the Win32 target can give.
@MainActor
public struct ZmxClient {
    public struct Invocation: Equatable, Sendable {
        public let arguments: [String]
        public let environment: [String: String]
        /// mergesStderr is for kill, whose verdict zmx prints there; list must not read stderr notices as rows.
        public let mergesStderr: Bool
    }

    /// Runner answers the exit status and output, nil when zmx could not start or overran its time.
    public typealias Runner = @MainActor (_ executablePath: String, _ invocation: Invocation) -> (status: Int32, output: String)?

    public let executablePath: String
    public let socketDirectory: String
    private let runner: Runner
    private let log: @MainActor (String) -> Void

    public init(executablePath: String, socketDirectory: String, runner: @escaping Runner,
                log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.executablePath = executablePath
        self.socketDirectory = socketDirectory
        self.runner = runner
        self.log = log
    }

    public var endpoint: ControlZmxEndpoint { ControlZmxEndpoint(executable: executablePath, socketDirectory: socketDirectory) }

    /// listSessions is the parsed listing; nil when it could not be read, which is not the empty namespace.
    public func listSessions() -> [ZmxSessionRecord]? {
        guard let output = invoke(["list"]) else { return nil }
        do {
            return try ZmxListParser.parse(output)
        } catch {
            log("zmx: list output was incomplete: \(error)")
            return nil
        }
    }

    /// reap is the launch reap by requested mode, `ZmxReapPolicy`'s: a deliberate Fresh shells or Re-run launch ends
    /// every detached app daemon, a Live one only those no saved pane claims. False when something could not be done.
    @discardableResult
    public func reap(knownPaneIdentities: Set<UUID>?, decision: RestoreLaunchDecision) -> Bool {
        if decision.requested == .live, knownPaneIdentities == nil {
            log("zmx: skipping the live reap because the saved pane inventory is incomplete")
            return true
        }
        guard let sessions = listSessions() else { return false }
        let known = knownPaneIdentities.map { Set($0.map(ZmxSupport.localDaemonName(for:))) }
        guard let names = ZmxReapPolicy.namesToKill(sessions: sessions, requestedMode: decision.requested, knownNames: known) else {
            return true
        }
        log("zmx: launch reap (\(decision.requested.rawValue)) ends \(names.count) daemon(s)")
        return kill(names: names)
    }

    /// kill force-kills every name in one call; semantic deletion has already taken the panes out of the model.
    @discardableResult
    public func kill(paneIdentities: [UUID]) -> Bool {
        kill(names: paneIdentities.map(ZmxSupport.localDaemonName(for:)))
    }

    func kill(names: [String]) -> Bool {
        var seen: Set<String> = []
        let unique = names.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return true }
        return invoke(["kill"] + unique + ["--force"], mergesStderr: true) != nil
    }

    /// killConfirmed force-kills one daemon and reports what zmx did: it exits zero after only unlinking a socket it
    /// could not reach, so a caller closing a live pane on this answer needs more than the status.
    public func killConfirmed(name: String) -> ZmxKillOutcome {
        guard let output = invoke(["kill", name, "--force"], mergesStderr: true) else { return .failed("zmx kill failed") }
        return ZmxKillOutcome.parse(output, name: name)
    }

    /// killObservedOrphan kills each name without `--force`, one call apiece, so prune reports per daemon.
    public func killObservedOrphan(names: [String]) -> [String: ZmxKillOutcome] {
        var outcomes: [String: ZmxKillOutcome] = [:]
        for name in Set(names) {
            outcomes[name] = invoke(["kill", name], mergesStderr: true).map { ZmxKillOutcome.parse($0, name: name) }
                ?? .failed("zmx kill failed")
        }
        return outcomes
    }

    /// screen is the daemon's own grid for `name`; nil when the read failed.
    public func screen(name: String, all: Bool) -> ZmxScreen? {
        invoke(["screen", name] + (all ? ["--all"] : [])).flatMap(ZmxScreen.init(output:))
    }

    func invocation(_ arguments: [String], mergesStderr: Bool = false) -> Invocation {
        var environment = ProcessInfo.processInfo.environment
        environment["ZMX_DIR"] = socketDirectory
        environment.removeValue(forKey: "ZMX_SESSION")
        environment.removeValue(forKey: "ZMX_SESSION_PREFIX")
        return Invocation(arguments: arguments, environment: environment, mergesStderr: mergesStderr)
    }

    private func invoke(_ arguments: [String], mergesStderr: Bool = false) -> String? {
        let invocation = invocation(arguments, mergesStderr: mergesStderr)
        guard let result = runner(executablePath, invocation) else {
            log("zmx: \(arguments.first ?? "") did not finish")
            return nil
        }
        log("zmx: \(arguments.joined(separator: " ")) exited \(result.status)")
        guard result.status == 0 else { return nil }
        return result.output
    }
}
