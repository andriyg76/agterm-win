import Foundation

/// ControlOverlayOpen parses `session.overlay.open` into a program or a page source, using the same rules as the Mac
/// dispatcher.
public enum ControlOverlayOpen {
  public static func parse(command: String, args: ControlArgs?) -> Result<HtmlSource?, String> {
    switch ControlDispatcher.overlayContent(command: command, args: args) {
    case .rejected(let response):
      return .failure(response.error ?? "refused")
    case .program:
      return .success(nil)
    case .page(let source):
      return .success(source)
    }
  }
}