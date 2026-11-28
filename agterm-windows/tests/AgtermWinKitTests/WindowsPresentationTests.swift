import AgtermWinKit
import Testing
import agtermCore

@MainActor
struct WindowsPresentationTests {
    @Test func everyCoreKindIsDecidedOnce() {
        #expect(WindowsPresentation.handled.union(WindowsPresentation.unhandled) == Set(PresentationHub.supportedKinds))
        #expect(WindowsPresentation.handled.isDisjoint(with: WindowsPresentation.unhandled))
    }

    @Test func theHelloListsTheHandledKindsAndKeepsFormsAndPages() {
        let kinds = Set(WindowsPresentation.kinds)
        #expect(kinds == WindowsPresentation.handled)
        #expect(kinds.isSuperset(of: [PresentationHub.askFormKind, PresentationHub.askOtherKind] + PresentationHub.pageKinds + PresentationHub.pickKinds))
        #expect(!kinds.contains(PresentationHub.pageTextKind) && !kinds.contains(PresentationHub.overlayPointsKind))
    }
}
