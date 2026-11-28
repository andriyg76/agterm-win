import Foundation

/// Windows package identity: agterm-win's own version and the upstream agterm release it is locked to.
public struct AppBuildInfo: Codable, Equatable, Sendable {
    public let version: String
    public let agtermVersion: String?
    public let buildDate: String?
    public let branch: String?
    public let pullRequest: Int?

    public init(version: String, agtermVersion: String?, buildDate: String?, branch: String? = nil, pullRequest: Int? = nil) {
        self.version = version
        self.agtermVersion = agtermVersion
        self.buildDate = buildDate
        self.branch = branch
        self.pullRequest = pullRequest
    }

    public var aboutText: String {
        var lines = ["agterm for Windows", "Version \(version)" + (agtermVersion.map { " (agterm \($0))" } ?? "")]
        if let buildDate { lines.append("Built \(buildDate)") }
        if let branch { lines.append("Branch \(branch)") }
        if let pullRequest { lines.append("PR #\(pullRequest)") }
        return lines.joined(separator: "\n")
    }
}
