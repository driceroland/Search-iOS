import SwiftUI
import WebKit

// What a person has decided for one site: its text size, the computer's
// version of it, the camera and the microphone, the bits of it they hid.
// Kept on this iPhone, by site, and never for a private tab.

enum Choice: String, Codable, CaseIterable, Identifiable {
    case ask, allow, deny

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return String(localized: "Ask")
        case .allow: return String(localized: "Allow")
        case .deny: return String(localized: "Deny")
        }
    }
}

struct SitePrefs: Codable, Equatable {
    var zoom: Double?
    var desktop: Bool?
    var camera: Choice?
    var microphone: Choice?
    /// What was hidden on the site, as CSS selectors (the Mac's zapper).
    var hidden: [String]?

    var isEmpty: Bool { self == SitePrefs() }
}

@MainActor
final class Sites: ObservableObject {
    static let shared = Sites()

    @Published private(set) var all: [String: SitePrefs] = [:]

    /// The sizes text steps through, as in Safari.
    static let zooms: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 3]

    private static var file: URL { Store.file("sites.json") }

    private init() {
        if let data = try? Data(contentsOf: Sites.file),
           let saved = try? JSONDecoder().decode([String: SitePrefs].self, from: data) {
            all = saved
        }
    }

    /// One name per site: no scheme, no "www.".
    static func key(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func prefs(_ url: URL?) -> SitePrefs {
        Sites.key(url).flatMap { all[$0] } ?? SitePrefs()
    }

    func change(_ url: URL?, _ edit: (inout SitePrefs) -> Void) {
        guard let key = Sites.key(url) else { return }
        var prefs = all[key] ?? SitePrefs()
        edit(&prefs)
        all[key] = prefs.isEmpty ? nil : prefs
        save()
    }

    func forget() {
        all = [:]
        save()
    }

    private func save() {
        let snapshot = all
        let file = Sites.file
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

// MARK: - text size, the computer's version, hidden bits

extension Browser {
    /// The page's text size, one step up or down, or back to 100 %. The
    /// text grows and the page lays itself out again around it, as in
    /// Safari: nothing runs off the side.
    func zoom(_ tab: Tab, step: Int) {
        let steps = Sites.zooms
        let here = steps.firstIndex { abs($0 - tab.textZoom) < 0.01 } ?? steps.firstIndex(of: 1)!
        let next = step == 0 ? 1 : steps[max(0, min(steps.count - 1, here + step))]
        tab.textZoom = next
        tab.web.evaluateJavaScript(Zap.textSize(next))
        if !tab.isPrivate {
            Sites.shared.change(tab.address) { $0.zoom = next == 1 ? nil : next }
        }
    }

    /// The site as a computer sees it, or as a phone does again.
    func desktop(_ tab: Tab) {
        let on = !(Sites.shared.prefs(tab.address).desktop ?? false)
        Sites.shared.change(tab.address) { $0.desktop = on ? true : nil }
        tab.web.reload()
    }

    /// The next thing tapped on the page goes, here and on every later
    /// visit to the site.
    func zap(_ tab: Tab) {
        tab.web.evaluateJavaScript(Zap.pick)
        say(String(localized: "Tap what to hide"))
    }

    /// Everything hidden on the site, back.
    func unzap(_ tab: Tab) {
        Sites.shared.change(tab.address) { $0.hidden = nil }
        tab.web.reload()
    }

    /// What was decided for the page's site, put on the page.
    func apply(_ prefs: SitePrefs, to tab: Tab) {
        // A private tab keeps the size it was given; others take the site's.
        if !tab.isPrivate { tab.textZoom = prefs.zoom ?? 1 }
        if tab.textZoom != 1 { tab.web.evaluateJavaScript(Zap.textSize(tab.textZoom)) }
        if let hidden = prefs.hidden, !hidden.isEmpty {
            tab.web.evaluateJavaScript(Zap.hide(hidden))
        }
    }

    /// A selector came back from the page: kept for the site.
    func zapped(_ selector: String, in web: WKWebView) {
        guard let tab = tabs.first(where: { $0.web === web }) else { return }
        guard !selector.isEmpty else {
            say(String(localized: "Nothing hidden"))
            return
        }
        Feel.tick()
        say("Hidden on \(tab.address.map { Address.host($0) } ?? "this site")")
        guard !tab.isPrivate else { return }
        Sites.shared.change(tab.address) { prefs in
            var list = prefs.hidden ?? []
            if !list.contains(selector) { list.append(selector) }
            prefs.hidden = list
        }
    }
}

/// The page's answer when something was tapped to be hidden.
final class ZapRelay: NSObject, WKScriptMessageHandler {
    weak var browser: Browser?

    init(_ browser: Browser) { self.browser = browser }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let selector = message.body as? String ?? ""
        let web = message.webView
        MainActor.assumeIsolated {
            guard let web else { return }
            browser?.zapped(selector, in: web)
        }
    }
}

enum Zap {
    static let handler = "searchZap"

    /// One tap hides one thing. Ends by itself after 15 seconds, so a page
    /// left in the middle doesn't swallow a later tap.
    static let pick = """
    (function(){
      if (window.__searchZap) return; window.__searchZap = 1;
      var css = document.createElement('style');
      css.textContent = '*{cursor:crosshair!important}';
      document.documentElement.appendChild(css);
      function name(el){
        var parts = [];
        while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement) {
          if (el.id && /^[A-Za-z][\\w-]*$/.test(el.id)) { parts.unshift('#' + el.id); break; }
          var part = el.tagName.toLowerCase(), up = el.parentElement;
          if (up) {
            var same = Array.prototype.filter.call(up.children, function(c){ return c.tagName === el.tagName; });
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(part); el = up;
        }
        return parts.join(' > ');
      }
      function stop(){ document.removeEventListener('click', tap, true); css.remove(); delete window.__searchZap; clearTimeout(timer); }
      function tap(e){
        e.preventDefault(); e.stopPropagation();
        var el = e.target, found = '';
        if (el && el !== document.body && el !== document.documentElement) {
          found = name(el);
          el.style.setProperty('display', 'none', 'important');
        }
        stop();
        window.webkit.messageHandlers.\(handler).postMessage(found);
      }
      var timer = setTimeout(stop, 15000);
      document.addEventListener('click', tap, true);
    })();
    """

    static func textSize(_ zoom: Double) -> String {
        let percent = Int((zoom * 100).rounded())
        return "document.documentElement.style.setProperty('-webkit-text-size-adjust','\(percent)%','important');"
    }

    /// What was hidden before, hidden again, now and as the page builds.
    static func hide(_ selectors: [String]) -> String {
        let rules = selectors.map { $0 + "{display:none!important}" }.joined()
        let quoted = (try? String(data: JSONEncoder().encode(rules), encoding: .utf8)) ?? "\"\""
        return """
        (function(){
          var s = document.getElementById('__searchHidden');
          if (!s) { s = document.createElement('style'); s.id = '__searchHidden'; (document.head || document.documentElement).appendChild(s); }
          s.textContent = \(quoted);
        })();
        """
    }
}

// MARK: - the sheet

/// "This site": everything decided for the site in front, in one place.
struct SiteSheet: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var sites = Sites.shared
    @Environment(\.dismiss) private var done

    private var prefs: SitePrefs { sites.prefs(tab.address) }
    private var host: String { tab.address.map { Address.host($0) } ?? String(localized: "This site") }

    private var blocking: Bool {
        Shield.shared.enabled && !Shield.shared.isPaused(on: tab.address?.host()?.lowercased())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Desktop version", isOn: Binding(
                        get: { prefs.desktop ?? false },
                        set: { _ in browser.desktop(tab) }
                    )).tint(.green)
                    LabeledContent("Text size") {
                        HStack(spacing: 18) {
                            Button { browser.zoom(tab, step: -1) } label: { Text("A").font(.scaled(13)) }
                            Button { browser.zoom(tab, step: 0) } label: {
                                Text("\(Int((tab.textZoom * 100).rounded())) %").monospacedDigit()
                            }
                            Button { browser.zoom(tab, step: 1) } label: { Text("A").font(.scaled(19)) }
                        }
                        .buttonStyle(.plain)
                    }
                    if Shield.shared.enabled {
                        Toggle("Block ads", isOn: Binding(
                            get: { blocking },
                            set: { _ in browser.shield(tab) }
                        )).tint(.green)
                    }
                }

                Section {
                    Picker("Camera", selection: Binding(
                        get: { prefs.camera ?? .ask },
                        set: { value in sites.change(tab.address) { $0.camera = value == .ask ? nil : value } }
                    )) {
                        ForEach(Choice.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Microphone", selection: Binding(
                        get: { prefs.microphone ?? .ask },
                        set: { value in sites.change(tab.address) { $0.microphone = value == .ask ? nil : value } }
                    )) {
                        ForEach(Choice.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Location") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } footer: {
                    Text("iOS asks before any site gets your location, and you can turn it off for Search altogether in the iPhone's Settings.")
                }

                if let hidden = prefs.hidden, !hidden.isEmpty {
                    Section {
                        Button(hidden.count == 1 ? String(localized: "Show the hidden element") : String(localized: "Show \(hidden.count) hidden elements")) {
                            browser.unzap(tab)
                        }
                    }
                }
            }
            .navigationTitle(host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                }
            }
        }
        .tint(Palette.ink)
    }
}

// MARK: - type that follows the iPhone's text size

extension Font {
    /// The system font at a size that grows with the iPhone's text size, up
    /// to a point past which the pill and the rows would no longer hold it.
    static func scaled(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: min(UIFontMetrics.default.scaledValue(for: size), size * 1.4), weight: weight)
    }
}
