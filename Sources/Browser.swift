import SwiftUI
import WebKit
import Combine

// Everything the app knows: which tabs exist, which one is showing, and whether
// the address field is up.

@MainActor
final class Browser: NSObject, ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published var activeID: Tab.ID?

    @Published var editing = false
    @Published var typed = "" { didSet { guess() } }
    @Published private(set) var offers: [Suggestion] = []
    @Published private(set) var ending: String?
    /// True while the grid of tabs is up.
    @Published var showingTabs = false
    /// Bumped when what was typed can't be anywhere. The field shivers.
    @Published private(set) var refusals = 0

    private static let flight = Animation.spring(response: 0.42, dampingFraction: 0.84)

    let history = History()

    private var bag = Set<AnyCancellable>()
    private var saving = false

    var active: Tab? { tabs.first { $0.id == activeID } }
    var completed: String { typed + (ending ?? "") }
    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    override init() {
        super.init()
        let saved = Session.read()
        guard !saved.tabs.isEmpty else {
            adopt(Tab())
            editing = true
            return
        }
        for entry in saved.tabs {
            guard let url = URL(string: entry.url) else { continue }
            let tab = Tab()
            prepare(tab)
            tab.pin = entry.pin
            tabs.append(tab)
            tab.go(to: url)
        }
        if tabs.isEmpty { adopt(Tab()) }
        activeID = tabs[min(max(0, saved.active), tabs.count - 1)].id
    }

    // MARK: - tabs

    func newTab() {
        let tab = Tab()
        adopt(tab)
        activeID = tab.id
        typed = ""
        editing = true
        showingTabs = false
    }

    func select(_ tab: Tab) {
        guard tab.id != activeID else {
            withAnimation(Browser.flight) { showingTabs = false }
            return
        }
        activeID = tab.id
        editing = false
        remember()
        withAnimation(Browser.flight) { showingTabs = false }
    }

    func openTabs() {
        withAnimation(Browser.flight) { showingTabs = true }
    }

    /// Swiping the bar walks the row, and comes round to the first again.
    func step(_ direction: Int) {
        guard tabs.count > 1, let here = tabs.firstIndex(where: { $0.id == activeID }) else { return }
        activeID = tabs[(here + direction + tabs.count) % tabs.count].id
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
        let host = tab.address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
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
        tab.$address
            .dropFirst()
            .sink { [weak self] _ in self?.remember() }
            .store(in: &bag)
    }

    // MARK: - the field

    func edit() {
        typed = active?.address.map { Address.pretty($0) } ?? ""
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

    private func remember() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            saving = false
            Session.write(
                .init(
                    tabs: self.tabs.compactMap { tab in
                        guard let url = tab.address,
                              url.scheme?.hasPrefix("http") == true
                        else { return nil }
                        return Session.Entry(
                            url: url.absoluteString, title: tab.title, pin: tab.pin
                        )
                    },
                    active: self.tabs.firstIndex { $0.id == self.activeID } ?? 0
                )
            )
        }
    }
}

extension Browser: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tabs.first(where: { $0.web === webView }),
              let url = tab.address
        else { return }
        history.record(url, title: tab.title)
    }

    /// A link asking for a new window gets a new tab.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        let tab = Tab()
        adopt(tab)
        activeID = tab.id
        tab.go(to: url)
        return nil
    }
}

enum Session {
    struct Entry: Codable {
        var url: String
        var title: String
        var pin: String?
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
