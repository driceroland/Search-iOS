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
        // Left alone, WKWebView names no browser at all, and sites serve it
        // their oldest layout. This is the string Safari sends.
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        return config
    }
}

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let web: WKWebView

    @Published private(set) var title = ""
    @Published private(set) var address: URL?
    @Published private(set) var progress: Double = 0
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// One letter, when the tab has been pinned.
    @Published var pin: String?

    private var watch: [NSKeyValueObservation] = []

    var isBlank: Bool { address == nil }

    var label: String {
        if !title.isEmpty { return title }
        if let address { return Address.pretty(address) }
        return "New Tab"
    }

    var short: String {
        address.map { Address.pretty($0) } ?? "Search or enter an address"
    }

    init() {
        web = WKWebView(frame: .zero, configuration: Web.configuration())
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never

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
        ]
    }

    func go(to url: URL) {
        address = url
        title = ""
        web.load(URLRequest(url: url))
    }

    func reload() { web.reloadFromOrigin() }
    func back() { web.goBack() }
    func forward() { web.goForward() }

    func close() {
        watch = []
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }
}
