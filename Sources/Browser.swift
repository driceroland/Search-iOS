import SwiftUI
import WebKit
import Combine

// Everything the app knows: which tabs exist, which one is showing, and what is
// summoned over it.

@MainActor
final class Browser: NSObject, ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeID: Tab.ID?

    @Published var editing = false
    @Published var typed = "" { didSet { guess() } }
    @Published private(set) var offers: [Suggestion] = []
    @Published private(set) var ending: String?
    /// Asked for the sheet of every tab. The sheet's own position belongs to
    /// the gesture that moves it; this only says where it should end up.
    @Published var showingTabs = false
    /// The pill held: the page's own menu.
    @Published var holding = false
    /// Bumped when what was typed can't be anywhere. The field shivers.
    @Published private(set) var refusals = 0
    /// A word over the pill, and gone: the Mac's toasts.
    @Published private(set) var toast: String?
    private var toastTimer: DispatchWorkItem?

    let history = History()
    /// How far the pill is folded. Its own object, so that a page scrolling
    /// redraws the pill and nothing else.
    let chrome = Chrome()

    private var bag = Set<AnyCancellable>()
    private var saving = false

    var active: Tab? { tabs.first { $0.id == activeID } }
    var activeIndex: Int? { tabs.firstIndex { $0.id == activeID } }
    var completed: String { typed + (ending ?? "") }
    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    /// The page either side of this one, as walking the pill reaches them.
    func neighbour(_ step: Int) -> Tab? {
        guard let here = activeIndex else { return nil }
        let there = here + step
        return tabs.indices.contains(there) ? tabs[there] : nil
    }

    override init() {
        super.init()
        Shield.shared.compile()
        Favicons.shared.arrived = { [weak self] key, image in
            for tab in self?.tabs ?? [] where tab.address.flatMap(Favicons.key) == key {
                tab.icon = image
            }
        }
        let saved = Session.read()
        guard !saved.tabs.isEmpty else {
            adopt(Tab())
            editing = true
            return
        }
        // Every tab comes back with its address, title and picture, and
        // none loads until it's shown: the one in front now, the rest when
        // they're reached. Nine tabs from yesterday cost nothing today.
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab(key: entry.key ?? UUID().uuidString)
            prepare(tab)
            tab.pin = entry.pin
            tab.restore(url, title: entry.title)
            tabs.append(tab)
        }
        if tabs.isEmpty { adopt(Tab()) }
        activeID = tabs[min(max(0, saved.active), tabs.count - 1)].id
        active?.wake()
        Snapshots.prune(keeping: Set(tabs.map(\.key)))
        $activeID
            .removeDuplicates()
            .sink { [weak self] id in self?.tabs.first { $0.id == id }?.wake() }
            .store(in: &bag)
    }

    /// The app going to the background: the page in front is pictured, so it
    /// is what comes back first next time.
    func rest() {
        active?.capture()
        remember(now: true)
    }

    // MARK: - tabs

    func newTab() {
        active?.capture()
        let tab = Tab()
        adopt(tab)
        activeID = tab.id
        chrome.unfold(animated: false)
        typed = ""
        editing = true
        showingTabs = false
    }

    /// A link from another app.
    func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        if let active, active.isBlank {
            active.go(to: url)
        } else {
            active?.capture()
            let tab = Tab()
            adopt(tab)
            activeID = tab.id
            tab.go(to: url)
        }
        editing = false
        showingTabs = false
        holding = false
        chrome.unfold(animated: false)
        remember()
    }

    func select(_ tab: Tab) {
        showingTabs = false
        guard tab.id != activeID else { return }
        active?.capture()
        activeID = tab.id
        editing = false
        chrome.unfold(animated: false)
        remember()
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // A pinned tab is put down, not closed: the letter keeps its place.
        if tab.pin != nil {
            tab.close()
            let fresh = Tab()
            prepare(fresh)
            fresh.pin = tab.pin
            if let url = tab.address { fresh.go(to: url) }
            tabs[index] = fresh
            if activeID == tab.id { activeID = fresh.id }
            remember()
            return
        }
        tab.close()
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
            return
        }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
        remember()
    }

    func pin(_ tab: Tab) {
        guard tab.pin == nil else {
            tab.pin = nil
            remember()
            return
        }
        let host = tab.address.map { Address.host($0) } ?? ""
        tab.pin = host.first.map { String($0).uppercased() } ?? "•"
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = max(0, pinnedCount - 1)
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        remember()
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    private func prepare(_ tab: Tab) {
        tab.web.navigationDelegate = self
        tab.web.uiDelegate = self
        tab.scrolled = { [weak self, weak tab] event in
            guard let self, let tab, tab.id == self.activeID else { return }
            self.chrome.follow(event)
        }
        tab.$address
            .removeDuplicates { $0.flatMap(Favicons.key) == $1.flatMap(Favicons.key) }
            .sink { [weak tab] url in
                // Another site: its own icon if one is known, its letter if not.
                tab?.icon = url.flatMap { Favicons.shared.cached($0) }
            }
            .store(in: &bag)
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.remember() }
            .store(in: &bag)
    }

    // MARK: - the page's own menu

    /// The article alone, or the page again.
    func read(_ tab: Tab) {
        if tab.reading {
            tab.reading = false
            tab.web.reload()
            return
        }
        tab.web.evaluateJavaScript(Reader.script) { [weak self, weak tab] answer, _ in
            MainActor.assumeIsolated {
                if (answer as? String) == "read" {
                    tab?.reading = true
                } else {
                    Feel.refuse()
                    self?.say("Nothing to read here")
                }
            }
        }
    }

    /// Ads on or off for the site this tab is on, for this page and every
    /// one after it on the site.
    func shield(_ tab: Tab) {
        guard let host = tab.address?.host()?.lowercased() else { return }
        let off = !Shield.shared.isPaused(on: host)
        Shield.shared.pause(host, off)
        say(off ? "Ads allowed on \(Address.host(tab.address!))" : "Ads blocked on \(Address.host(tab.address!))")
        tab.web.reload()
    }

    func say(_ words: String) {
        toastTimer?.cancel()
        withAnimation(Motion.settle) { toast = words }
        let gone = DispatchWorkItem { [weak self] in
            withAnimation(Motion.settle) { self?.toast = nil }
        }
        toastTimer = gone
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: gone)
    }

    // MARK: - the field

    func edit() {
        typed = active?.address.map { Address.pretty($0) } ?? ""
        holding = false
        editing = true
    }

    func dismiss() {
        editing = false
        typed = ""
    }

    func submit() {
        let target = ending != nil
            ? Address.destination(for: completed)
            : Address.destination(for: typed)
        guard let url = target else {
            refusals += 1
            return
        }
        if active == nil { newTab() }
        active?.go(to: url)
        editing = false
        typed = ""
    }

    func take(_ offer: Suggestion) {
        active?.go(to: offer.url)
        editing = false
        typed = ""
    }

    private func guess() {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            offers = []
            ending = nil
            return
        }
        offers = history.suggestions(for: typed)
        ending = history.completion(for: typed, among: offers)
    }

    // MARK: - between launches

    private func remember(now: Bool = false) {
        if now {
            Session.write(shape)
            return
        }
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            saving = false
            Session.write(shape)
        }
    }

    /// What is written down: every tab that has a web address, private
    /// ones never.
    private var shape: Session.Shape {
        let kept = tabs.filter { !$0.isPrivate && $0.address?.scheme?.hasPrefix("http") == true }
        return Session.Shape(
            tabs: kept.map { tab in
                Session.Entry(
                    url: tab.address!.absoluteString, title: tab.title, pin: tab.pin, key: tab.key
                )
            },
            active: kept.firstIndex { $0.id == activeID } ?? 0
        )
    }
}

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Before each page: the ad blocker goes on or off for the site it's
    /// heading to, so "off for this site" holds for the whole page. Links
    /// that aren't for a browser (mail, phone, the App Store) go to the app
    /// that handles them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame != false {
                UIApplication.shared.open(url)
            }
            return
        }
        if action.targetFrame?.isMainFrame == true {
            Shield.shared.tune(webView.configuration.userContentController, for: url.host()?.lowercased())
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tabs.first { $0.web === webView }?.reading = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.web === webView }),
              let url = tab.address
        else { return }
        if !tab.isPrivate { history.record(url, title: tab.title) }
        Favicons.shared.fetch(for: tab)
    }

    /// A link asking for a new window gets a new tab — a real one, built on
    /// the configuration WebKit hands over, so the page that opened it can
    /// still talk to it ("Sign in with…" windows need `window.opener`).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // The child must not share the opener's content controller: closing
        // the child would strip the opener's scripts (the Mac learned this).
        configuration.userContentController = WKUserContentController()
        let tab = Tab(configuration: configuration)
        active?.capture()
        adopt(tab)
        activeID = tab.id
        chrome.unfold(animated: false)
        return tab.web
    }

    /// A page closing the window it opened.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tabs.first(where: { $0.web === webView }) else { return }
        close(tab)
    }
}

/// The pill's fold: 0 open, 1 folded down to the site's name.
@MainActor
final class Chrome: ObservableObject {
    @Published private(set) var fold: CGFloat = 0

    /// How far a page has to travel to fold the pill all the way.
    private let travel: CGFloat = 44

    func follow(_ event: Scrolled) {
        switch event {
        case .by(let delta):
            let next = min(1, max(0, fold + delta / travel))
            if next != fold { fold = next }
        case .top:
            unfold(animated: true)
        case .rest:
            let target: CGFloat = fold > 0.5 ? 1 : 0
            guard target != fold else { return }
            withAnimation(Motion.settle) { fold = target }
        }
    }

    func unfold(animated: Bool) {
        guard fold != 0 else { return }
        if animated {
            withAnimation(Motion.settle) { fold = 0 }
        } else {
            fold = 0
        }
    }
}

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
        /// The name of its picture on disk.
        var key: String?
    }

    struct Shape: Codable {
        var tabs: [Entry]
        var active: Int
    }

    private static var file: URL { Store.file("session.json") }

    static func read() -> Shape {
        guard let data = try? Data(contentsOf: file),
              let shape = try? JSONDecoder().decode(Shape.self, from: data)
        else { return Shape(tabs: [], active: 0) }
        return shape
    }

    static func write(_ shape: Shape) {
        let file = Session.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
