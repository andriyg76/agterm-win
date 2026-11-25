import Foundation

extension HtmlOverlay {
  /// controlNode is how this page reads on `tree`, matching the Mac's `htmlOverlays` entry for a local page.
  public func controlNode(hidden: Bool = false, zoom: Double? = nil, pane: OverlayPane? = nil) -> ControlHtmlOverlayNode {
    var file: String?, cwd: String?, url: String?, image: String?, markdown: String?, document: String?
    var text: ControlTextOverlayNode?
    switch source {
    case .file(let path, let grantRoot): (file, cwd) = (path, grantRoot)
    case .url(let address): url = address.absoluteString
    case .replica(let path, .html): file = path
    case .image(let path), .replica(let path, .image): image = path
    case .markdown(let path), .replica(let path, .markdown): markdown = path
    case .document(let path), .replica(let path, .document): document = path
    case .unreadable: break
    case .text(let path, let line), .replica(let path, .text(let line)):
      let log = logState
      text = ControlTextOverlayNode(file: path, language: TextPage.language(forFile: path), line: line,
                                    tail: textLog?.tail, following: log?.following, lines: log?.report.lines,
                                    clipped: log?.report.clipped, waiting: log?.report.waiting,
                                    unreadable: log?.report.unreadable,
                                    search: textSearch.map {
                                      ControlTextSearchNode(query: $0.query, matches: $0.matches, current: $0.current)
                                    },
                                    changes: textChanges.map { ControlTextChangesNode(count: $0.count, current: $0.current) },
                                    files: textFiles.map { ControlTextFilesNode(count: $0.count, current: $0.current, path: $0.path) },
                                    wrap: textWrap ? true : nil, expand: textExpand ? true : nil)
    }
    return ControlHtmlOverlayNode(pane: pane?.rawValue, file: file, cwd: cwd, url: url, image: image, markdown: markdown,
                                document: document, text: text, state: loadState.rawValue, error: loadError,
                                page: current?.page, title: current?.title, canGoBack: current?.canGoBack,
                                canGoForward: current?.canGoForward, navigation: navigation ? true : nil, javascript: javascript,
                                chromeless: chromeless, zoom: zoom, id: id.uuidString, persistent: persistent, browse: browse,
                                hidden: hidden ? true : nil, replica: replicaOf == nil ? nil : true,
                                clicked: clicked ? true : nil)
  }
}