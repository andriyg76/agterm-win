import Foundation

/// Windows package identity, kept separate from the three-component upstream server version.
public struct AppBuildInfo: Codable, Equatable, Sendable {
    public let version: String
    public let buildDate: String?
    public let branch: String?
    public let pullRequest: Int?

    public init(version: String, buildDate: String?, branch: String? = nil, pullRequest: Int? = nil) {
        self.version = version.split(separator: ".").count == 3 ? "\(version).0" : version
        self.buildDate = buildDate
        self.branch = branch
        self.pullRequest = pullRequest
    }

    public var aboutText: String {
        var lines = ["agterm for Windows", "Version \(version)"]
        if let buildDate { lines.append("Built \(buildDate)") }
        if let branch { lines.append("Branch \(branch)") }
        if let pullRequest { lines.append("PR #\(pullRequest)") }
        return lines.joined(separator: "\n")
    }
}
