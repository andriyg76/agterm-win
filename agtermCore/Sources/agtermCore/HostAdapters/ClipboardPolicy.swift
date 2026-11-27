import Foundation

/// One clipboard representation. Binary-safe: text stays bytes too, so a write never re-encodes it.
public struct ClipboardItem: Equatable, Sendable {
    public let mime: String
    public let data: Data

    public init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }
}

public enum ClipboardRequestKind: CaseIterable, Sendable {
    case paste, list, osc52Read, osc52Write, kittyRead, kittyWrite
}

/// Host-free decisions behind libghostty's clipboard callbacks. A missing surface or clipboard is not modeled here:
/// the callback answers those `UNSUPPORTED`.
public enum ClipboardPolicy {
    public enum ReadPlan: Equatable, Sendable {
        case unavailable
        case listOnly
        case text(list: Bool)
    }

    public static let textMime = "text/plain"
    public static let uriListMime = "text/uri-list"

    /// A file-manager copy reads as POSIX paths, like macOS. The callback gets no request kind, so the clipboard's
    /// formats are what tell that from literal `file://` text, which round-trips unchanged.
    public static func readableText(_ text: String, advertisesURIList: Bool) -> String {
        guard advertisesURIList else { return text }
        return PasteDecoder.posixPaths(fromURIList: text) ?? text
    }

    /// Reads serve text only: binary representations are never fetched from the clipboard.
    public static func readPlan(mimes: [String], list: Bool) -> ReadPlan {
        if mimes.contains(textMime) { return .text(list: list) }
        return list ? .listOnly : .unavailable
    }

    /// `text` nil still yields a zero-length item: `UNAVAILABLE` never starts a request, so an OSC 52 reader would
    /// wait for a reply that never comes.
    public static func textCompletion(text: String?, list: Bool) -> (items: [ClipboardItem], available: [String]) {
        ([ClipboardItem(mime: textMime, data: Data((text ?? "").utf8))], list && text != nil ? [textMime] : [])
    }

    /// Nil kinds complete unprompted: a paste has no permission to ask for, and a listing reads no content.
    public static func access(for kind: ClipboardRequestKind) -> ClipboardAccess? {
        switch kind {
        case .osc52Read, .kittyRead: .read
        case .osc52Write, .kittyWrite: .write
        case .paste, .list: nil
        }
    }
}

public enum PasteDecoder {
    /// posixPaths turns a `text/uri-list` of `file://` URIs into space-joined paths; nil when any line is not one.
    public static func posixPaths(fromURIList text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("file://") }) else { return nil }
        let paths = lines.compactMap { URL(string: $0)?.path }
        guard paths.count == lines.count else { return nil }
        return paths.joined(separator: " ")
    }

    /// dropPayload is what a drop inserts: the paths of a URI list, else the text itself; nil for nothing.
    public static func dropPayload(_ payload: String) -> String? {
        posixPaths(fromURIList: payload) ?? (payload.isEmpty ? nil : payload)
    }
}
