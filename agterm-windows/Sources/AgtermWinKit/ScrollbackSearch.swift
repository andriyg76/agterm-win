/// ScrollbackSearch finds text in a terminal's lines (scrollback, then screen), ignoring case. A line is its cells'
/// runes as `TerminalLink.row` reads them, so a match is reported in cells, the unit selection and drawing use.
public enum ScrollbackSearch {
    public struct Match: Equatable, Sendable {
        public let line: Int
        public let column: Int
        /// cells is how many cells the match covers, wide characters counting two.
        public let cells: Int

        public init(line: Int, column: Int, cells: Int) {
            self.line = line
            self.column = column
            self.cells = cells
        }
    }

    /// find looks from `after` (exclusive) toward older lines when `backward`, newer otherwise, wrapping around; with no
    /// `after` it starts past the newest line, so the first backward match is the newest one.
    public static func find(_ needle: String, lineCount: Int, line: (Int) -> [UInt32], after: Match?, backward: Bool) -> Match? {
        let wanted = Array(needle.lowercased())
        guard !wanted.isEmpty, lineCount > 0 else { return nil }
        let startLine = after?.line ?? (backward ? lineCount : -1)
        for step in 0...lineCount {
            let index = ((startLine + (backward ? -step : step)) % lineCount + lineCount) % lineCount
            if step == 0, after == nil { continue }
            let matches = matchesIn(line(index), wanted: wanted, line: index)
            let candidates: [Match]
            if step == 0, let after {
                candidates = matches.filter { backward ? $0.column < after.column : $0.column > after.column }
            } else if step == lineCount, let after {
                candidates = matches.filter { backward ? $0.column >= after.column : $0.column <= after.column }
            } else {
                candidates = matches
            }
            if let found = backward ? candidates.last : candidates.first { return found }
        }
        return nil
    }

    private static func matchesIn(_ runes: [UInt32], wanted: [Character], line: Int) -> [Match] {
        var characters: [Character] = [], cells: [Int] = []
        for (cell, rune) in runes.enumerated() where rune != TerminalLink.wideTail {
            characters.append(Character(Unicode.Scalar(rune).flatMap { $0 == "\0" ? nil : $0 } ?? " ").lowercased().first ?? " ")
            cells.append(cell)
        }
        guard characters.count >= wanted.count else { return [] }
        return (0...(characters.count - wanted.count)).compactMap { start in
            guard Array(characters[start..<start + wanted.count]) == wanted else { return nil }
            let end = start + wanted.count
            let endCell = end < cells.count ? cells[end] : runes.count
            return Match(line: line, column: cells[start], cells: endCell - cells[start])
        }
    }
}
