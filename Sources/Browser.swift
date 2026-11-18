import SwiftUI
import WebKit
import Combine

// Everything the app knows: which tabs exist, which one is showing, and what is
// summoned over it.

@MainActor
final class Browser: NSObject, ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeID: Tab.ID?

    @Published var editing = false {
        didSet {
            // The keyboard leaves the moment the field is put away, not when
            // the field's own exit has finished animating: until then the
            // field would still be first responder, and the keyboard would
            // wait for it.
            if oldValue, !editing {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }
    @Published var typed = "" { didSet { guess() } }
    @Published private(set) var offers: [Suggestion] = []
    @Published private(set) var ending: String?
    /// Asked for the sheet of every tab. The sheet's own position belongs to
    /// the gesture that moves it; this only says where it should end up.
    @Published var showingTabs = false
    /// The pill held: the page's own menu.
    @Published var holding = false
    /// The system's find bar is up; the pill steps aside for it.
    @Published var finding = false
    @Published var settings = false
    /// The bookmarks, and the other devices' tabs.
    @Published var showingBookmarks = false
    @Published var showingOthers = false
    /// "This site", out of the page's menu.
    @Published var siteSheet = false
    /// Held the count: close every tab?
    @Published var askingCloseAll = false
    /// Private tabs behind Face ID until it's given.
    @Published var locked = false
    /// What the search engine proposes for the words typed, when asked to.
    @Published private(set) var searches: [Suggestion] = []
    private var asking: URLSessionDataTask?
    /// Pages closed lately, newest first, to bring back.
    @Published private(set) var closed: [Session.Entry] = []
    private var findWatch: NSObjectProtocol?
    /// Bumped when what was typed can't be anywhere. The field shivers.
    @Published private(set) var refusals = 0
    /// A word over the pill, and gone: the Mac's toasts.
    @Published private(set) var toast: String?
    private var toastTimer: DispatchWorkItem?

    let history = History()
    /// How far the pill is folded. Its own object, so that a page scrolling
    /// redraws the pill and nothing else.
    let chrome = Chrome()
    /// The screen's safe area, for telling each page how much of it the
    /// status bar and the pill cover.
    var safe = EdgeInsets() { didSet { if safe != oldValue { cover() } } }

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
        defer {
            offering = Offering(self, prefs: .shared)
            Sync.shared.browser = self
            if Prefs.shared.sync { Sync.shared.start() }
        }
        Shield.shared.compile()
        Favicons.shared.arrived = { [weak self] key, image in
            for tab in self?.tabs ?? [] where tab.address.flatMap(Favicons.key) == key {
                tab.icon = image
            }
        }
        // Whichever tab comes to the front loads, if it hasn't yet: one
        // brought back from yesterday, or a pin from another device.
        $activeID
            .removeDuplicates()
            .sink { [weak self] id in self?.tabs.first { $0.id == id }?.wake() }
            .store(in: &bag)
        let saved = Session.read()
        guard !saved.tabs.isEmpty else {
            adopt(Tab())
            editing = true
            return
        }
        // Every tab comes back with its address, title and picture, and
        // none loads until it's shown: the one in front now, the rest when
        // they're reached. Nine tabs from yesterday cost nothing today.
        // Tabs left alone longer than asked are closed on the way in;
        // pinned ones never.
        let limit = Prefs.shared.autoClose.interval
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            if let limit, entry.pin == nil, let seen = entry.seen, Date().timeIntervalSince(seen) > limit {
                Snapshots.remove(entry.key ?? "")
                continue
            }
            let tab = Tab(key: entry.key ?? UUID().uuidString)
            prepare(tab)
            tab.pin = entry.pin
            tab.pinID = entry.pinID
            tab.pinHome = entry.home.flatMap(URL.init(string:))
            tab.pinName = entry.pinName
            tab.seen = entry.seen ?? Date()
            tab.restore(url, title: entry.title)
            if tab.icon == nil { Favicons.shared.prefetch(url) }
            tabs.append(tab)
        }
        closed = Session.readClosed()
        if tabs.isEmpty { adopt(Tab()) }
        activeID = tabs[min(max(0, min(saved.active, tabs.count - 1)), tabs.count - 1)].id
        active?.wake()
        Snapshots.prune(keeping: Set(tabs.map(\.key)))
    }

    /// The page offered to one's own Mac, while Handoff is on.
    private(set) var offering: Offering?

    /// The app going to the background: the page in front is pictured, so it
    /// is what comes back first next time.
    func rest() {
        active?.capture()
        remember(now: true)
    }

    // MARK: - tabs

    func newTab(private: Bool = false) {
        active?.capture()
        let tab = `private`
            ? Tab(configuration: Web.configuration(private: true), isPrivate: true)
            : Tab()
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
        tab.seen = Date()
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
            fresh.pinID = tab.pinID
            fresh.pinHome = tab.pinHome
            fresh.pinName = tab.pinName
            if let url = tab.address { fresh.go(to: url) }
            tabs[index] = fresh
            if activeID == tab.id { activeID = fresh.id }
            remember()
            return
        }
        bury(tab)
        tab.close()
        tabs.remove(at: index)
        // The last private tab gone: its cookie jar goes with it.
        if tab.isPrivate, !tabs.contains(where: \.isPrivate) { Web.forgetPrivate() }
        if tabs.isEmpty {
            activeID = nil
            newTab()
            return
        }
        if activeID == tab.id { activeID = tabs[min(index, tabs.count - 1)].id }
        if !tabs.contains(where: \.isPrivate) { locked = false }
        remember()
    }

    /// A closed page, kept to be brought back. Never a private one.
    private func bury(_ tab: Tab) {
        guard !tab.isPrivate, let url = tab.address, url.scheme?.hasPrefix("http") == true else { return }
        closed.insert(Session.Entry(url: url.absoluteString, title: tab.title, pin: nil, key: nil), at: 0)
        if closed.count > 20 { closed.removeLast(closed.count - 20) }
        Session.writeClosed(closed)
    }

    /// The last page closed, or the one picked, open again in front.
    func reopen(_ entry: Session.Entry? = nil) {
        guard let entry = entry ?? closed.first, let url = URL(string: entry.url) else {
            say(String(localized: "Nothing to reopen"))
            return
        }
        closed.removeAll { $0.url == entry.url && $0.title == entry.title }
        Session.writeClosed(closed)
        // An empty tab in front takes it; otherwise it comes back beside it.
        if let here = active, here.isBlank, !here.isPrivate {
            here.go(to: url)
        } else {
            active?.capture()
            let tab = Tab()
            prepare(tab)
            let here = activeIndex.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: min(here, tabs.count))
            tab.go(to: url)
            activeID = tab.id
        }
        editing = false
        showingTabs = false
        chrome.unfold(animated: false)
        remember()
    }

    /// The list of closed pages, gone with the history.
    func forgetClosed() {
        closed = []
        Session.writeClosed([])
    }

    /// Every tab but the pinned ones.
    func closeAll() {
        let going = tabs.filter { $0.pin == nil }
        for tab in going.reversed() { bury(tab) }
        for tab in going { tab.close() }
        tabs.removeAll { $0.pin == nil }
        Web.forgetPrivate()
        locked = false
        activeID = nil
        newTab()
        remember()
    }

    /// A tab dragged to another place among the others.
    func move(_ tab: Tab, before target: Tab) {
        guard tab.id != target.id,
              let from = tabs.firstIndex(where: { $0.id == tab.id }),
              let to = tabs.firstIndex(where: { $0.id == target.id }),
              (tab.pin == nil) == (target.pin == nil)
        else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        remember()
    }

    func pin(_ tab: Tab) {
        guard tab.pin == nil else {
            tab.pin = nil
            tab.pinID = nil
            tab.pinHome = nil
            tab.pinName = nil
            remember()
            return
        }
        let host = tab.address.map { Address.host($0) } ?? ""
        tab.pinID = UUID()
        tab.pinHome = tab.address
        tab.pin = host.first.map { String($0).uppercased() } ?? "•"
        if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
            let home = max(0, pinnedCount - 1)
            if here != home {
                tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
            }
        }
        remember()
    }

    /// A tab made elsewhere (a pin from iCloud), ready to be put in.
    func bring(_ tab: Tab) { prepare(tab) }

    /// The tabs in a new order, from iCloud's pins.
    func setTabs(_ next: [Tab]) {
        for tab in tabs where !next.contains(tab) { tab.close() }
        tabs = next
        if !tabs.contains(where: { $0.id == activeID }) { activeID = tabs.first?.id }
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Tells every page what the status bar and the pill cover, so a page's
    /// fixed bar or button at the bottom sits above the pill, as it does
    /// above Safari's, while the page itself still runs under it.
    func cover() {
        for tab in tabs { cover(tab) }
    }

    private func cover(_ tab: Tab) {
        guard safe.bottom > 0 || safe.top > 0 else { return }
        let foot = Metrics.foot(safe.bottom)
        tab.cover(top: safe.top, bottom: foot, least: safe.bottom + Metrics.pillFolded, most: foot)
    }

    private func prepare(_ tab: Tab) {
        tab.web.navigationDelegate = self
        tab.web.uiDelegate = self
        let controller = tab.web.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Zap.handler)
        controller.add(ZapRelay(self), name: Zap.handler)
        cover(tab)
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
                    self?.say(String(localized: "Nothing to read here"))
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
        say(off ? String(localized: "Ads allowed on \(Address.host(tab.address!))") : String(localized: "Ads blocked on \(Address.host(tab.address!))"))
        tab.web.reload()
    }

    /// The share sheet, with the page itself among the things shared, so
    /// iOS can offer to add it to the Home Screen.
    func share(_ tab: Tab) {
        guard let url = tab.address else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = tab.label
        info.outputType = .general
        Present.share([url, tab.web, info, tab.web.viewPrintFormatter()], extra: [PDFActivity(tab: tab)])
    }

    /// The system's own find bar, over the keyboard.
    func find(_ tab: Tab) {
        finding = true
        tab.web.findInteraction?.presentFindNavigator(showingReplace: false)
        // The find bar rides on the keyboard and goes with it.
        findWatch = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                withAnimation(Motion.quick) { self.finding = false }
                if let watch = self.findWatch { NotificationCenter.default.removeObserver(watch) }
                self.findWatch = nil
            }
        }
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

    /// A link held and sent to a tab of its own, in front or behind.
    func open(_ url: URL, private: Bool, behind: Bool) {
        let tab = `private`
            ? Tab(configuration: Web.configuration(private: true), isPrivate: true)
            : Tab()
        prepare(tab)
        let here = activeIndex.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: min(here, tabs.count))
        tab.go(to: url)
        if behind {
            Feel.tick()
            say(String(localized: "Opened behind"))
        } else {
            active?.capture()
            activeID = tab.id
            chrome.unfold(animated: false)
        }
        remember()
    }

    // MARK: - the field

    /// The address in front, to paste somewhere else.
    func copyAddress(_ tab: Tab) {
        guard let url = tab.address else { return }
        UIPasteboard.general.url = url
        say(String(localized: "Address copied"))
    }

    /// What was copied: gone to, or searched for.
    func pasteAndGo() {
        let words = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
        guard let url = Address.destination(for: words) else {
            say(String(localized: "Nothing to paste"))
            return
        }
        holding = false
        if active == nil { newTab() }
        active?.go(to: url)
        putAway()
    }

    func edit() {
        typed = active?.address.map { Address.pretty($0) } ?? ""
        holding = false
        editing = true
    }

    func dismiss() {
        putAway()
    }

    /// The field goes back to being the pill, on the keyboard's own curve,
    /// whichever way it was put away: tapped outside, dragged down, Go, or a
    /// suggestion. Said here rather than left to whoever watches `editing`,
    /// so no way out of the field can skip the animation.
    private func putAway() {
        // The keyboard is let go first, on its own: giving up the caret
        // inside the animated change made SwiftUI settle the field's exit
        // there and then, unanimated (the field vanished in one frame).
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(UIAccessibility.isReduceMotionEnabled ? Motion.quick : Keyboard.curve(0.3)) {
            editing = false
        }
        // What was typed stays while the field fades: emptied now, the
        // placeholder would flash in it on the way out. `edit` and `newTab`
        // set it afresh.
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
        putAway()
    }

    func take(_ offer: Suggestion) {
        if let id = offer.tab, let there = tabs.first(where: { $0.id == id }) {
            putAway()
            // A blank tab that was only ever for typing goes.
            if let here = active, here.isBlank, here.id != there.id {
                tabs.removeAll { $0.id == here.id }
                here.close()
            }
            select(there)
            return
        }
        active?.go(to: offer.url)
        putAway()
    }

    private func guess() {
        let words = typed.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else {
            offers = []
            searches = []
            ending = nil
            asking?.cancel()
            return
        }
        let open = openTabs(for: words)
        var taken = Set(open.map(\.key))
        let marked = bookmarked(words).filter { !taken.contains($0.key) }
        taken.formUnion(marked.map(\.key))
        let places = history.suggestions(for: typed, limit: 4).filter { !taken.contains($0.key) }
        offers = Array((open + marked + places).prefix(4))
        ending = history.completion(for: typed, among: places)
        suggestSearches(for: words)
    }

    /// Bookmarks whose name or address has the words in it.
    private func bookmarked(_ words: String) -> [Suggestion] {
        let needle = words.lowercased()
        guard needle.count >= 2 else { return [] }
        return Bookmarks.flat(Bookmarks.shared.roots).compactMap { mark -> Suggestion? in
            guard let raw = mark.url, let url = URL(string: raw) else { return nil }
            let key = Address.pretty(url).lowercased()
            let bare = key.hasPrefix("www.") ? String(key.dropFirst(4)) : key
            guard bare.hasPrefix(needle) || bare.contains("." + needle) || mark.title.lowercased().contains(needle)
            else { return nil }
            return Suggestion(key: bare, title: mark.title, url: url)
        }
        .prefix(2)
        .map { $0 }
    }

    /// Tabs already open on what is being typed, other than this one.
    private func openTabs(for words: String) -> [Suggestion] {
        let needle = words.lowercased()
        guard needle.count >= 2 else { return [] }
        let privately = active?.isPrivate ?? false
        return tabs.compactMap { tab -> Suggestion? in
            guard tab.id != activeID, tab.isPrivate == privately, let url = tab.address else { return nil }
            let key = Address.pretty(url).lowercased()
            let bare = key.hasPrefix("www.") ? String(key.dropFirst(4)) : key
            guard bare.hasPrefix(needle) || bare.contains("." + needle) || tab.title.lowercased().contains(needle)
            else { return nil }
            return Suggestion(key: bare, title: tab.title, url: url, tab: tab.id)
        }
        .prefix(2)
        .map { $0 }
    }

    /// The engine's own suggestions, when they were asked for, and never
    /// from a private tab: what is typed goes to the engine as it is typed.
    private func suggestSearches(for words: String) {
        asking?.cancel()
        guard Prefs.shared.engineSuggestions, active?.isPrivate == false,
              Address.url(from: words) == nil,
              let url = Prefs.shared.engine.suggestions(for: words)
        else {
            searches = []
            return
        }
        let template = Prefs.shared.searchTemplate
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let found = data.map(Engine.parseSuggestions) ?? []
            DispatchQueue.main.async {
                guard let self, self.typed.trimmingCharacters(in: .whitespaces) == words else { return }
                self.searches = found.prefix(4).compactMap { phrase in
                    Engine.url(for: phrase, template: template).map {
                        Suggestion(key: phrase, title: "", url: $0, search: true)
                    }
                }
            }
        }
        asking = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard self?.asking === task else { return }
            task.resume()
        }
    }

    // MARK: - between launches

    func remember(now: Bool = false) {
        if now {
            Session.write(shape)
            Sync.shared.publish(self)
            return
        }
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            saving = false
            Session.write(shape)
            Sync.shared.publish(self)
        }
    }

    /// What is written down: every tab that has a web address, private
    /// ones never.
    private var shape: Session.Shape {
        let kept = tabs.filter { !$0.isPrivate && $0.address?.scheme?.hasPrefix("http") == true }
        return Session.Shape(
            tabs: kept.map { tab in
                Session.Entry(
                    url: tab.address!.absoluteString, title: tab.title, pin: tab.pin, key: tab.key,
                    seen: tab.id == activeID ? Date() : tab.seen,
                    pinID: tab.pinID, home: tab.pinHome?.absoluteString, pinName: tab.pinName
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
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow, preferences)
            return
        }
        if !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame != false {
                UIApplication.shared.open(url)
            }
            return
        }
        if action.targetFrame?.isMainFrame == true {
            Shield.shared.tune(webView.configuration.userContentController, for: url.host()?.lowercased())
            // The computer's version of the site, when it was asked for.
            preferences.preferredContentMode = Sites.shared.prefs(url).desktop == true ? .desktop : .mobile
        }
        decisionHandler(.allow, preferences)
    }

    /// The site's text size and hidden bits, as soon as the page is its own.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.web === webView }) else { return }
        apply(Sites.shared.prefs(tab.address), to: tab)
        tab.readGround()
    }

    /// The camera and the microphone: as decided for the site, or asked.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let site = URL(string: "\(origin.protocol)://\(origin.host)")
        let prefs = Sites.shared.prefs(site)
        let asked: [Choice]
        switch type {
        case .camera: asked = [prefs.camera ?? .ask]
        case .microphone: asked = [prefs.microphone ?? .ask]
        default: asked = [prefs.camera ?? .ask, prefs.microphone ?? .ask]
        }
        if asked.contains(.deny) {
            decisionHandler(.deny)
        } else if asked.allSatisfy({ $0 == .allow }) {
            decisionHandler(.grant)
        } else {
            decisionHandler(.prompt)
        }
    }

    /// What a page can't show is a download.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let attachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") ?? false
        decisionHandler(response.canShowMIMEType && !attachment ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.take(download, from: self)
        // A tab that only ever held the download has nothing to show: it
        // goes, and the page that offered the file is in front again.
        if let tab = tabs.first(where: { $0.web === webView }), webView.backForwardList.currentItem == nil {
            close(tab)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.take(download, from: self)
    }

    /// Holding a link: open it in a new tab here or behind, copy it, share it.
    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationFor element: WKContextMenuElementInfo,
        completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void
    ) {
        guard let url = element.linkURL else {
            completionHandler(nil)
            return
        }
        let opener = tabs.first { $0.web === webView }
        // No preview of our own: WebKit shows the page itself above the menu.
        let menu = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    self?.open(url, private: opener?.isPrivate ?? false, behind: false)
                },
                UIAction(title: "Open Behind", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
                    self?.open(url, private: opener?.isPrivate ?? false, behind: true)
                },
                UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
                    UIPasteboard.general.url = url
                },
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                    Present.share([url])
                },
            ])
        }
        completionHandler(menu)
    }

    /// The preview tapped: the link opens here.
    func webView(
        _ webView: WKWebView,
        contextMenuForElement element: WKContextMenuElementInfo,
        willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating
    ) {
        guard let url = element.linkURL else { return }
        animator.addCompletion { [weak webView] in
            webView?.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let tab = tabs.first { $0.web === webView }
        tab?.reading = false
        tab?.failure = nil
    }

    /// A page that couldn't be reached: said, with a way to try again.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: Error) {
        let error = error as NSError
        // Stopped, replaced by another page, or handed to a download or an
        // app: not failures.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", [102, 204].contains(error.code) { return }
        guard let tab = tabs.first(where: { $0.web === webView }) else { return }
        let url = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab.address
        guard let url else { return }
        tab.failure = Tab.Failure(url: url, reason: Browser.reason(error))
    }

    private static func reason(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return String(localized: "You're offline.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return String(localized: "This site can't be found. Check the address.")
        case NSURLErrorTimedOut:
            return String(localized: "The site took too long to answer.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot:
            return String(localized: "The site's secure connection can't be trusted.")
        case NSURLErrorCannotConnectToHost:
            return String(localized: "The site isn't answering.")
        default:
            return error.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.web === webView }),
              let url = tab.address
        else { return }
        if !tab.isPrivate { history.record(url, title: tab.title) }
        Favicons.shared.fetch(for: tab)
        tab.readGround()
        // Again once the page is built: a page can set its own text size.
        apply(Sites.shared.prefs(url), to: tab)
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
        // A window opened from a private tab is private too: it shares the
        // opener's store, which WebKit has already put in the configuration.
        let opener = tabs.first { $0.web === webView }
        let tab = Tab(configuration: configuration, isPrivate: opener?.isPrivate ?? false)
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
    /// Where the fold came to rest: folded or open. Pages are told only
    /// when it settles, so a fixed button doesn't jitter with every scroll.
    private(set) var folded = false {
        didSet { if folded != oldValue { settled?() } }
    }
    var settled: (() -> Void)?

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
            folded = target == 1
            guard target != fold else { return }
            withAnimation(Motion.settle) { fold = target }
        }
    }

    func unfold(animated: Bool) {
        folded = false
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
        /// When it was last the one in front.
        var seen: Date? = nil
        /// A pin's id, the page it was pinned at, its name: the Mac's.
        var pinID: UUID? = nil
        var home: String? = nil
        var pinName: String? = nil
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

    private static var closedFile: URL { Store.file("closed.json") }

    static func readClosed() -> [Entry] {
        guard let data = try? Data(contentsOf: closedFile),
              let list = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return list
    }

    static func writeClosed(_ list: [Entry]) {
        let file = closedFile
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    static func write(_ shape: Shape) {
        let file = Session.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(shape) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}
