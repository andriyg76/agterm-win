import AgtermWinKit
import Foundation
import Testing
import agtermCore

@MainActor
struct PaletteTests {
    private func session(_ name: String, ended: Bool = false) -> Session {
        let session = Session(initialCwd: "/home/u", customName: name, remoteHost: "wsl-Ubuntu", remoteSessionID: name)
        session.ended = ended
        return session
    }

    @Test func sessionsListLocalAndServerAToZWithTheirWorkspace() {
        let api = session("api"), web = session("Web", ended: true)
        let mine = Palette.Local(id: UUID(), name: "build", exited: true, attention: false)
        let db = session("db")
        let rows = Palette.sessionRows(locals: [mine], servers: [("WSL Ubuntu", [Workspace(name: "", sessions: [web], isRoot: true),
                                                                                Workspace(name: "dev", sessions: [api])]),
                                                                 ("WSL Debian", [Workspace(name: "", sessions: [db], isRoot: true)])])
        #expect(rows.map(\.title) == ["api", "build", "db", "Web"])
        #expect(rows.map(\.subtitle) == ["WSL Ubuntu · dev", "", "WSL Debian", "WSL Ubuntu"])
        #expect(rows.map(\.detail) == ["", "exited", "", "ended"])
        #expect(rows[1].target == .session(mine.id))
    }

    @Test func aCompanionFollowsItsParentAsParentAndChild() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        // a store opens companions only for local sessions; a server's arrive already linked in its catalog
        let parent = Session(initialCwd: "/home/u", customName: "zeta"), other = Session(initialCwd: "/home/u", customName: "alpha")
        let store = AppStore(workspaces: [Workspace(name: "dev", sessions: [parent, other])], persistence: PersistenceStore(directory: directory),
                             paneFinalizer: nil, headless: true)
        guard case .success = store.addCompanion(to: parent.id, options: CompanionOptions(name: "logs", select: false)) else {
            Issue.record("addCompanion refused")
            return
        }
        let rows = Palette.sessionRows(locals: [], servers: [("WSL Ubuntu", store.workspaces)])
        #expect(rows.map(\.title) == ["alpha", "zeta", "zeta › logs"])
    }

    @Test func unseenAndAttentionMarkASession() {
        let quiet = Palette.Local(id: UUID(), name: "a", exited: false, attention: true)
        let counted = Palette.Local(id: UUID(), name: "b", exited: false, attention: true, unseen: 3)
        let server = session("c")
        let rows = Palette.sessionRows(locals: [quiet, counted], servers: [("WSL", [Workspace(name: "dev", sessions: [server])])],
                                       unseen: [server.id: 120])
        #expect(rows.map(\.detail) == ["●", "● 3", "● 99+"])
    }

    @Test func commandsAreTheWindowMenuFlattenedAToZ() {
        let profiles = [LaunchProfile(name: "Windows PowerShell", commandLine: "powershell.exe")]
        let rows = Palette.commandRows(NativeMenu.window(profiles: profiles, canCloseSession: false, sessionCount: 1, hasSelection: false,
                                                         canPaste: false))
        let titles = rows.map(\.title)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        #expect(titles.contains("New Session › Windows PowerShell") && titles.contains("Default Profile › Windows PowerShell"))
        #expect(titles.contains("Go to Session…") && !titles.contains("Command Palette…"))
        #expect(rows.first { $0.title == "Close Session" }?.enabled == false)
        #expect(rows.first { $0.title == "View › Find…" }?.detail == "Ctrl+F")
        #expect(rows.first { $0.title == "Quit" }?.target == .pick(.command(.quit)))
    }

    @Test func aBlankQueryKeepsTheOrderAndATypedOneRanks() {
        let rows = ["zeta", "api", "beta-api"].map { Palette.Row(title: $0, target: .pick(.command(.find))) }
        #expect(Palette.filter(rows, query: " \n").map(\.title) == ["zeta", "api", "beta-api"])
        #expect(Palette.filter(rows, query: "api").map(\.title) == ["api", "beta-api"])
        #expect(Palette.filter(rows, query: "zz").isEmpty)
    }

    @Test func theSubtitleIsSearchedToo() {
        let rows = [Palette.Row(title: "api", subtitle: "WSL Ubuntu · dev", target: .session(UUID())),
                    Palette.Row(title: "build", subtitle: "Local", target: .session(UUID()))]
        #expect(Palette.filter(rows, query: "local").map(\.title) == ["build"])
    }

    @Test func theHighlightStopsAtEitherEnd() {
        #expect(Palette.step(0, by: -1, count: 3) == 0)
        #expect(Palette.step(1, by: 1, count: 3) == 2)
        #expect(Palette.step(2, by: 10, count: 3) == 2)
        #expect(Palette.step(nil, by: 1, count: 0) == nil)
    }

    @Test func thePalettesAreInTheWindowMenuWithTheirChords() {
        let menu = NativeMenu.window(profiles: [], canCloseSession: false, sessionCount: 0, hasSelection: false, canPaste: false)
        #expect(menu.first { $0.pick == .command(.sessionPalette) }?.shortcut == "Ctrl+P")
        #expect(menu.first { $0.pick == .command(.commandPalette) }?.shortcut == "Ctrl+Shift+P")
        #expect(menu.first { $0.pick == .command(.attentionPalette) }?.shortcut == "Ctrl+Alt+I")
    }

    @Test func attentionOmitsIdleAndSortsByStatusThenRecency() {
        let time = Date(timeIntervalSince1970: 100)
        let rows = Palette.attentionRows([
            (UUID(), "idle", "", .idle, time),
            (UUID(), "old blocked", "", .blocked, nil),
            (UUID(), "active", "", .active, time),
            (UUID(), "new blocked", "", .blocked, time),
            (UUID(), "completed", "", .completed, time),
        ])
        #expect(rows.map(\.title) == ["new blocked", "old blocked", "active", "completed"])
    }
}
