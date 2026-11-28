import agtermCore

/// WindowsPresentation is what agterm-win's hello lists to an agterm-server: the kinds it handles. The origin refuses
/// or keeps the rest. Every kind core supports is in `handled` or `unhandled`, so a new upstream kind needs a decision.
public enum WindowsPresentation {
    public static let handled: Set<String> = Set(PresentationHub.pageKinds + PresentationHub.pickKinds + [
        "status", "hud", "notify", "context", "info",
        PresentationHub.askFormKind, PresentationHub.askOtherKind, PresentationHub.jobTokenKind,
        PresentationHub.statusShapesKind, PresentationHub.statusCheckmarkKind, PresentationHub.statusClearKind,
        PresentationHub.pendingSnapshotKind, PresentationHub.presenterVacantKind, PresentationHub.offerIdentityKind,
        PresentationHub.endedKind,
    ])

    /// unhandled lists what an agterm-win viewer cannot show yet: messages and mail, status sounds, companion following,
    /// attached-pane layout, respawns and leads, link clicks and snapshots, point-sized overlays, and every page source but
    /// a URL, an HTML file and an image.
    public static let unhandled: Set<String> = [
        "message", "mail", "sound", "layout",
        PresentationHub.companionsKind, PresentationHub.restartRespawnKind, PresentationHub.leadReportKind,
        PresentationHub.linkClickKind, PresentationHub.linkSnapshotKind, PresentationHub.overlayPointsKind,
        PresentationHub.pageContentKind, PresentationHub.pageDocumentKind, PresentationHub.pageLinksKind,
        PresentationHub.pageForwardKind, PresentationHub.pageTextKind, PresentationHub.pageFilesKind,
        PresentationHub.pageExpandKind,
    ]

    /// kinds is the hello's list, in core's order.
    public static let kinds = PresentationHub.supportedKinds.filter(handled.contains)
}
