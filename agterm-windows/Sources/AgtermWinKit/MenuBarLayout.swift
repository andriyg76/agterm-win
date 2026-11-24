/// MenuBarLayout is the agwinterm-style menu row in the title bar: File, View, Navigate, Help.
public enum MenuBarLayout: Sendable {
    public static let titles = ["File", "View", "Navigate", "Help"]

    /// Each label's width in unscaled client pixels, including padding (agwinterm: text + 20).
    public static func labelWidth(_ title: String, dpi: UInt32) -> Int32 {
        let scaled = { (v: Int32) in Int32((Int64(v) * Int64(dpi) + 48) / 96) }
        // Approximate: 7 px per character at 13px Segoe UI, plus 20px padding
        return scaled(Int32(title.count * 7 + 20))
    }

  /// menuSpans lays out tabs starting at `origin` until `limit`, dropping labels that would reach the right group.
    public static func menuSpans(origin: Int32, limit: Int32, dpi: UInt32) -> [(index: Int, span: TitleBar.Span)] {
        var spans: [(Int, TitleBar.Span)] = []
        var x = origin
        let gap = labelWidth(" ", dpi: dpi) / 5
        for (index, title) in titles.enumerated() {
            let width = labelWidth(title, dpi: dpi)
            if x + width > limit { break }
            spans.append((index, TitleBar.Span(left: x, right: x + width)))
            x += width + gap
        }
        return spans
    }
}