import Foundation
import ReadiumNavigator
import ReadiumAdapterGCDWebServer
import ReadiumShared
import Flutter
import UIKit
import WebKit

private let TAG = "ReadiumReaderView"
private let ReadiumReaderStatusReady = "ready"
private let ReadiumReaderStatusLoading = "loading"
private let ReadiumReaderStatusClosed = "closed"
private let ReadiumReaderStatusError = "error"

let readiumReaderViewType = "dev.mulev.flureadium/ReadiumReaderWidget"

class ReadiumBugLogger: ReadiumShared.WarningLogger {
  func log(_ warning: Warning) {
    print(TAG, "Error in Readium: \(warning)")
  }
}

private let readiumBugLogger = ReadiumBugLogger()
private var userScripts: [WKUserScript] = []

func parseLocatorFragmentsResult(_ result: Any?) -> Locator? {
  guard let json = result as? Dictionary<String, Any?> else {
    return nil
  }

  return try? Locator(json: json, warnings: readiumBugLogger)
}

/// CSS value for our `--MBO__paraAlign` variable. Not sent to Readium.
/// `"default"` means keep publisher alignment (no override).
func mboCssAlign(_ align: TextAlignment?) -> String {
  switch align {
  case .justify: return "justify"
  case .left: return "left"
  default: return "default"
  }
}

/// ReadiumCSS forces `p { text-align: inherit !important }` when
/// `--USER__textAlign` is present. Strip it so publisher center/right survive.
func preferencesWithoutReadiumTextAlign(_ preferences: EPUBPreferences) -> EPUBPreferences {
  var prefs = preferences
  prefs.textAlign = nil
  return prefs
}

class ReadiumReaderView: NSObject, FlutterPlatformView, EPUBNavigatorDelegate, VisualNavigatorDelegate {

  private let channel: ReadiumReaderChannel
  private var readerStatusStreamHandler: EventStreamHandler?
  private var textLocatorStreamHandler: EventStreamHandler?
  private let _view: UIView
  private let readiumViewController: EPUBNavigatorViewController
  private var isVerticalScroll = false
  private var hasSentReady = false
  private var isDisposed = false
  private var enableEdgeTapNavigation: Bool
  private var enableSwipeNavigation: Bool
  private var edgeTapAreaPoints: CGFloat?

  // Retain the navigation adapter to prevent ARC deallocation
  private var directionalNavigationAdapter: DirectionalNavigationAdapter?

  // Scroll-mode position memory: remembers the last scroll position per spine item
  // so swipe-back can restore where the user was in the previous chapter.
  private var spineItemHistory: [String: Locator] = [:]
  private var lastSpineItemLocator: Locator?
  private var currentSpineItemHref: String?
  /// User left/justify; never forwarded to Readium `--USER__textAlign`.
  private var mboParaAlign: String

  var publicationIdentifier: String?

  /// The editing actions shown in the EPUB long-press selection menu.
  /// Keeping this as a static constant makes the native action set testable.
  static let highlightEditingAction =
    EditingAction(title: "Highlight", action: Selector("onHighlightSelection:"))
  static let noteEditingAction =
    EditingAction(title: "Add note", action: Selector("onNoteSelection:"))
  static let epubEditingActions: [EditingAction] = [
    .copy,
    highlightEditingAction,
    noteEditingAction,
  ]

  func view() -> UIView {
    print(TAG, "::getView")
    return _view
  }

  deinit {
    print(TAG, "::deinit")
    readiumViewController.view.removeFromSuperview()
  }

  init(
    frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?,
    registrar: FlutterPluginRegistrar
  ) {
    print(TAG, "::init")
    let creationParams = args as! Dictionary<String, Any?>

    let publication = getCurrentPublication()!

    let preferencesMap = creationParams["preferences"] as? [String: String]
    // Default to single-column when Flutter sends no preferences map.
    var defaultPreferences = preferencesMap.map { EPUBPreferences(fromMap: $0) }
      ?? EPUBPreferences(columnCount: .one, spread: .never)
    // ReadiumCSS `p { text-align: inherit !important }` fires when
    // --USER__textAlign is set. Keep the Flutter value for our CSS instead.
    mboParaAlign = mboCssAlign(defaultPreferences.textAlign)
    defaultPreferences.textAlign = nil

    // Start with overlay gestures off so edge swipes reach WKWebView
    // before Flutter applies setNavigationConfig.
    enableEdgeTapNavigation = false
    enableSwipeNavigation = false
    edgeTapAreaPoints = nil

    let locatorStr = creationParams["initialLocator"] as? String
    let locator = locatorStr == nil ? nil : try! Locator.init(jsonString: locatorStr!)
    print(TAG, "publication = \(publication)")

    channel = ReadiumReaderChannel(
      name: "\(readiumReaderViewType):\(viewId)", binaryMessenger: registrar.messenger())
    textLocatorStreamHandler = EventStreamHandler(withName: "text-locator", messenger: registrar.messenger())
    readerStatusStreamHandler = EventStreamHandler(withName: "reader-status", messenger: registrar.messenger())

    readerStatusStreamHandler?.sendEvent(ReadiumReaderStatusLoading)

    print(TAG, "Publication: (identifier=\(String(describing: publication.metadata.identifier)),title=\(String(describing: publication.metadata.title)))")
    print(TAG, "Added publication at \(String(describing: publication.baseURL))")

    // Remove undocumented Readium default 20dp or 44dp top/bottom padding.
    // See EPUBNavigatorViewController.swift in r2-navigator-swift.
    var config = EPUBNavigatorViewController.Configuration()
    config.contentInset = [
      .compact: (top: 0, bottom: 0),
      .regular: (top: 0, bottom: 0),
    ]
    // TODO: Make this config configurable from Flutter
    // Might want it to be higher for a local publication than remote.
    config.preloadPreviousPositionCount = 2
    config.preloadNextPositionCount = 4
    config.debugState = true
    var decorationTemplates = HTMLDecorationTemplate.defaultTemplates(
      alpha: 1.0,
      experimentalPositioning: true
    )
    decorationTemplates[.mboNoteMarker] = HTMLDecorationTemplate(
      layout: .bounds,
      width: .page,
      element: { decoration in
        let tint = (decoration.style.config as? UIColor ?? .systemPurple).cssValue()
        return """
          <div class="mbo-note-marker-root">
            <span class="mbo-note-marker" data-activable="1" style="--mbo-note-marker-tint: \(tint)">
              <i class="mbo-note-glyph" aria-hidden="true"></i>
            </span>
          </div>
          """
      },
      stylesheet: """
        .mbo-note-marker-root { position: relative; width: 100%; height: 100%; pointer-events: none; overflow: visible; }
        .mbo-note-marker { position: absolute; top: -7px; right: 4px; width: 15px; height: 15px; box-sizing: border-box; border: 1.5px solid var(--mbo-note-marker-tint); border-radius: 50%; background: var(--RS__backgroundColor, #fff); color: var(--mbo-note-marker-tint); display: flex; align-items: center; justify-content: center; z-index: 99; pointer-events: auto; box-shadow: 0 0 0 1px var(--RS__backgroundColor, #fff); }
        .mbo-note-glyph { position: relative; display: block; width: 6px; height: 8px; box-sizing: border-box; border: 1px solid var(--mbo-note-marker-tint); border-radius: 1px; }
        .mbo-note-glyph:after { content: ''; position: absolute; left: 1px; right: 1px; top: 2px; height: 1px; background: var(--mbo-note-marker-tint); box-shadow: 0 2px 0 var(--mbo-note-marker-tint); }
        """
    )
    config.decorationTemplates = decorationTemplates
    config.editingActions = ReadiumReaderView.epubEditingActions
    config.preferences = defaultPreferences

    readiumViewController = try! EPUBNavigatorViewController(
      publication: publication,
      initialLocation: locator,
      config: config,
      httpServer: sharedReadium.httpServer!
    )

    if userScripts.isEmpty {
      initUserScripts(registrar: registrar)
    }

    _view = EdgeTapInterceptView()
    super.init()

    channel.setMethodCallHandler(onMethodCall)
    readiumViewController.delegate = self
    readiumViewController.observeDecorationInteractions(inGroup: "book-annotations") { [weak self] event in
      guard let self = self else { return }
      self.channel.onDecorationTapped(id: event.decoration.id, locator: event.decoration.locator)
    }

    // Set initial scroll mode from preferences and configure edge tap handlers accordingly
    isVerticalScroll = defaultPreferences.scroll ?? false
    configureEdgeTapHandlers(isScrollMode: isVerticalScroll)

    let child: UIView = readiumViewController.view
    let view = _view
    view.addSubview(readiumViewController.view)

    child.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate(
      [
        child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        child.topAnchor.constraint(equalTo: view.topAnchor),
        child.bottomAnchor.constraint(equalTo: view.bottomAnchor)
      ]
    )

    currentReaderView = self
    publicationIdentifier = publication.metadata.identifier

    /// Keyboard arrows still turn pages. Touch taps are handled only by
    /// `EdgeTapInterceptView` when `enableEdgeTapNavigation` is true.
    /// Binding `.touch` here would keep ~30% left/right tap-to-turn even
    /// after Flutter sends `enableEdgeTapNavigation: false`.
    directionalNavigationAdapter = DirectionalNavigationAdapter(
        pointerPolicy: .init(types: [])
    )
    directionalNavigationAdapter?.bind(to: readiumViewController)

    print(TAG, "::init success")
  }

  @objc public func onCustomEditingAction() {
    print(TAG, "EditingAction::NOTA")
    // NOTE: This method will not actually be hit. It will try to find an "onEditingActionNota" function in the Responder chain!
    // see https://github.com/readium/swift-toolkit/issues/466

    // This methos should actually be implemented in the Flutter AppDelegate!
    // TODO: Find a way to trigger the code below, from the AppDelegate.
    if let selection = readiumViewController.currentSelection {
      let selectionLocator = selection.locator
      currentReaderView?.readiumViewController.apply(decorations: [Decoration(id: "highlight", locator: selectionLocator, style: .highlight(), userInfo: [:])], in: "user-highlight")
      readiumViewController.clearSelection()
    }
  }

  @MainActor func performSelectionAction(_ action: String) {
    guard let locator = readiumViewController.currentSelection?.locator else { return }
    channel.onSelectionAction(action: action, locator: locator)
    readiumViewController.clearSelection()
  }

  // override EPUBNavigatorDelegate::navigator:setupUserScripts
  func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
    print(TAG, "setupUserScripts: adding \(userScripts.count) scripts")
    for script in userScripts {
      userContentController.addUserScript(script)
    }
  }

  // override EPUBNavigatorDelegate::middleTapHandler
  func middleTapHandler() {
  }

  func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
    // All margin & safe-area is handled on the Flutter side.
    return .init(top: 0, left: 0, bottom: 0, right: 0)
  }

  // override EPUBNavigatorDelegate::navigator:presentError
  func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
    print(TAG, "presentError: \(error)")
  }

  // override EPUBNavigatorDelegate::navigator:didFailToLoadResourceAt
  func navigator(_ navigator: Navigator, didFailToLoadResourceAt href: ReadiumShared.RelativeURL, withError error: ReadiumShared.ReadError) {
    print(TAG, "didFailToLoadResourceAt: \(href). err: \(error)")

    // TODO: Should we send resource-load error like this?
    self.readerStatusStreamHandler?.sendEvent(ReadiumReaderStatusError)

    // Route through the plugin, which owns the single "error" channel.
    FlureadiumPlugin.shared?.sendError(
      message: error.localizedDescription, code: "DidFailToLoadResource", data: href.string)
  }

  // override NavigatorDelegate::navigator:locationDidChange
  func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    print(TAG, "onPageChanged: \(locator)")

    let newHref = strippedHref(locator.href.string)

    if isVerticalScroll, let oldHref = currentSpineItemHref, newHref != oldHref {
      // Store last known position for the spine item we are leaving
      if let outgoing = lastSpineItemLocator {
        spineItemHistory[oldHref] = outgoing
      }

      // Restore position if swiping backward and we have a stored position
      let readingOrder = readiumViewController.publication.readingOrder
      if isBackwardNavigation(from: oldHref, to: newHref, in: readingOrder),
         let stored = spineItemHistory[newHref] {
        Task { @MainActor in
          // emitOnPageChanged fires inside goToLocator — persistent save
          // correctly updates to the restored position as a side effect.
          await self.goToLocator(locator: stored, animated: false)
        }
      }
    }

    currentSpineItemHref = newHref
    lastSpineItemLocator = locator
    applyMboParagraphAlign()

    if !hasSentReady {
      self.readerStatusStreamHandler?.sendEvent(ReadiumReaderStatusReady)
      hasSentReady = true
    }
    emitOnPageChanged(locator: locator)
  }

  func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      print(TAG, "skipped non-http external URL: \(url)")
      return
    }
    emitOnExternalLinkActivated(url: url)
  }

  func applyDecorations(_ decorations: [Decoration], forGroup groupIdentifier: String) {
    print(TAG, "onMethodApplyDecorations: \(decorations) identifier: \(groupIdentifier)")
    self.readiumViewController.apply(decorations: decorations, in: groupIdentifier)
  }

  func getFirstVisibleLocator() async -> Locator? {
    return await self.readiumViewController.firstVisibleElementLocator()
  }

  func getCurrentLocation() -> Locator? {
    return self.readiumViewController.currentLocation
  }

  func getCurrentSelection() -> Locator? {
    return self.readiumViewController.currentSelection?.locator
  }

  func selectLocator(_ locator: Locator) async {
    guard !isDisposed else { return }
    await goToLocator(locator: locator, animated: false)
    guard !isDisposed, let locatorJSON = locator.jsonString,
          let encoded = try? JSONEncoder().encode(locatorJSON),
          let quotedLocator = String(data: encoded, encoding: .utf8) else { return }
    let script = """
    (function() {
      try {
        const locator = JSON.parse(\(quotedLocator));
        const locations = locator.locations || {};
        const domRange = locations.domRange;
        const boundary = (value) => {
          if (!value || !value.cssSelector) return null;
          const element = document.querySelector(value.cssSelector);
          if (!element) return null;
          if (value.charOffset !== undefined) {
            const textNodes = Array.from(element.childNodes)
              .filter(node => node.nodeType === Node.TEXT_NODE);
            const node = textNodes[value.textNodeIndex];
            return node ? { node, offset: value.charOffset } : null;
          }
          return { node: element, offset: value.textNodeIndex };
        };
        let range = null;
        if (domRange && domRange.start && domRange.end) {
          const start = boundary(domRange.start);
          const end = boundary(domRange.end);
          if (start && end) {
            range = document.createRange();
            range.setStart(start.node, start.offset);
            range.setEnd(end.node, end.offset);
          }
        }
        if (!range) {
          const quote = locator.text && locator.text.highlight;
          if (!quote) return false;
          const root = locations.cssSelector
            ? document.querySelector(locations.cssSelector)
            : document.body;
          if (!root) return false;
          const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          const nodes = [];
          let text = '';
          while (walker.nextNode()) {
            const node = walker.currentNode;
            nodes.push({ node, start: text.length, end: text.length + node.textContent.length });
            text += node.textContent;
          }
          const startIndex = text.indexOf(quote);
          if (startIndex < 0) return false;
          const endIndex = startIndex + quote.length;
          const startNode = nodes.find(item => item.start <= startIndex && item.end > startIndex);
          const endNode = nodes.find(item => item.start < endIndex && item.end >= endIndex);
          if (!startNode || !endNode) return false;
          range = document.createRange();
          range.setStart(startNode.node, startIndex - startNode.start);
          range.setEnd(endNode.node, endIndex - endNode.start);
        }
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        return true;
      } catch (_) { return false; }
    })()
    """
    _ = await evaluateJavascript(script)
  }

  private func evaluateJavascript(_ code: String) async -> Result<Any, Error> {
    return await self.readiumViewController.evaluateJavaScript(code)
  }

  private func evaluateJSReturnResult(_ code: String, result: @escaping FlutterResult) {
    Task { @MainActor in
      guard !self.isDisposed else { result(nil); return }
      do {
        let data = try await self.evaluateJavascript(code).get()
        print(TAG, "evaluateJSReturnResult result: \(data)")
        await MainActor.run() {
          return result(data)
        }
      } catch (let err) {
        print(TAG, "evaluateJSReturnResult error: \(err)")
        await MainActor.run() {
          return result(nil)
        }
      }
    }
  }

  private func setUserPreferences(preferences: EPUBPreferences) {
    isVerticalScroll = preferences.scroll ?? false
    mboParaAlign = mboCssAlign(preferences.textAlign)
    self.readiumViewController.submitPreferences(preferencesWithoutReadiumTextAlign(preferences))
    configureEdgeTapHandlers(isScrollMode: isVerticalScroll)
    applyMboParagraphAlign()
  }

  private func applyMboParagraphAlign() {
    let letters = mboParaAlign.filter(\.isLetter)
    let align = letters.isEmpty ? "default" : letters
    Task {
      _ = await evaluateJavascript("""
        (function(){
          try { localStorage.setItem('mboParaAlign', '\(align)'); } catch(e) {}
          window.__MBO_PARA_ALIGN = '\(align)';
          function applyDoc(doc) {
            if (!doc || !doc.documentElement) return;
            var override = ('\(align)' === 'left' || '\(align)' === 'justify');
            try {
              if (override) {
                doc.documentElement.style.setProperty('--MBO__paraAlign', '\(align)');
                doc.documentElement.setAttribute('data-mbo-para-align', '\(align)');
              } else {
                doc.documentElement.style.removeProperty('--MBO__paraAlign');
                doc.documentElement.removeAttribute('data-mbo-para-align');
              }
            } catch (e) {}
            try {
              var r = doc.defaultView && doc.defaultView.readium;
              if (r && r.setCSSProperties) {
                r.setCSSProperties({'--MBO__paraAlign': override ? '\(align)' : null});
              }
            } catch (e) {}
            try {
              var frames = doc.querySelectorAll('iframe');
              for (var i = 0; i < frames.length; i++) {
                try { applyDoc(frames[i].contentDocument); } catch (err) {}
              }
            } catch (e) {}
          }
          if (window.__mboSetParaAlign) { window.__mboSetParaAlign('\(align)'); }
          else { applyDoc(document); }
        })();
      """)
    }
  }

  /// Configure edge tap handlers based on scroll mode.
  /// In scroll mode, all callbacks are nil — WKWebView handles native swipes.
  /// In paginated mode, the overlay only claims the edge zone when tap or
  /// swipe navigation is enabled. Otherwise edge swipes pass through to
  /// Readium's page-turn gesture.
  private func configureEdgeTapHandlers(isScrollMode: Bool) {
    guard let edgeTapView = _view as? EdgeTapInterceptView else { return }

    let overlayNavigation = enableEdgeTapNavigation || enableSwipeNavigation
    edgeTapView.interceptEdgeTaps = !isScrollMode && overlayNavigation

    if isScrollMode {
      // Scroll mode: all callbacks nil.
      // Swipes are handled natively by WKWebView — no interception needed.
      edgeTapView.onLeftEdgeTap = nil
      edgeTapView.onRightEdgeTap = nil
      edgeTapView.onSwipeLeft = nil
      edgeTapView.onSwipeRight = nil
    } else {
      // Enable edge tap navigation in paginated mode (if preference allows)
      if enableEdgeTapNavigation {
        if let points = edgeTapAreaPoints {
          edgeTapView.edgeThresholdPoints = points
        }
        edgeTapView.onLeftEdgeTap = { [weak self] in
          guard let self = self else { return }
          print(TAG, "[FALLBACK] Triggering goLeft via fallback tap handler")
          Task { @MainActor in
            let _ = await self.readiumViewController.goLeft(options: NavigatorGoOptions(animated: true))
          }
        }
        edgeTapView.onRightEdgeTap = { [weak self] in
          guard let self = self else { return }
          print(TAG, "[FALLBACK] Triggering goRight via fallback tap handler")
          Task { @MainActor in
            let _ = await self.readiumViewController.goRight(options: NavigatorGoOptions(animated: true))
          }
        }
      } else {
        edgeTapView.onLeftEdgeTap = nil
        edgeTapView.onRightEdgeTap = nil
      }

      if enableSwipeNavigation {
        edgeTapView.onSwipeLeft = { [weak self] in
          guard let self = self else { return }
          print(TAG, "[FALLBACK] Triggering goRight via swipe left handler")
          Task { @MainActor in
            let _ = await self.readiumViewController.goRight(options: NavigatorGoOptions(animated: true))
          }
        }
        edgeTapView.onSwipeRight = { [weak self] in
          guard let self = self else { return }
          print(TAG, "[FALLBACK] Triggering goLeft via swipe right handler")
          Task { @MainActor in
            let _ = await self.readiumViewController.goLeft(options: NavigatorGoOptions(animated: true))
          }
        }
      } else {
        edgeTapView.onSwipeLeft = nil
        edgeTapView.onSwipeRight = nil
      }
    }
  }

  private func emitOnPageChanged(locator: Locator) -> Void {
    let json = locator.jsonString ?? "null"

    print(TAG, "emitOnPageChanged:locator=\(String(describing: locator))")

    Task { @MainActor [isVerticalScroll, weak self] in
      guard let self else { return }
      let isDisposed = await MainActor.run { self.isDisposed }
      guard !isDisposed else { return }
      guard let locatorWithFragments = await self.getLocatorFragments(json, isVerticalScroll) else {
        print(TAG, "emitOnPageChanged failed!")
        return
      }
      await MainActor.run {
        guard !self.isDisposed else { return }
        self.channel.onPageChanged(locator: locatorWithFragments)
        guard let textLocatorStreamHandler = self.textLocatorStreamHandler else {
          print(TAG, "emitOnPageChanged: textLocatorStreamHandler is nil!")
          return
        }

        textLocatorStreamHandler.sendEvent(locatorWithFragments.jsonString)
      }
    }
  }

  private func emitOnExternalLinkActivated(url: URL) {
    print(TAG, "emitOnExternalLinkActivated: \(url)")
    Task { @MainActor in
      await MainActor.run() {
        self.channel.onExternalLinkActivated(url: url)
      }
    }
  }

  internal func getLocatorFragments(_ locatorJson: String, _ isVerticalScroll: Bool) async -> Locator? {
    guard !isDisposed else {
      return nil
    }

    switch await self.evaluateJavascript("window.epubPage.getLocatorFragments(\(locatorJson), \(isVerticalScroll));") {
      case .success(let jresult):
        guard let locatorWithFragments = parseLocatorFragmentsResult(jresult) else {
          print(TAG, "getLocatorFragments: failed to parse locator from JS result")
          return nil
        }
        return locatorWithFragments
      case .failure(let err):
        print(TAG, "getLocatorFragments failed! \(err)")
        return nil
      }
  }

  private func scrollTo(locations: Locator.Locations, toStart: Bool) async -> Void {
    let json = locations.jsonString ?? "null"
    print(TAG, "scrollTo: Go to locations \(json), toStart: \(toStart)")

    let _ = await evaluateJavascript("window.epubPage.scrollToLocations(\(json),\(isVerticalScroll),\(toStart));")
  }

  func goToLocator(locator: Locator, animated: Bool) async -> Void {
    // Explicit navigation (TOC, skipToPrevious, etc.) must not trigger restoration.
    // Clearing history for this target prevents a subsequent swipe-back from
    // landing at a stale stored position rather than the TOC-specified location.
    spineItemHistory.removeValue(forKey: strippedHref(locator.href.string))

    let locations = locator.locations
    let shouldScroll = canScroll(locations: locations)
    let shouldGo = readiumViewController.currentLocation?.href != locator.href
    let readiumViewController = self.readiumViewController

    if shouldGo {
      print(TAG, "goToLocator: Go to \(locator.href)")
      let goToSuccees = await readiumViewController.go(to: locator, options: NavigatorGoOptions(animated: animated))
      if (goToSuccees && shouldScroll) {
        await self.scrollTo(locations: locations, toStart: false)
        self.emitOnPageChanged()
      }
    } else {
      print(TAG, "goToLocator: Already there, Scroll to \(locator.href)")
      if (shouldScroll) {
        await self.scrollTo(locations: locations, toStart: false)
        self.emitOnPageChanged()
      }
    }
  }

  func justGoToLocator(_ locator: Locator, animated: Bool) async -> Bool {
    return await readiumViewController.go(to: locator, options: NavigatorGoOptions(animated: animated))
  }

  private func setLocation(locator: Locator, isAudioBookWithText: Bool) async -> Result<Any, Error> {
    let json = locator.jsonString ?? "null"

    return await evaluateJavascript("window.epubPage.setLocation(\(json), \(isAudioBookWithText));")
  }

  private func emitOnPageChanged() {
    guard let locator = readiumViewController.currentLocation else {
      print(TAG, "emitOnPageChanged: currentLocation = nil!")
      return
    }
    print(TAG, "emitOnPageChanged: Calling navigator:locationDidChange.")
    navigator(readiumViewController, locationDidChange: locator)
  }

  func onMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "go":
      guard let args = call.arguments as? [Any], args.count >= 3,
            let json = args[0] as? String,
            let locator = try? Locator(jsonString: json, warnings: readiumBugLogger),
            let animated = args[1] as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Invalid navigation locator", details: nil))
        return
      }
      let isAudioBookWithText = args[2] as? Bool ?? false

      Task { @MainActor in
        await self.goToLocator(locator: locator, animated: animated)
        let _ = await self.setLocation(locator: locator, isAudioBookWithText: isAudioBookWithText)
        result(true)
      }
      break
    case "goLeft":
      guard let animated = call.arguments as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Expected animation flag", details: nil))
        return
      }
      let readiumViewController = self.readiumViewController

      Task { @MainActor in
        let success = await readiumViewController.goLeft(options: NavigatorGoOptions(animated: animated))
        result(success)
      }
      break
    case "goRight":
      guard let animated = call.arguments as? Bool else {
        result(FlutterError(code: "invalid_arguments", message: "Expected animation flag", details: nil))
        return
      }
      let readiumViewController = self.readiumViewController

      Task { @MainActor in
        let success = await readiumViewController.goRight(options: NavigatorGoOptions(animated: animated))
        result(success)
      }
      break
    case "setLocation":
      guard let args = call.arguments as? [Any], args.count >= 2,
            let json = args[0] as? String,
            let locator = try? Locator(jsonString: json, warnings: readiumBugLogger) else {
        result(FlutterError(code: "invalid_arguments", message: "Invalid location", details: nil))
        return
      }
      let isAudioBookWithText = args[1] as? Bool ?? false
      Task { @MainActor in
        let _ = await self.setLocation(locator: locator, isAudioBookWithText: isAudioBookWithText)
        return await MainActor.run() {
          result(true)
        }
      }
      break
    case "getLocatorFragments":
      let args = call.arguments as? String ?? "null"
      Task { @MainActor in
        do {
          let data = try await self.evaluateJavascript("window.epubPage.getLocatorFragments(\(args), true);").get()
          await MainActor.run() {
            return result(data)
          }
        } catch (let err) {
          print(TAG, "getLocatorFragments error \(err)")
          await MainActor.run() {
            return result(false)
          }
        }
      }
      break
    case "getCurrentLocator":
      let args = call.arguments as? String ?? "null"
      print(TAG, "onMethodCall[currentLocator] args = \(args)")
      Task { @MainActor [isVerticalScroll] in
        guard let json = await self.readiumViewController.currentLocation?.jsonString else {
          await MainActor.run { result(nil) }
          return
        }
        let data = await self.getLocatorFragments(json, isVerticalScroll)
        await MainActor.run {
          result(data?.jsonString)
        }
      }
      break
    case "getCurrentSelection":
      result(self.readiumViewController.currentSelection?.locator.jsonString)
      break
    case "selectLocator":
      guard let locatorJSON = call.arguments as? String,
            let locator = try? Locator(jsonString: locatorJSON, warnings: readiumBugLogger) else {
        result(FlutterError(code: "select_locator_failed", message: "Invalid locator", details: nil))
        return
      }
      Task { @MainActor in
        await self.selectLocator(locator)
        result(nil)
      }
      break
    case "clearSelection":
      self.readiumViewController.clearSelection()
      result(nil)
      break
    case "isLocatorVisible":
      guard let args = call.arguments as? String,
            let locator = try? Locator(jsonString: args, warnings: readiumBugLogger) else {
        result(false)
        return
      }
      if locator.href != self.readiumViewController.currentLocation?.href {
        result(false)
        return
      }
      evaluateJSReturnResult("window.epubPage.isLocatorVisible(\(args));", result: result)
      break
    case "isReaderReady":
      self.evaluateJSReturnResult("""
                (function() {
                    if (typeof window.epubPage !== 'undefined' && typeof window.epubPage.isReaderReady === 'function') {
                        return window.epubPage.isReaderReady();
                    } else {
                        return false;
                    }
                })();
            """, result: result)
      break
    case "setPreferences":
      guard let args = call.arguments as? [String: String] else {
        result(FlutterError(code: "invalid_arguments", message: "Invalid preferences", details: nil))
        return
      }
      print(TAG, "onMethodCall[setPreferences] args = \(args)")
      let preferences = EPUBPreferences.init(fromMap: args)
      setUserPreferences(preferences: preferences)
      result(nil)
      break
    case "setNavigationConfig":
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "invalid_arguments", message: "Invalid navigation configuration", details: nil))
        return
      }
      print(TAG, "onMethodCall[setNavigationConfig] args = \(args)")
      let navConfig = FlutterNavigationConfig(fromMap: args)
      if let v = navConfig.enableEdgeTapNavigation { enableEdgeTapNavigation = v }
      if let v = navConfig.enableSwipeNavigation { enableSwipeNavigation = v }
      if let pts = navConfig.edgeTapAreaPoints {
        edgeTapAreaPoints = CGFloat(min(max(pts, 44.0), 120.0))
      }
      configureEdgeTapHandlers(isScrollMode: isVerticalScroll)
      result(nil)
      break
    case "applyDecorations":
      guard let args = call.arguments as? [Any], args.count == 2,
            let identifier = args[0] as? String,
            let decorationsPayload = args[1] as? [Any] else {
        return result(FlutterError.init(
          code: "JSON mapping error",
          message: "Could not map decorations: expected a list",
          details: nil))
      }

      // ReaderDecoration.toJson() sends nested maps. Keep accepting the
      // legacy JSON-string form while flattening the current Dart payload to
      // the string map consumed by Decoration(fromJson:).
      let decorationsStr: [String] = decorationsPayload.compactMap { value in
        if let jsonString = value as? String { return jsonString }
        guard let decoration = value as? [String: Any],
              let id = decoration["id"] as? String,
              let locator = decoration["locator"],
              let style = decoration["style"] as? [String: Any],
              let styleName = style["style"] as? String,
              let tint = style["tint"] as? String else {
          return nil
        }
        guard let locatorData = try? JSONSerialization.data(
          withJSONObject: locator, options: [.fragmentsAllowed, .sortedKeys]),
              let locatorString = String(data: locatorData, encoding: .utf8) else {
          return nil
        }
        let flattened = ["id": id, "locator": locatorString, "style": styleName, "tint": tint]
        guard let data = try? JSONSerialization.data(withJSONObject: flattened, options: [.sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
          return nil
        }
        return jsonString
      }

      guard decorationsStr.count == decorationsPayload.count else {
        return result(FlutterError.init(
          code: "JSON mapping error",
          message: "Could not map one or more decorations",
          details: nil))
      }

      guard let decorations = try? decorationsStr.map({ try Decoration(fromJson: $0) }) else {
        return result(FlutterError.init(
          code: "JSON mapping error",
          message: "Could not map decorations from JSON: \(decorationsStr)",
          details: nil))
      }

      print(TAG, "onMethodCall[setPreferences] args = \(args)")
      applyDecorations(decorations, forGroup: identifier)
      result(nil)
      break
    case "dispose":
      print(TAG, "Disposing readiumViewController")
      isDisposed = true
      readiumViewController.view.removeFromSuperview()
      readiumViewController.delegate = nil
      self.readerStatusStreamHandler?.sendEvent(ReadiumReaderStatusClosed)
      textLocatorStreamHandler?.dispose()
      textLocatorStreamHandler = nil
      readerStatusStreamHandler?.dispose()
      readerStatusStreamHandler = nil
      channel.setMethodCallHandler(nil)
      if currentReaderView === self { currentReaderView = nil }
      result(nil)
      break
    default:
      print(TAG, "Unhandled call \(call.method)")
      result(FlutterMethodNotImplemented)
      break
    }
  }

}

func initUserScripts(registrar: FlutterPluginRegistrar) {
  let comicJsKey = registrar.lookupKey(forAsset: "assets/helpers/comics.js", fromPackage: "flureadium")
  let comicCssKey = registrar.lookupKey(forAsset: "assets/helpers/comics.css", fromPackage: "flureadium")
  let epubJsKey = registrar.lookupKey(forAsset: "assets/helpers/epub.js", fromPackage: "flureadium")
  let preserveAlignJsKey = registrar.lookupKey(
    forAsset: "assets/helpers/preserve-text-align.js", fromPackage: "flureadium")
  let epubCssKey = registrar.lookupKey(forAsset: "assets/helpers/epub.css", fromPackage: "flureadium")
  let jsScripts = [comicJsKey, epubJsKey, preserveAlignJsKey].map { sourceFile -> String in
    let path = Bundle.main.path(forResource: sourceFile, ofType: nil)!
    let data = FileManager().contents(atPath: path)!
    return String(data: data, encoding: .utf8)!
  }
  let addCssScripts = [comicCssKey, epubCssKey].map { sourceFile -> String in
    let path = Bundle.main.path(forResource: sourceFile, ofType: nil)!
    let data = FileManager().contents(atPath: path)!.base64EncodedString()
    return """
      (function() {
      var parent = document.getElementsByTagName('head').item(0);
      var style = document.createElement('style');
      style.type = 'text/css';
      style.innerHTML = window.atob('\(data)');
      parent.appendChild(style)})();
    """
  }
  /// Add JS scripts right away, before loading the rest of the document.
  for jsScript in jsScripts {
    userScripts.append(WKUserScript(source: jsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
  }
  /// Add css injection scripts after primary document finished loading.
  for addCssScript in addCssScripts {
    userScripts.append(WKUserScript(source: addCssScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
  }
  /// Add simple script used by our JS to detect OS
  userScripts.append(WKUserScript(source: "const isAndroid=false,isIos=true;", injectionTime: .atDocumentStart, forMainFrameOnly: false))

  /// Click synthesis: Flutter's synthetic touch delivery prevents WKWebView from
  /// dispatching native click events after goLeft/goRight (when WKContentView is oversized).
  /// This script monitors pointerup events and synthesizes a click if the native one
  /// doesn't fire within 50ms.
  let clickSynthesisScript = """
  (function() {
      var pendingClickTimer = null;
      var lastPointerDownPos = null;

      document.addEventListener('pointerdown', function(e) {
          lastPointerDownPos = { x: e.clientX, y: e.clientY };
      }, true);

      document.addEventListener('pointerup', function(e) {
          if (!lastPointerDownPos) return;
          var dx = e.clientX - lastPointerDownPos.x;
          var dy = e.clientY - lastPointerDownPos.y;
          if (Math.sqrt(dx * dx + dy * dy) > 10) return;

          var x = e.clientX;
          var y = e.clientY;
          var target = e.target;

          if (pendingClickTimer) clearTimeout(pendingClickTimer);
          pendingClickTimer = setTimeout(function() {
              pendingClickTimer = null;
              var clickEvent = new MouseEvent('click', {
                  bubbles: true,
                  cancelable: true,
                  view: window,
                  clientX: x,
                  clientY: y,
                  button: 0
              });
              target.dispatchEvent(clickEvent);
          }, 50);
      }, true);

      document.addEventListener('click', function(e) {
          if (pendingClickTimer) {
              clearTimeout(pendingClickTimer);
              pendingClickTimer = null;
          }
      }, true);
  })();
  """
  userScripts.append(WKUserScript(source: clickSynthesisScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
}

func strippedHref(_ href: String) -> String {
  href.components(separatedBy: "#").first?
      .components(separatedBy: "?").first ?? href
}

func chapterLink(before currentHref: String, in readingOrder: [Link]) -> Link? {
  let clean = strippedHref(currentHref)
  guard let idx = readingOrder.firstIndex(where: { strippedHref($0.href) == clean }),
        idx > 0 else { return nil }
  return readingOrder[idx - 1]
}

func chapterLink(after currentHref: String, in readingOrder: [Link]) -> Link? {
  let clean = strippedHref(currentHref)
  guard let idx = readingOrder.firstIndex(where: { strippedHref($0.href) == clean }),
        idx < readingOrder.count - 1 else { return nil }
  return readingOrder[idx + 1]
}

func isBackwardNavigation(from oldHref: String, to newHref: String, in readingOrder: [Link]) -> Bool {
  let cleanOld = strippedHref(oldHref)
  let cleanNew = strippedHref(newHref)
  guard let oldIdx = readingOrder.firstIndex(where: { strippedHref($0.href) == cleanOld }),
        let newIdx = readingOrder.firstIndex(where: { strippedHref($0.href) == cleanNew }) else {
    return false
  }
  return newIdx < oldIdx
}

private func canScroll(locations: Locator.Locations?) -> Bool {
  guard let locations = locations else { return false }
  return locations.domRange != nil || locations.cssSelector != nil || locations.progression != nil
}
