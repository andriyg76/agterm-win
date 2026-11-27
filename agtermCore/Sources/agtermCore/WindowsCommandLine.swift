/// WindowsCommandLine quotes arguments the way CommandLineToArgvW reads them.
public enum WindowsCommandLine {
    public static func quoted(_ argument: String) -> String {
        if !argument.isEmpty, !argument.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) { return argument }
        var quoted = "\""
        var backslashes = 0
        for character in argument {
            switch character {
            case "\\":
                backslashes += 1
            case "\"":
                quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            default:
                quoted += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }
}
