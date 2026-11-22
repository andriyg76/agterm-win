import Foundation

/// NativeSettings is what the native window keeps between launches, in its state directory.
public struct NativeSettings: Codable, Equatable, Sendable {
    public struct Frame: Codable, Equatable, Sendable {
        public var left, top, right, bottom: Int32

        public init(left: Int32, top: Int32, right: Int32, bottom: Int32) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    public var fontPoints: Float = NativeMenu.defaultPoints
    /// frame is the window's restored (not maximized) rectangle in screen pixels.
    public var frame: Frame?
    public var maximized = false

    public init() {}

    /// load reads `url`, falling back to the defaults for a missing or unreadable file, and for a font size out of range.
    public static func load(from url: URL) -> NativeSettings {
        guard let data = try? Data(contentsOf: url), var settings = try? JSONDecoder().decode(NativeSettings.self, from: data) else {
            return NativeSettings()
        }
        if !NativeMenu.pointRange.contains(settings.fontPoints) { settings.fontPoints = NativeMenu.defaultPoints }
        if let frame = settings.frame, frame.right <= frame.left || frame.bottom <= frame.top { settings.frame = nil }
        return settings
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // decodes a file from an older build, which lacks later fields, with their defaults
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontPoints = try container.decodeIfPresent(Float.self, forKey: .fontPoints) ?? NativeMenu.defaultPoints
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        maximized = try container.decodeIfPresent(Bool.self, forKey: .maximized) ?? false
    }
}
