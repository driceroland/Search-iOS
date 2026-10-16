import SwiftUI
import WebKit

// One tab, one web view, kept alive for as long as the tab is. Switching is a
// swap, not a reload.

enum Web {
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .audio
        config.applicationNameForUserAgent = userAgentTail
        return config
    }

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
    /// What the page last looked like, for walking past it and the sheet.
    @Published private(set) var snapshot: UIImage?
    /// One letter, when the tab has been pinned.
    @Published var pin: String?
    /// The site's own icon, once it has been fetched or found on disk.
    @Published var icon: UIImage?
    /// A private tab keeps nothing: no history, no icons on disk, no cookies.
    let isPrivate: Bool

    /// Told how the page scrolls, while a finger is on it or it is coasting.
    var scrolled: ((Scrolled) -> Void)?

    private var watch: [NSKeyValueObservation] = []
    private var lastY: CGFloat = 0

    var isBlank: Bool { address == nil }

    var label: String {
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New tab"
    }

    /// The site's first letter, for where its icon will go.
    var letter: String {
        guard let address else { return "" }
        return Address.host(address).first.map { String($0).uppercased() } ?? ""
    }

    var short: String {
        address.map { Address.host($0) } ?? "Search or enter an address"
    }

    init(configuration: WKWebViewConfiguration = Web.configuration(), isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        web.allowsBackForwardNavigationGestures = true
        web.allowsLinkPreview = true
        web.isInspectable = true
        web.scrollView.contentInsetAdjustmentBehavior = .always
        web.scrollView.contentInset.bottom = Metrics.pillRoom
        web.scrollView.verticalScrollIndicatorInsets.bottom = Metrics.pillRoom
        web.scrollView.delegate = self

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
                MainActor.assumeIsolated { self?.progress = self?.web.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.loading = self?.web.isLoading ?? false }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoBack = self?.web.canGoBack ?? false }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.canGoForward = self?.web.canGoForward ?? false }
            },
            web.observe(\.themeColor, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.tint = self?.web.themeColor }
            },
        ]
    }

    func go(to url: URL) {
        address = url
        title = ""
        web.load(URLRequest(url: url))
    }

    func reload() { web.reload() }
    func back() { web.goBack() }
    func forward() { web.goForward() }

    /// Keeps a picture of the page as it is now. Only a page on screen can be
    /// pictured; the last picture stays until then.
    func capture() {
        guard !isBlank, web.window != nil, web.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        config.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
            }
        }
    }

    func close() {
        watch = []
        scrolled = nil
        web.scrollView.delegate = nil
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }
}

extension Tab: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ view: UIScrollView) {
        lastY = view.contentOffset.y
    }

    func scrollViewDidScroll(_ view: UIScrollView) {
        guard view.isTracking || view.isDecelerating else { return }
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
        if !willDecelerate { scrolled?(.rest) }
    }

    func scrollViewDidEndDecelerating(_ view: UIScrollView) {
        scrolled?(.rest)
    }

    func scrollViewDidScrollToTop(_ view: UIScrollView) {
        scrolled?(.top)
    }
}
