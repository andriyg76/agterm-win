import AgtermWinKit
import Foundation
import Testing
import agtermCore

private final class Terminal {}

@MainActor
struct NativeEventsTests {
    private let run = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let primary = Terminal()
    private let split = Terminal()

    private func store(_ events: NativeEvents, window: UUID = LocalWindow.id) -> AppStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-events-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: directory, fileName: "window.json"),
                             controlEventSink: events.sink(window: window), paneFinalizer: nil)
        store.ensureRoot()
        return store
    }

    private func read(_ events: NativeEvents, _ store: AppStore, _ args: ControlArgs? = nil) async -> ControlResponse {
        await ControlDispatcher(actions: NativeStructure(store: store, events: events)).dispatch(ControlRequest(cmd: .eventsRead, args: args))!
    }

    private func items(_ events: NativeEvents, _ store: AppStore, kinds: [String]? = nil) async -> [ControlEvent] {
        await read(events, store, ControlArgs(after: "0", run: run.uuidString, kinds: kinds, limit: 1_000)).result?.events?.items ?? []
    }

    private func pane(_ status: AgentStatus = .idle, split splitShown: Bool = false, scratch: Bool = false,
                      right: Bool = false) -> NativeEvents.Pane {
        NativeEvents.Pane(indicator: AgentIndicator(status: status), splitShown: splitShown, scratchShown: scratch,
                          focusedPane: right ? .right : .left, focusedTerminal: ObjectIdentifier(right ? split : primary))
    }

    @Test func aReadWithoutACursorAnchorsAtTheTail() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        events.launched()
        let reply = await read(events, store)
        #expect(reply.ok && reply.result?.events == ControlEventBatch(run: run, next: 1, items: []))
        #expect(await items(events, store).map(\.kind) == [.appLaunched])
    }

    @Test func nothingIsRecordedBeforeLaunchAndLaunchRecordsOnce() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        _ = store.addSession(toWorkspace: store.rootWorkspace!.id, cwd: "", command: "cmd.exe", select: true)
        events.launched()
        events.launched()
        #expect(await items(events, store).map(\.kind) == [.appLaunched])
    }

    @Test func storeEventsCarryTheirWindowAndTreeChangesFold() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        events.launched()
        let first = store.addSession(toWorkspace: store.rootWorkspace!.id, cwd: "", command: "cmd.exe", select: true)!
        _ = store.addSession(toWorkspace: store.rootWorkspace!.id, cwd: "", command: "cmd.exe", select: false)
        store.closeSession(first.id)
        let recorded = await items(events, store)
        #expect(recorded.filter { $0.kind == .sessionCreated }.count == 2)
        #expect(recorded.contains { $0.kind == .sessionSelected && $0.session == first.id.uuidString })
        #expect(recorded.contains { $0.kind == .sessionClosed && $0.session == first.id.uuidString })
        #expect(recorded.filter { $0.kind == .treeChanged }.count == 1)
        #expect(recorded.filter { $0.kind != .appLaunched }.allSatisfy { $0.window == LocalWindow.id.uuidString })
    }

    @Test func aNotificationRecordedByTheStoreIsANotifyEvent() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        let session = store.addSession(toWorkspace: store.rootWorkspace!.id, cwd: "", command: "cmd.exe", name: "build", select: false)!
        events.launched()
        store.recordNotificationEvent(forSession: session.id, title: "", body: "done")
        let notify = await items(events, store, kinds: ["notify"])
        #expect(notify.map(\.payload.title) == ["build"] && notify.map(\.payload.body) == ["done"])
    }

    @Test func syncReportsStatusAndPanesAsTheyChange() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        let id = store.addSession(toWorkspace: store.rootWorkspace!.id, cwd: "", command: "cmd.exe", select: false)!.id
        events.launched()
        events.sync([(id: id, name: "pwsh", pane: pane())], store: store)
        events.sync([(id: id, name: "pwsh", pane: pane(.completed))], store: store)
        events.sync([(id: id, name: "pwsh", pane: pane(.completed, split: true, right: true))], store: store)
        events.sync([(id: id, name: "pwsh", pane: pane(.completed, split: true, scratch: true, right: true))], store: store)
        let recorded = await items(events, store).filter { $0.kind != .appLaunched }
        #expect(recorded.map(\.kind) == [.status, .paneSplit, .paneFocused, .paneScratch])
        #expect(recorded[0].payload.status == "completed" && recorded[0].payload.previous == "idle" && recorded[0].payload.name == "pwsh")
        #expect(recorded[0].session == id.uuidString && recorded[0].workspace == store.rootWorkspace!.id.uuidString)
        #expect(recorded[1].payload.status == "shown" && recorded[2].payload.pane == "right" && recorded[3].payload.status == "shown")
    }

    @Test func aSwapAndANewOrGoneSessionRecordNothing() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        let id = UUID()
        events.launched()
        events.sync([(id: id, name: "pwsh", pane: pane(.active))], store: store)
        let swapped = NativeEvents.Pane(indicator: AgentIndicator(status: .active), splitShown: false, scratchShown: false,
                                        focusedPane: .right, focusedTerminal: ObjectIdentifier(primary))
        events.sync([(id: id, name: "pwsh", pane: swapped)], store: store)
        events.sync([], store: store)
        events.sync([(id: id, name: "pwsh", pane: pane(.blocked))], store: store)
        #expect(await items(events, store).map(\.kind) == [.appLaunched])
    }

    @Test func theLocalStoresOwnStatusAndPaneEventsAreLeftToSync() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let local = store(events)
        let remoteWindow = NativeControl.remoteWindowID("Ubuntu")
        let remote = store(events, window: remoteWindow)
        let localID = local.addSession(toWorkspace: local.rootWorkspace!.id, cwd: "", command: "cmd.exe", select: false)!.id
        let remoteID = remote.addSession(toWorkspace: remote.rootWorkspace!.id, cwd: "", command: "bash", select: false)!.id
        events.launched()
        local.setAgentIndicator(AgentIndicator(status: .completed), forSession: localID)
        remote.setAgentIndicator(AgentIndicator(status: .completed), forSession: remoteID)
        let status = await items(events, local, kinds: ["status"])
        #expect(status.map(\.session) == [remoteID.uuidString] && status.map(\.window) == [remoteWindow.uuidString])
    }

    @Test func pagingAndKindsFollowTheCursor() async {
        let events = NativeEvents(ring: ControlEventRing(runID: run))
        let store = store(events)
        let id = UUID()
        events.launched()
        events.sync([(id: id, name: "pwsh", pane: pane())], store: store)
        for status in [AgentStatus.active, .blocked, .completed] {
            events.sync([(id: id, name: "pwsh", pane: pane(status))], store: store)
        }
        let page = await read(events, store, ControlArgs(after: "0", run: run.uuidString, limit: 2)).result?.events
        #expect(page?.items.map(\.seq) == [1, 2] && page?.next == 2)
        let rest = await read(events, store, ControlArgs(after: "2", run: run.uuidString, kinds: ["status"])).result?.events
        #expect(rest?.items.compactMap(\.payload.status) == ["blocked", "completed"] && rest?.next == 4)
    }

    @Test func aCursorThatCannotResumeIsRefusedWithTheAnchor() async {
        let events = NativeEvents(ring: ControlEventRing(capacity: 2, runID: run))
        let store = store(events)
        let id = UUID()
        events.launched()
        events.sync([(id: id, name: "pwsh", pane: pane())], store: store)
        for status in [AgentStatus.active, .blocked, .completed] {
            events.sync([(id: id, name: "pwsh", pane: pane(status))], store: store)
        }
        let anchor = ControlEventBatch(run: run, next: 4, items: [])
        let other = await read(events, store, ControlArgs(after: "1", run: UUID().uuidString))
        #expect(!other.ok && other.error == "event run changed" && other.result?.events == anchor)
        let expired = await read(events, store, ControlArgs(after: "0", run: run.uuidString))
        #expect(expired.error == "event cursor expired" && expired.result?.events == anchor)
        let ahead = await read(events, store, ControlArgs(after: "9", run: run.uuidString))
        #expect(ahead.error == "event cursor is ahead of the current sequence")
        #expect(await read(events, store, ControlArgs(kinds: ["bogus"])).error == "invalid event kind: bogus")
    }
}
