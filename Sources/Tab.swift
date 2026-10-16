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
        return config
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
    /// What the page last looked like, for walking past it and the sheet.
    @Published private(set) var snapshot: UIImage?
    /// One letter, when the tab has been pinned.
    @Published var pin: String?
    /// Showing the article alone, in the Reader's type.
    @Published var reading = false
    /// The site's own icon, once it has been fetched or found on disk.
    @Published var icon: UIImage?
    /// A private tab keeps nothing: no history, no icons on disk, no cookies.
    let isPrivate: Bool

    /// Told how the page scrolls, while a finger is on it or it is coasting.
    var scrolled: ((Scrolled) -> Void)?

    private var watch: [NSKeyValueObservation] = []
    private var lastY: CGFloat = 0
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
        web.allowsLinkPreview = true
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
                    if !self.loading { self.waking = false }
                }
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

    func reload() { web.reload() }
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
        config.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        web.takeSnapshot(with: config) { [weak self] taken, _ in
            MainActor.assumeIsolated {
                // Copied into pixels of its own: what WebKit hands back can
                // go on tracking the live page.
                let image = taken.flatMap(Tab.copy)
                if let self, let image {
                    self.snapshot = image
                    if !self.isPrivate { Snapshots.write(image, for: self.key) }
                }
                done(image)
            }
        }
    }

    /// A picture drawn into a bitmap of its own.
    private static func copy(_ image: UIImage) -> UIImage? {
        guard image.size.width > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let out = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
        return out.cgImage.map { UIImage(cgImage: $0, scale: image.scale, orientation: .up) }
    }

    /// Keeps a picture of the page as it is now, for walking past it and for
    /// the next launch. Only a page on screen can be pictured; the last
    /// picture stays until then.
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
