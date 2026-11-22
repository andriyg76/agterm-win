import AgtermWinKit
import Foundation
import Testing
import agtermCore

@MainActor
struct SessionSidebarTests {
    private func session(_ name: String, ended: Bool = false, command: String? = nil) -> Session {
        let session = Session(initialCwd: "/home/u", customName: name, remoteHost: "wsl-Ubuntu", remoteSessionID: name)
        session.ended = ended
        session.initialCommand = command
        return session
    }

    @Test func workspacesHoldTheirSessionsInOrder() {
        let api = session("api"), web = session("web", ended: true)
        let items = SessionSidebar.items([Workspace(name: "dev", sessions: [api, web]), Workspace(name: "empty")])
        #expect(items.map(\.title) == ["dev", "empty"])
        #expect(items[0].isWorkspace)
        #expect(items[0].children.map(\.title) == ["api", "web (ended)"])
        #expect(items[0].children.map(\.ended) == [false, true])
        #expect(items[1].children.isEmpty)
    }

    @Test func selectionKeepsAPresentSessionAndOtherwiseTakesTheFirstLiveOne() {
        let gone = session("gone", ended: true), live = session("live")
        let workspaces = [Workspace(name: "a", sessions: [gone]), Workspace(name: "b", sessions: [live])]
        #expect(SessionSidebar.selection(current: gone.id, in: workspaces) == gone.id)
        #expect(SessionSidebar.selection(current: UUID(), in: workspaces) == live.id)
        #expect(SessionSidebar.selection(current: nil, in: workspaces) == live.id)
        #expect(SessionSidebar.selection(current: nil, in: [Workspace(name: "a", sessions: [gone])]) == nil)
    }

    @Test func launchRunsTheAttachCommand() {
        #expect(SessionSidebar.launch(for: session("a", command: "wsl.exe -e zmx attach a"), hostLabel: "WSL Ubuntu")
            == .command("wsl.exe -e zmx attach a"))
    }

    @Test func launchShowsANoticeForTheEndedPlaceholderOrNoPane() {
        let ended = session("a", ended: true, command: RemoteSession.endedCommand(host: "wsl-Ubuntu"))
        #expect(SessionSidebar.launch(for: ended, hostLabel: "WSL Ubuntu") == .notice("Ended on WSL Ubuntu"))
        #expect(SessionSidebar.launch(for: session("b"), hostLabel: "WSL Ubuntu") == .notice("no pane to attach"))
    }
}
