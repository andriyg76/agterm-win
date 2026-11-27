import Foundation
import Testing
@testable import agtermCore

@MainActor
@Suite struct HostPolicyTests {
    @Test func aNotificationFromTheFocusedPaneOfTheActiveAppIsNotDelivered() {
        let session = Session(initialCwd: "/tmp")
        let store = AppStore(workspaces: [Workspace(name: "w", sessions: [session])])
        let window = UUID()
        func record(focused: Bool, active: Bool) -> NotificationDelivery? {
            store.recordTerminalNotification(TerminalNotificationRecord(
                sessionID: session.id, windowID: window, pane: .split, title: "t", body: "b",
                firingIsFocused: focused, appActive: active))
        }

        #expect(record(focused: true, active: true) == nil)
        #expect(session.unseenCount == 0)
        let delivery = record(focused: false, active: true)
        #expect(delivery?.identity == TerminalNotification.identity(windowID: window, sessionID: session.id, pane: .split))
        #expect(session.unseenCount == 1)
    }

    @Test func aNotificationClickFallsBackToThePrimaryPane() {
        #expect(NotificationRevealFocus.resolve(pane: .split, sessionExists: true, hasSplit: true, coverActive: false) == .split)
        #expect(NotificationRevealFocus.resolve(pane: .split, sessionExists: true, hasSplit: false, coverActive: false) == .primary)
        #expect(NotificationRevealFocus.resolve(pane: .overlay, sessionExists: true, hasSplit: false, coverActive: false) == .primary)
        #expect(NotificationRevealFocus.resolve(pane: .main, sessionExists: false, hasSplit: false, coverActive: false) == nil)
    }

    @Test func aURIListReadsAsPathsOnlyWhenTheClipboardAdvertisesOne() {
        let list = "file:///tmp/a%20b\r\nfile:///tmp/c\n"
        #expect(ClipboardPolicy.readableText(list, advertisesURIList: true) == "/tmp/a b /tmp/c")
        #expect(ClipboardPolicy.readableText(list, advertisesURIList: false) == list)
        #expect(PasteDecoder.posixPaths(fromURIList: "file:///tmp/a\nhttps://x") == nil)
        #expect(PasteDecoder.dropPayload("") == nil)
        #expect(PasteDecoder.dropPayload("text") == "text")
    }

    @Test func anEmptyClipboardStillCompletesAnOSC52Read() {
        #expect(ClipboardPolicy.readPlan(mimes: ["image/png"], list: false) == .unavailable)
        #expect(ClipboardPolicy.readPlan(mimes: ["image/png"], list: true) == .listOnly)
        let completion = ClipboardPolicy.textCompletion(text: nil, list: true)
        #expect(completion.items == [ClipboardItem(mime: ClipboardPolicy.textMime, data: Data())])
        #expect(completion.available.isEmpty)
        #expect(ClipboardPolicy.access(for: .paste) == nil)
        #expect(ClipboardPolicy.access(for: .osc52Write) == .write)
    }

    @Test func aLatchedOSC11ColorKeepsTheBackgroundOutOfTheOverlay() {
        let session = BackgroundWatermark(kind: .color, colorHex: "#102030")
        #expect(BackgroundOverlayPolicy.watermark(oscLatch: "#ffffff", fixedBackground: nil, sessionBackground: session) == nil)
        #expect(BackgroundOverlayPolicy.watermark(oscLatch: nil, fixedBackground: "#000000", sessionBackground: session)?.colorHex
            == "#000000")
        #expect(!BackgroundOverlayPolicy.overlayText(oscLatch: "#ffffff", watermark: session, resolvedImagePath: nil,
                                                     fontSize: nil, windowOpacity: 0.5).contains("background ="))
    }

    @Test func aPickItemStatusErrorNamesTheFieldNotTheValue() {
        #expect(ControlPickItem(id: "a", label: "a", status: "active").statusError == nil)
        #expect(ControlPickItem(id: "a", label: "a", status: "busy").statusError?.contains("busy") == false)
        #expect(ControlPickItem(id: "a", label: "a", statusColor: "red").statusError == "invalid pick item color (expected #rrggbb)")
    }

    @Test func deletePromptsCountSessions() {
        #expect(DeletePrompt.workspaceMessage(name: "w", sessions: 1) == "Delete “w” and its 1 session? This can't be undone.")
        #expect(DeletePrompt.workspaceMessage(name: "w", sessions: 2).contains("2 sessions"))
    }
}
