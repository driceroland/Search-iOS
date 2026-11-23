import SwiftUI
import WebKit

// One tab, one web view, kept alive for as long as the tab is. Switching is a
// swap, not a reload.

enum Web {
    @MainActor static func configuration(private: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = `private` ? privateStore : .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.applicationNameForUserAgent = userAgentTail
        // A video's own full-screen button takes the whole screen.
        config.preferences.isElementFullscreenEnabled = true
        // A web link held is ours to show (a live peek): iOS's own preview
        // and menu stay out of the way, links only.
        config.userContentController.addUserScript(callout)
        return config
    }

    /// Put back whenever a tab's scripts are rebuilt (Shield.tune).
    @MainActor static var callout: WKUserScript {
        WKUserScript(
            source: """
            (function () {
              var s = document.createElement('style');
              s.textContent = 'a[href^="http"] { -webkit-touch-callout: none !important; }';
              (document.head || document.documentElement).appendChild(s);
            })();
            """,
            injectionTime: .atDocumentEnd, forMainFrameOnly: false)
    }

    /// One cookie jar for every private tab open now, kept in memory only and
    /// let go when the last of them closes.
    @MainActor static var privateStore: WKWebsiteDataStore {
        if let kept = privateKept { return kept }
        let fresh = WKWebsiteDataStore.nonPersistent()
        privateKept = fresh
        return fresh
    }
    @MainActor private static var privateKept: WKWebsiteDataStore?
    @MainActor static func forgetPrivate() { privateKept = nil }

    /// Left alone, WKWebView names no browser at all, and sites serve it their
    /// oldest layout or a captcha. This is the tail Safari sends, with
    /// Safari's version taken from the system's: Safari's major version is
    /// iOS's from iOS 26 on, and was iOS's own before that too.
    static let userAgentTail: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
    }()
}

/// What a page's scrolling tells the pill.
enum Scrolled {
    case by(CGFloat)
    case top
    case rest
}

@MainActor
final class Tab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    /// The name its picture is kept under between launches.
    let key: String
    let web: WKWebView

    @Published private(set) var title = ""
    @Published private(set) var address: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The colour the page asks to be framed in, for the band under the
    /// status bar.
    @Published private(set) var tint: UIColor?
    /// The page's own background, for when it names no colour of its own.
    @Published private(set) var ground: UIColor?
    /// The colour of what's at the very top of the page as it shows now
    /// (its bar, its header, its banner), read as Safari does, again as the
    /// page scrolls: what goes behind the clock.
    @Published private(set) var edge: UIColor?
    private var edgeRead = Date.distantPast

    /// Behind the clock: what the page shows at its top, else the colour it
    /// names for itself, else its background.
    var behindClock: UIColor? { edge ?? tint ?? ground }

    /// The colour of a Duo's rail beside the page: the page's own background,
    /// as Safari does there, steady as the page scrolls; not its top bar,
    /// which made a white page's rail black.
    var railColour: UIColor? { ground ?? tint }
    /// What the page last looked like, for walking past it and the sheet.
    @Published private(set) var snapshot: UIImage?
    /// One letter, when the tab has been pinned.
    @Published var pin: String?
    /// The pin's own name for it everywhere (the Mac's PinDef id), the page
    /// it was pinned at, and a name given to it, if any.
    var pinID: UUID?
    var pinHome: URL?
    var pinName: String?
    /// Showing the article alone, in the Reader's type.
    @Published var reading = false
    /// The site's own icon, once it has been fetched or found on disk.
    @Published var icon: UIImage?
    /// A private tab keeps nothing: no history, no icons on disk, no cookies.
    let isPrivate: Bool
    /// A page that couldn't be opened: where, and why, said plainly.
    struct Failure: Equatable {
        let url: URL
        let reason: String
    }
    @Published var failure: Failure?

    /// The page's text size, 1 for the site's own.
    @Published var textZoom: Double = 1
    /// When it was last the one in front, for closing tabs left alone.
    var seen = Date()

    /// Told how the page scrolls, while a finger is on it or it is coasting.
    var scrolled: ((Scrolled) -> Void)?

    private var watch: [NSKeyValueObservation] = []
    private var lastY: CGFloat = 0
    /// A pull from the top, 0 to 1 at the distance that reloads.
    @Published private(set) var pull: CGFloat = 0
    static let pullReach: CGFloat = 80
    private var startedAtTop = false
    /// Brought back from the last launch and not shown since: it has an
    /// address, a title and a picture, and no page until it's looked at.
    private(set) var pending: URL?
    /// Woken and not drawn yet: its picture stays over the page until the
    /// page has something to show, so waking a tab never flashes white.
    @Published private(set) var waking = false

    var isBlank: Bool { address == nil }

    var label: String {
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return String(localized: "New tab")
    }

    /// The site's first letter, for where its icon will go.
    var letter: String {
        guard let address else { return "" }
        return Address.host(address).first.map { String($0).uppercased() } ?? ""
    }

    var short: String {
        address.map { Address.host($0) } ?? String(localized: "Search or enter an address")
    }

    init(
        configuration: WKWebViewConfiguration? = nil,
        isPrivate: Bool = false,
        key: String = UUID().uuidString
    ) {
        self.isPrivate = isPrivate
        self.key = key
        web = WKWebView(frame: .zero, configuration: configuration ?? Web.configuration())
        super.init()
        web.allowsBackForwardNavigationGestures = true
        // A link held is peeked by Search (Peeker), live and scrollable;
        // iOS's own frozen preview would take the hold first.
        web.allowsLinkPreview = false
        web.isInspectable = true
        if #available(iOS 26.0, *) {
            // WebKit is told what's covered (see `cover`) and does the rest.
            web.scrollView.contentInsetAdjustmentBehavior = .never
        } else {
            web.scrollView.contentInsetAdjustmentBehavior = .always
            web.scrollView.contentInset.bottom = Metrics.pillRoom
            web.scrollView.verticalScrollIndicatorInsets.bottom = Metrics.pillRoom
        }
        web.scrollView.delegate = self
        web.isFindInteractionEnabled = true
        Shield.shared.protect(web.configuration.userContentController)
        // Pull the page down past its top to load it again: our own, not
        // UIRefreshControl, which changes the scroll view's insets and
        // left the page under the clock once it was done.

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.title = self?.web.title ?? "" }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.web.url,
                          fresh.absoluteString != "about:blank"
                    else { return }
                    self.address = fresh
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.progress = self.web.estimatedProgress
                    if self.waking, self.progress >= 0.6 { self.waking = false }
                }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading = self.web.isLoading
                    if !self.loading {
                        self.waking = false
                        self.readGround()
                        self.readEdge()
                    }
                }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoBack = self?.web.canGoBack ?? false }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoForward = self?.web.canGoForward ?? false }
            },
            web.observe(\.fullscreenState, options: [.new]) { web, _ in
                MainActor.assumeIsolated {
                    Shortcuts.turning = web.fullscreenState == .inFullscreen || web.fullscreenState == .enteringFullscreen
                }
            },
            // The page's background as soon as it paints it, and whenever it
            // changes: the clock's colour follows it from the first load.
            web.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.readGround() }
            },
            web.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.tint = self?.web.themeColor }
            },
        ]
    }

    func go(to url: URL) {
        pending = nil
        address = url
        title = ""
        web.load(URLRequest(url: url))
    }

    /// A tab from the last launch: everything but the page.
    func restore(_ url: URL, title: String) {
        pending = url
        address = url
        self.title = title
        snapshot = Snapshots.read(key)
    }

    /// Loads the page a restored tab has been holding a place for.
    func wake() {
        guard let url = pending else { return }
        pending = nil
        waking = snapshot != nil
        web.load(URLRequest(url: url))
    }

    /// What's at the top of the page, asked of the page: the first element
    /// under its top edge that has a colour of its own, from the left where
    /// logos don't sit.
    func readEdge(force: Bool = true) {
        guard !isBlank, failure == nil else { if edge != nil { edge = nil }; return }
        let now = Date()
        guard force || now.timeIntervalSince(edgeRead) > 0.15 else { return }
        edgeRead = now
        web.evaluateJavaScript(Tab.edgeScript) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let colour = (result as? String).flatMap(Tab.colour(css:))
                if colour != self.edge { self.edge = colour }
            }
        }
    }

    private static let edgeScript = """
    (function(){
      function bg(e){ while (e && e.nodeType === 1) {
        var c = getComputedStyle(e).backgroundColor;
        var m = c && c.match(/rgba?\\(([^)]+)\\)/);
        if (m) { var p = m[1].split(','); if (p.length < 4 || parseFloat(p[3]) > 0.5) return c; }
        e = e.parentElement; } return null; }
      var w = window.innerWidth, picks = [6, w / 2, w - 6], seen = {};
      for (var i = 0; i < picks.length; i++) {
        var c = bg(document.elementFromPoint(picks[i], 1));
        if (c) { seen[c] = (seen[c] || 0) + 1; if (seen[c] > 1) return c; }
      }
      return bg(document.elementFromPoint(6, 1)) || bg(document.body) || bg(document.documentElement);
    })()
    """

    /// "rgb(1, 2, 3)" or "rgba(1, 2, 3, 0.9)", as a colour.
    static func colour(css: String) -> UIColor? {
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        let parts = css[css.index(after: open)..<close].split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard parts.count >= 3 else { return nil }
        let alpha = parts.count > 3 ? parts[3] : 1
        guard alpha > 0.5 else { return nil }
        return UIColor(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: 1)
    }

    /// The colour the page is painted, read once it has drawn.
    func readGround() {
        let colour = web.underPageBackgroundColor
        if colour != ground { ground = colour }
    }

    func reload() { web.reload() }
    func stop() { web.stopLoading() }

    private func pulled() {
        #if DEBUG
        Probe.note("pulled")
        #endif
        Feel.tick()
        if pending != nil { wake() } else { web.reload() }
    }
    func back() { web.goBack() }
    func forward() { web.goForward() }

    /// What of the page the status bar and the pill cover. From iOS 26 WebKit
    /// lays fixed and sticky elements out inside what's left, and lets the
    /// page scroll on under the covers; before, the page only learns the
    /// sizes its viewport can take (for lvh/svh), and the scroll view keeps
    /// room at the foot.
    func cover(top: CGFloat, bottom: CGFloat, least: CGFloat, most: CGFloat) {
        if #available(iOS 26.0, *) {
            let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
            if web.obscuredContentInsets != insets { web.obscuredContentInsets = insets }
            // As in Safari: at the top, the page starts below the clock (the
            // band), and only scrolling takes it under. Without this the
            // band was there on load and gone once the page came back up.
            if web.scrollView.contentInset.top != top {
                web.scrollView.contentInset.top = top
            }
            // And the end of the page clear of the bar: obscured insets alone
            // left the last stretch of every page under the pill, out of
            // reach. The folded bar's room, since reaching the end folds it.
            if web.scrollView.contentInset.bottom != least {
                web.scrollView.contentInset.bottom = least
            }
            web.scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
        let low = UIEdgeInsets(top: top, left: 0, bottom: least, right: 0)
        let high = UIEdgeInsets(top: top, left: 0, bottom: most, right: 0)
        if web.minimumViewportInset != low || web.maximumViewportInset != high {
            web.setMinimumViewportInset(low, maximumViewportInset: high)
        }
    }

    /// The page as it is this instant, as a view of its own: what moves in
    /// its place while it's walked or shrinks under the sheet, so the page
    /// itself is never resized and never re-lays itself out.
    /// The page as it is on screen this instant, as a bitmap: WebKit's own
    /// snapshot of what it has drawn. (A picture drawn from the view
    /// hierarchy, or a snapshot view, isn't a bitmap of a web view at all: it
    /// keeps showing the page live, at its place on screen, whatever scale
    /// or offset it is given — the card that looked "re-laid out".)
    func snap(_ done: @escaping @MainActor (UIImage?) -> Void) {
        guard !isBlank, web.window != nil, web.bounds.width > 0 else {
            done(nil)
            return
        }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        // The whole of it, the band under the clock included: left to
        // itself WebKit pictures only what isn't covered, and the card
        // came out shifted up with a sliver of the band at its edge.
        config.rect = web.bounds
        config.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: config) { [weak self] taken, _ in
            MainActor.assumeIsolated {
                // Copied into pixels of its own: what WebKit hands back can
                // go on tracking the live page.
                let image = taken.flatMap { Tab.copy($0) }
                // Not kept while the page is still coming in: a card of a
                // blank page in the making says less than the old picture.
                if let self, let image, !(self.loading && self.progress < 0.8) {
                    self.snapshot = image
                    if !self.isPrivate { Snapshots.write(image, for: self.key) }
                }
                done(image)
            }
        }
    }

    /// A picture drawn into a bitmap of its own.
    private static func copy(_ image: UIImage, down: CGFloat = 0, fill: UIColor = .white) -> UIImage? {
        guard image.size.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let out = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            if down > 0 {
                fill.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
            }
            image.draw(at: CGPoint(x: 0, y: down))
        }
        return out.cgImage.map { UIImage(cgImage: $0, scale: image.scale, orientation: .up) }
    }

    /// Keeps a picture of the page as it is now, for walking past it and for
    /// the next launch. Only a page on screen can be pictured; the last
    /// picture stays until then.
    /// The page as it is on screen, at once: what the screen shows, drawn
    /// in this very frame. For a motion that can't wait for WebKit's own
    /// picture, which comes a few frames later.
    func now() -> UIImage? {
        guard !isBlank, web.window != nil, web.bounds.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: web.bounds, format: format).image { _ in
            _ = web.drawHierarchy(in: web.bounds, afterScreenUpdates: false)
        }
        // Kept for the card too, always: the page zooms into its card with
        // this picture, and a card still showing an older one (a page
        // mid-load kept its last) changed under it as the zoom handed over.
        keep(image)
        return image
    }

    /// The card's picture, as the page moving into it shows.
    func keep(_ image: UIImage) {
        snapshot = image
        if !isPrivate { Snapshots.write(image, for: key) }
    }

    func capture() {
        snap { _ in }
    }

    func close() {
        Snapshots.remove(key)
        watch = []
        scrolled = nil
        web.scrollView.delegate = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        // Off the screen for good: a closed page never shows behind the
        // tab that took its place.
        web.removeFromSuperview()
    }
}

extension Tab: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ view: UIScrollView) {
        lastY = view.contentOffset.y
        startedAtTop = view.contentOffset.y <= -view.adjustedContentInset.top + 1
    }

    func scrollViewDidScroll(_ view: UIScrollView) {
        // How far a pull from the top has gone, for the arrow that shows it.
        let past = -view.adjustedContentInset.top - view.contentOffset.y
        let next = startedAtTop && view.isTracking ? max(0, min(1, past / Tab.pullReach)) : 0
        if abs(next - pull) > 0.01 || (next == 0) != (pull == 0) { pull = next }
        guard view.isTracking || view.isDecelerating else { return }
        // What reaches the top changes as the page moves.
        readEdge(force: false)
        let y = view.contentOffset.y
        let top = -view.adjustedContentInset.top
        let bottom = view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
        defer { lastY = y }
        if y <= top + 1 {
            scrolled?(.top)
            return
        }
        // The bounce at the foot isn't the reader asking for anything.
        guard y < bottom else { return }
        scrolled?(.by(y - lastY))
    }

    func scrollViewDidEndDragging(_ view: UIScrollView, willDecelerate: Bool) {
        // Let go well past the top: load the page again.
        // Only a pull that began at the top: a fling back up that
        // overshoots isn't asking for anything.
        if startedAtTop, view.contentOffset.y < -view.adjustedContentInset.top - Tab.pullReach { pulled() }
        pull = 0
        if !willDecelerate { scrolled?(.rest) }
    }


    func scrollViewDidEndDecelerating(_ view: UIScrollView) {
        readGround()
        scrolled?(.rest)
    }

    func scrollViewDidScrollToTop(_ view: UIScrollView) {
        scrolled?(.top)
    }
}

/// Each tab's last picture, kept between launches so a restored tab can be
/// walked past and seen in the sheet before its page has loaded. Small JPEGs,
/// one per tab, gone when the tab is closed.
enum Snapshots {
    private static let folder = Store.folder.appendingPathComponent("snapshots", isDirectory: true)
    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".jpg") }

    static func read(_ key: String) -> UIImage? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return UIImage(data: data, scale: UIScreen.main.scale)
    }

    static func write(_ image: UIImage, for key: String) {
        let file = file(key)
        DispatchQueue.global(qos: .utility).async {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    static func remove(_ key: String) {
        let file = file(key)
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: file) }
    }

    /// Every picture whose tab is gone: left over from a launch that ended
    /// before it could clear up after itself.
    static func prune(keeping keys: Set<String>) {
        DispatchQueue.global(qos: .utility).async {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !keys.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

#if DEBUG
/// Test runs read what happened from a file in the app's tmp folder.
enum Probe {
    static func note(_ line: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("probe.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try? (text + line + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
#endif
