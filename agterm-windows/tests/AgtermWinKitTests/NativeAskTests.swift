import AgtermWinKit
import Foundation
import Testing
import agtermCore

@MainActor
struct NativeAskTests {
    private func key(_ virtualKey: Int32, shift: Bool = false, control: Bool = false, alt: Bool = false) -> NativeAsk.Key? {
        NativeAsk.key(virtualKey: virtualKey, shift: shift, control: control, alt: alt)
    }

    @Test func panelKeysFollowTheMacDialog() {
        #expect(key(0x09) == .forward)
        #expect(key(0x09, shift: true) == .backward)
        #expect(key(0x27) == .forward)
        #expect(key(0x25) == .backward)
        #expect(key(0x28) == .down)
        #expect(key(0x20) == .toggle)
        #expect(key(0x0D) == .activate)
        #expect(key(0x1B) == .cancel)
        #expect(key(0x57, control: true) == .cancel)
        #expect(key(0x59) == .hotkey("y"))
        #expect(key(0x59, control: true) == nil)
        #expect(key(0x59, alt: true) == nil)
    }

    @Test func returnAnswersALineButOnlyCtrlReturnAMultilineField() {
        #expect(NativeAsk.editorKey(.input(.line), virtualKey: 0x0D, shift: false, control: false, alt: false) == .activate)
        #expect(NativeAsk.editorKey(.input(.multiline), virtualKey: 0x0D, shift: false, control: false, alt: false) == nil)
        #expect(NativeAsk.editorKey(.input(.multiline), virtualKey: 0x0D, shift: false, control: true, alt: false) == .activate)
        #expect(NativeAsk.editorKey(.input(.line), virtualKey: 0x26, shift: false, control: false, alt: false) == nil)
        #expect(NativeAsk.editorKey(.other, virtualKey: 0x26, shift: false, control: false, alt: false) == .up)
        #expect(NativeAsk.editorKey(.input(.line), virtualKey: 0x59, shift: false, control: false, alt: false) == nil)
    }

    @Test func keysMoveTheHighlightAndAnswerWithIt() throws {
        let controller = PickController()
        let ask = PendingAsk(id: UUID().uuidString, title: "Go?",
                             buttons: [ControlAskButton(id: "yes", label: "Yes", hotkey: "y"), ControlAskButton(id: "no", label: "No")])
        #expect(controller.openAsk(ask))
        let slot = NativeAsk.Slot.window(controller)
        var navigation = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID)
        #expect(NativeAsk.apply(.forward, to: slot, navigation: &navigation) == .none)
        #expect(NativeAsk.apply(.activate, to: slot, navigation: &navigation) == .answer(1))
        #expect(NativeAsk.apply(.hotkey("y"), to: slot, navigation: &navigation) == .answer(0))
        #expect(NativeAsk.apply(.cancel, to: slot, navigation: &navigation) == .escape)
        controller.cancelAsk()
    }

    @Test func anEditRefusesForbiddenControls() {
        #expect(NativeAsk.acceptsEdit("one line", editor: .input(.line)))
        #expect(!NativeAsk.acceptsEdit("two\nlines", editor: .input(.line)))
        #expect(NativeAsk.acceptsEdit("two\nlines", editor: .input(.multiline)))
        #expect(!NativeAsk.acceptsEdit(String(repeating: "x", count: AskInputForm.maxTextBytes + 1), editor: .input(.multiline)))
    }

    @Test func widthIsAPercentOrNinetyPercentUpToSeventyTwoCells() {
        #expect(NativeAsk.panelWidth(anchorWidth: 1000, cell: 10, width: 50) == 500)
        #expect(NativeAsk.panelWidth(anchorWidth: 500, cell: 10, width: nil) == 450)
        #expect(NativeAsk.panelWidth(anchorWidth: 2000, cell: 10, width: nil) == 720)
    }

    @Test func buttonLabelsMarkTheirHotkey() {
        #expect(NativeAsk.buttonLabel(ControlAskButton(id: "s", label: "Save & quit", hotkey: "q"), destructive: false) == "Save && &quit")
        #expect(NativeAsk.buttonLabel(ControlAskButton(id: "x", label: "Delete", hotkey: "z"), destructive: true) == "! Delete (&Z)")
        #expect(NativeAsk.buttonLabel(ControlAskButton(id: "o", label: "OK"), destructive: false) == "OK")
    }
}

@MainActor
struct PalettePickTests {
    private func pick(query: String? = nil, allowCustom: Bool = false, selection: String? = nil) -> PendingPick {
        PendingPick(id: "p", items: [ControlPickItem(id: "a", label: "alpha", subtitle: "zeta"),
                                     ControlPickItem(id: "b", label: "beta"), ControlPickItem(id: "c", label: "gamma")],
                    prompt: nil, query: query, allowCustom: allowCustom, selection: selection)
    }

    @Test func aBlankQueryKeepsTheCallersOrder() {
        #expect(Palette.pickRows(pick(), query: " ").map(\.title) == ["alpha", "beta", "gamma"])
    }

    @Test func aQueryMatchesLabelsNotSubtitles() {
        #expect(Palette.pickRows(pick(), query: "zeta").isEmpty)
        #expect(Palette.pickRows(pick(), query: "gam").map(\.target) == [.pickChoice("c")])
    }

    @Test func aCustomRowOffersTheQueryWhenNothingMatches() {
        let rows = Palette.pickRows(pick(allowCustom: true), query: " zeta ")
        #expect(rows.map(\.title) == ["Use \"zeta\""])
        #expect(rows.map(\.target) == [.pickCustom("zeta")])
    }

    @Test func theSelectedItemIsHighlightedWhileListed() {
        let selected = pick(selection: "c")
        #expect(Palette.pickSeed(selected, rows: Palette.pickRows(selected, query: "")) == 2)
        #expect(Palette.pickSeed(selected, rows: Palette.pickRows(selected, query: "beta")) == 0)
    }
}
