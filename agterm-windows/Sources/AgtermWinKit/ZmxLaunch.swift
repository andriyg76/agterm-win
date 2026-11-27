import Foundation
import agtermCore

/// ZmxLaunch is the Windows side of macOS `ZmxLaunch`: whether a local pane starts under a zmx daemon named from its pane
/// identity, and the attach line it starts with. The profile command line, with its shell integration, is the create-only
/// payload, so a surviving daemon keeps the program it already runs.
public struct ZmxLaunch: Sendable {
    public let executablePath: String
    public let stateDirectory: String
    public let decision: RestoreLaunchDecision

    /// `requested` is the saved mode; Live falls back to fresh shells while `executablePath` cannot be configured.
    public init(executablePath: String, stateDirectory: String, requested: RestoreMode) {
        self.executablePath = executablePath
        self.stateDirectory = stateDirectory
        let reason = Self.unavailableReason(executablePath: executablePath, stateDirectory: stateDirectory)
        decision = requested.launchDecision(liveUnavailableReason: reason)
    }

    public var socketDirectory: String { ZmxSupport.socketDirectory(forStateDirectory: stateDirectory) }

    public struct Start: Equatable, Sendable {
        public let commandLine: String
        public let environment: [String: String]
        public let daemonName: String
    }

    /// start is how pane `paneIdentity` starts `commandLine`: through zmx while Live is active, nil for a plain start.
    public func start(_ commandLine: String, paneIdentity: UUID, environment: [String: String]) -> Start? {
        guard decision.active == .live,
              case .success(let configuration) = ZmxSupport.configuration(for: inputs(paneIdentity, environment)) else { return nil }
        let line = ZmxSupport.attachCommand(configuration, replaying: nil, paneCommand: ShellIntegration.commandLine(commandLine),
                                            denylist: [])
        return Start(commandLine: line, environment: configuration.environment, daemonName: configuration.daemonName)
    }

    private func inputs(_ paneIdentity: UUID, _ environment: [String: String]) -> ZmxSupport.Inputs {
        ZmxSupport.Inputs(zmxExecutablePath: executablePath, passwordDatabaseShell: nil, resourcesDirectory: nil,
                          stateDirectory: stateDirectory, paneIdentity: paneIdentity, baseEnvironment: environment, inheritedZdotdir: nil)
    }

    static func unavailableReason(executablePath: String, stateDirectory: String) -> String? {
        let probe = ZmxSupport.Inputs(zmxExecutablePath: executablePath, passwordDatabaseShell: nil, resourcesDirectory: nil,
                                      stateDirectory: stateDirectory, paneIdentity: UUID(), baseEnvironment: [:], inheritedZdotdir: nil)
        return switch ZmxSupport.configuration(for: probe) {
        case .success: nil
        case .failure(let rejection): rejection.message
        }
    }
}
