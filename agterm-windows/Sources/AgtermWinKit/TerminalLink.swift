/// TerminalLink finds the web address under a click in a terminal row. Only http and https open: a file or other
/// scheme handed to the shell could run a program.
public enum TerminalLink {
    /// row turns a row's cells into text: `runes` holds one value a cell, 0 for a blank cell and `wideTail` for the
    /// second cell of a wide character. It gives the text and the character index of cell `column`.
    public static let wideTail = UInt32.max

    public static func row(_ runes: [UInt32], column: Int) -> (text: [Character], index: Int) {
        var text: [Character] = []
        var index = 0
        for (cell, rune) in runes.enumerated() {
            if rune == wideTail {
                continue
            }
            if cell <= column { index = text.count }
            text.append(Character(Unicode.Scalar(rune).flatMap { $0 == "\0" ? nil : $0 } ?? " "))
        }
        return (text, index)
    }

    /// url is the address whose characters include `index`, with `www.` given https and closing punctuation trimmed.
    public static func url(in text: [Character], at index: Int) -> String? {
        guard text.indices.contains(index), !separates(text[index]) else { return nil }
        var start = index, end = index
        while start > 0, !separates(text[start - 1]) { start -= 1 }
        while end + 1 < text.count, !separates(text[end + 1]) { end += 1 }
        var word = String(text[start...end])
        guard let scheme = ["https://", "http://", "www."].first(where: { word.lowercased().contains($0) }),
              let found = word.lowercased().range(of: scheme) else { return nil }
        let offset = word.distance(from: word.startIndex, to: found.lowerBound)
        guard start + offset <= index else { return nil }
        word = String(word.dropFirst(offset))
        while let last = word.last, ".,;:!?'\"".contains(last) || closesUnopened(last, in: word) { word.removeLast() }
        guard word.count > scheme.count, start + offset + word.count > index else { return nil }
        return scheme == "www." ? "https://" + word : word
    }

    private static func separates(_ character: Character) -> Bool {
        character.isWhitespace || "<>\"`{}|\\^".contains(character)
    }

    private static func closesUnopened(_ character: Character, in word: String) -> Bool {
        let pairs: [Character: Character] = [")": "(", "]": "["]
        guard let opening = pairs[character] else { return false }
        return word.filter { $0 == character }.count > word.filter { $0 == opening }.count
    }
}
