/// The confirmation texts for deleting a workspace or a window, as macOS words them.
public enum DeletePrompt {
    public static func workspaceMessage(name: String, sessions: Int) -> String {
        let sessionClause = sessions == 1 ? "1 session" : "\(sessions) sessions"
        return "Delete “\(name)” and its \(sessionClause)? This can't be undone."
    }

    public static func windowMessage(name: String) -> String {
        "Delete the window “\(name)” and all its workspaces and sessions? This can't be undone."
    }
}
