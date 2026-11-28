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

/// One thing taken off a site: how to find it, and what it was in words, so
/// the list of what is hidden reads like something (the Mac's Veil).
struct Veil: Codable, Equatable, Identifiable {
    var selector: String
    var label: String
    /// Its size and where it sat, measured as it went: a hidden thing has
    /// no size left to measure.
    var note: String?
    var date: Date

    var id: String { selector }
}

struct SitePrefs: Codable, Equatable {
    var zoom: Double?
    var desktop: Bool?
    var camera: Choice?
    var microphone: Choice?
    /// What was hidden before hidden things had names: bare selectors,
    /// still read, folded into `veils` at the next change.
    var hidden: [String]?
    /// What was hidden on the site (the Mac's Hide Elements).
    var veils: [Veil]?

    var isEmpty: Bool { self == SitePrefs() }

    /// Everything hidden, the old bare selectors included.
    var allVeils: [Veil] {
        let named = veils ?? []
        let old = (hidden ?? [])
            .filter { selector in !named.contains { $0.selector == selector } }
            .map { Veil(selector: $0, label: String(localized: "Hidden element"), note: nil, date: .distantPast) }
        return old + named
    }

    /// The list, written back in the one field it lives in now.
    mutating func setVeils(_ list: [Veil]) {
        hidden = nil
        veils = list.isEmpty ? nil : list
    }
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

    // MARK: Hide Elements

    /// Hide Elements, as on the Mac: a tap outlines what is under the
    /// finger, Wider and Narrower move the outline out and back in, Hide
    /// takes it off, here and on every later visit to the site. On for the
    /// next thing until Done.
    func zap(_ tab: Tab) {
        guard tab.address != nil else { return }
        siteSheet = false
        holding = false
        if peekedVeil != nil {
            peekedVeil = nil
            unpeekVeil(tab)
        }
        withAnimation(Motion.settle) { zapping = Zapping(tab: tab.id) }
        Feel.tick()
        tab.web.evaluateJavaScript(Zap.picker + "\nwindow.__searchZap.on();")
    }

    func stopZap() {
        guard let zap = zapping else { return }
        withAnimation(Motion.settle) { zapping = nil }
        tabs.first { $0.id == zap.tab }?.web
            .evaluateJavaScript("window.__searchZap && window.__searchZap.off(true);")
    }

    func zapWider() { zapCall("wider") }
    func zapNarrower() { zapCall("narrower") }
    func zapHide() { zapCall("hide") }

    /// The last thing taken off while picking, back.
    func zapUndo() {
        guard let tab = zapTab, let last = zapping?.taken.last else { return }
        zapping?.taken.removeLast()
        forget(last, on: tab)
        Feel.tick()
    }

    private var zapTab: Tab? {
        zapping.flatMap { zap in tabs.first { $0.id == zap.tab } }
    }

    private func zapCall(_ name: String) {
        zapTab?.web.evaluateJavaScript("window.__searchZap && window.__searchZap.\(name)();")
    }

    /// What the page said while things were being picked from it.
    func zapSaid(_ body: [String: Any], in web: WKWebView) {
        guard let tab = tabs.first(where: { $0.web === web }), zapping?.tab == tab.id else { return }
        if body["off"] as? Bool == true {
            withAnimation(Motion.settle) { zapping = nil }
            return
        }
        if let picked = body["picked"] as? [String: Any] {
            Feel.tick()
            zapping?.label = picked["label"] as? String
            zapping?.note = picked["note"] as? String
            zapping?.wider = picked["wider"] as? Bool ?? false
            zapping?.narrower = picked["narrower"] as? Bool ?? false
            return
        }
        guard let selector = body["selector"] as? String, !selector.isEmpty else { return }
        let veil = Veil(
            selector: selector,
            label: body["label"] as? String ?? selector,
            note: body["note"] as? String,
            date: Date()
        )
        zapping?.label = nil
        zapping?.note = nil
        zapping?.wider = false
        zapping?.narrower = false
        // A private tab writes nothing down: taken off in this tab only.
        if tab.isPrivate {
            if passingVeils[tab.id]?.contains(where: { $0.selector == selector }) != true {
                passingVeils[tab.id, default: []].append(veil)
            }
        } else {
            Sites.shared.change(tab.address) { prefs in
                var list = prefs.allVeils
                if !list.contains(where: { $0.selector == selector }) { list.append(veil) }
                prefs.setVeils(list)
            }
        }
        zapping?.taken.append(selector)
        rehide(tab)
        armHiding(tab.web, for: tab.address)
        // A page can keep a thing on screen whatever the sheet says. Then
        // it isn't kept or listed, and the thing around it is the way past.
        tab.web.evaluateJavaScript(Zap.shows(selector)) { [weak self, weak tab] result, _ in
            MainActor.assumeIsolated {
                guard let self, let tab, result as? Bool == true else { return }
                self.zapping?.taken.removeAll { $0 == selector }
                self.forget(selector, on: tab)
                Feel.refuse()
                self.say(String(localized: "The page keeps that on screen. Try Wider."))
            }
        }
    }

    /// What is hidden on the tab's site, and what a private tab took off.
    func veils(_ tab: Tab) -> [Veil] {
        Sites.shared.prefs(tab.address).allVeils + (passingVeils[tab.id] ?? [])
    }

    private func hidingCSS(_ tab: Tab, sparing: String? = nil) -> String {
        veils(tab)
            .filter { $0.selector != sparing }
            .map { Zap.rule($0.selector) }
            .joined(separator: "\n")
    }

    /// The page's sheet of hidden things, as the list stands now.
    private func rehide(_ tab: Tab) {
        tab.web.evaluateJavaScript(Zap.sheet("search-hidden", hidingCSS(tab)))
    }

    /// The tab's scripts for the page about to load, put back whole, with
    /// what is hidden on its site in before the page draws anything.
    func armHiding(_ web: WKWebView, for url: URL?) {
        let controller = web.configuration.userContentController
        Shield.shared.tune(controller, for: url?.host()?.lowercased())
        let tab = tabs.first { $0.web === web }
        let css = (Sites.shared.prefs(url).allVeils + (tab.flatMap { passingVeils[$0.id] } ?? []))
            .map { Zap.rule($0.selector) }
            .joined(separator: "\n")
        if !css.isEmpty { controller.addUserScript(Zap.arm(css)) }
    }

    /// One thing back on the site's pages.
    func restore(_ veil: Veil, on tab: Tab) {
        forget(veil.selector, on: tab)
        Feel.tick()
    }

    /// Everything hidden on the site, back.
    func restoreAll(on tab: Tab) {
        peekedVeil = nil
        passingVeils[tab.id] = nil
        Sites.shared.change(tab.address) { $0.setVeils([]) }
        unpeekVeil(tab)
        armHiding(tab.web, for: tab.address)
        Feel.tick()
    }

    private func forget(_ selector: String, on tab: Tab) {
        if peekedVeil == selector { peekedVeil = nil }
        passingVeils[tab.id]?.removeAll { $0.selector == selector }
        Sites.shared.change(tab.address) { prefs in
            prefs.setVeils(prefs.allVeils.filter { $0.selector != selector })
        }
        unpeekVeil(tab)
        armHiding(tab.web, for: tab.address)
    }

    /// A line of This site's list touched: that one thing back on the page,
    /// outlined and scrolled to, so it's chosen by looking at it; touched
    /// again, gone again.
    func peekVeil(_ veil: Veil, on tab: Tab) {
        if peekedVeil == veil.selector {
            peekedVeil = nil
            unpeekVeil(tab)
            return
        }
        peekedVeil = veil.selector
        tab.web.evaluateJavaScript(Zap.peek(css: hidingCSS(tab, sparing: veil.selector), selector: veil.selector))
    }

    func unpeekVeil(_ tab: Tab) {
        tab.web.evaluateJavaScript(Zap.sheet("search-hidden", hidingCSS(tab)) + Zap.unpeek)
    }

    /// What was decided for the page's site, put on the page.
    func apply(_ prefs: SitePrefs, to tab: Tab) {
        // A private tab keeps the size it was given; others take the site's.
        if !tab.isPrivate { tab.textZoom = prefs.zoom ?? 1 }
        if tab.textZoom != 1 { tab.web.evaluateJavaScript(Zap.textSize(tab.textZoom)) }
        let css = hidingCSS(tab)
        if !css.isEmpty { tab.web.evaluateJavaScript(Zap.sheet("search-hidden", css)) }
    }
}

/// Hide Elements under way: on which tab, and what is outlined.
struct Zapping: Equatable {
    let tab: UUID
    var label: String?
    var note: String?
    var wider = false
    var narrower = false
    /// What was taken off since it began, for Undo.
    var taken: [String] = []
}

/// What the page says while things are picked from it.
final class ZapRelay: NSObject, WKScriptMessageHandler {
    weak var browser: Browser?

    init(_ browser: Browser) { self.browser = browser }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let web = message.webView
        MainActor.assumeIsolated {
            guard let web else { return }
            browser?.zapSaid(body, in: web)
        }
    }
}

enum Zap {
    static let handler = "searchZap"

    /// One thing taken off. Three ids no element has lift the rule above
    /// any a page is likely to write (the Mac's #1270); `:is()` keeps a
    /// selector it can't read from taking the rest down with it.
    static func rule(_ selector: String) -> String {
        ":is(\(selector)):not(#search-veiled):not(#search-veiled):not(#search-veiled) { display: none !important; }"
    }

    private static func json(_ text: String) -> String {
        (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
    }

    /// Puts css in the page's sheet called id: a sheet adopted by the
    /// document, which a site's Content-Security-Policy can't turn away,
    /// and a <style> only where WebKit has none.
    static let sheets = """
    if (!window.__searchSheet) window.__searchSheet = function (id, css) {
      var all = window.__searchSheets || (window.__searchSheets = {});
      try {
        var made = all[id] || (all[id] = new CSSStyleSheet());
        made.replaceSync(css);
        var adopted = document.adoptedStyleSheets;
        if (adopted.indexOf(made) < 0) document.adoptedStyleSheets = adopted.concat([made]);
        return;
      } catch (e) {}
      var s = document.getElementById(id);
      if (!s) { s = document.createElement('style'); s.id = id; (document.head || document.documentElement).appendChild(s); }
      s.textContent = css;
    };
    """

    static func sheet(_ id: String, _ css: String) -> String {
        "(function(){\n\(sheets)\nwindow.__searchSheet(\(json(id)), \(json(css)));\n})();"
    }

    /// What is hidden on the site, in before the page has drawn anything,
    /// so nothing is seen arriving and leaving.
    @MainActor static func arm(_ css: String) -> WKUserScript {
        WKUserScript(source: sheet("search-hidden", css), injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// One hidden thing back, framed, and the page scrolled to it, high
    /// enough to be seen over This site's sheet. A frame of its own over
    /// the page, not an outline: a box that clips its insides clipped that.
    static func peek(css: String, selector: String) -> String {
        sheet("search-hidden", css) + """
        (function(){
          var old = window.__searchPeek; if (old) old.stop();
          var el = null;
          try { el = document.querySelector(\(json(selector))); } catch (e) {}
          if (!el) return;
          var frame = document.createElement('div');
          frame.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;' +
            'border:3px solid #0a84ff;background:rgba(10,132,255,.10);border-radius:6px;' +
            'box-shadow:0 0 0 1px rgba(255,255,255,.75)';
          document.documentElement.appendChild(frame);
          function place() {
            var r = el.getBoundingClientRect();
            frame.style.left = (r.left - 3) + 'px'; frame.style.top = (r.top - 3) + 'px';
            frame.style.width = (r.width + 6) + 'px'; frame.style.height = (r.height + 6) + 'px';
          }
          place();
          window.addEventListener('scroll', place, true);
          window.__searchPeek = { stop: function () {
            window.removeEventListener('scroll', place, true);
            frame.remove();
            window.__searchPeek = null;
          } };
          var r = el.getBoundingClientRect();
          window.scrollTo({ top: window.scrollY + r.top - window.innerHeight * 0.12, behavior: 'smooth' });
        })();
        """
    }

    static let unpeek = "window.__searchPeek && window.__searchPeek.stop();"

    /// Whether the thing is still on screen.
    static func shows(_ selector: String) -> String {
        "(function(){try{var e=document.querySelector(\(json(selector)));return !!(e&&e.getClientRects().length);}catch(x){return false;}})()"
    }

    static func textSize(_ zoom: Double) -> String {
        let percent = Int((zoom * 100).rounded())
        return "document.documentElement.style.setProperty('-webkit-text-size-adjust','\(percent)%','important');"
    }

    /// What a thing is called when it says nothing itself, in the
    /// iPhone's language.
    private static var known: String {
        let names: [String: String] = [
            "nav": String(localized: "Navigation"), "header": String(localized: "Header"),
            "footer": String(localized: "Footer"), "aside": String(localized: "Sidebar"),
            "form": String(localized: "Form"), "dialog": String(localized: "Dialog"),
            "video": String(localized: "Video"), "img": String(localized: "Image"),
            "button": String(localized: "Button"), "iframe": String(localized: "Embed"),
            "figure": String(localized: "Figure"), "table": String(localized: "Table"),
        ]
        let words: [String: String] = [
            "top": String(localized: "top"), "middle": String(localized: "middle"),
            "bottom": String(localized: "bottom"),
        ]
        let encode = { (map: [String: String]) in
            (try? String(data: JSONEncoder().encode(map), encoding: .utf8)) ?? "{}"
        }
        return "var known = \(encode(names)), words = \(encode(words));"
    }

    /// The picking, the Mac's own made for a finger: a tap outlines,
    /// scrolling still scrolls, and nothing on the page acts on a tap
    /// until Done.
    static var picker: String {
        """
        (function () {
          if (window.__searchZap) return;
          \(sheets)
          \(known)
          var frame = null, target = null, trail = [], live = false, down = null;

          function say(m) { try { window.webkit.messageHandlers.\(handler).postMessage(m); } catch (e) {} }

          function chrome() {
            if (frame) return frame;
            frame = document.createElement('div');
            frame.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;box-sizing:border-box;' +
              'border:2px solid #0a84ff;background:rgba(10,132,255,.12);border-radius:6px;' +
              'box-shadow:0 0 0 1px rgba(255,255,255,.75);transition:all .12s ease-out;display:none';
            document.documentElement.appendChild(frame);
            return frame;
          }

          function place() {
            if (!target) { if (frame) frame.style.display = 'none'; return; }
            var box = chrome(), r = target.getBoundingClientRect();
            box.style.display = 'block';
            box.style.left = (r.left - 2) + 'px';
            box.style.top = (r.top - 2) + 'px';
            box.style.width = (r.width + 4) + 'px';
            box.style.height = (r.height + 4) + 'px';
          }

          function clip(text, n) { return text.length > n ? text.slice(0, n) + '…' : text; }

          // What it calls itself, then what kind of thing it is, then what it says.
          function name(el) {
            var said = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('alt'));
            if (said && said.trim()) return clip(said.trim(), 40);
            var tagName = el.tagName.toLowerCase();
            if (known[tagName]) return known[tagName];
            var role = el.getAttribute && el.getAttribute('role');
            if (role) return role.charAt(0).toUpperCase() + role.slice(1);
            var text = (el.innerText || '').trim().replace(/\\s+/g, ' ');
            return text ? clip(text, 40) : tagName;
          }

          function shape(el) {
            var r = el.getBoundingClientRect(), cy = r.top + r.height / 2;
            var band = cy < innerHeight / 3 ? words.top : (cy > innerHeight * 2 / 3 ? words.bottom : words.middle);
            return Math.round(r.width) + ' × ' + Math.round(r.height) + ' · ' + band;
          }

          function steady(c) {
            return /^[a-zA-Z][\\w-]{2,29}$/.test(c) && !/\\d{3,}/.test(c) &&
                   !/^(css|sc|jsx|emotion|svelte|styles?)-/.test(c);
          }

          function unique(sel) {
            try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; }
          }

          function selectorFor(el) {
            if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
            var hooks = ['data-testid', 'data-test', 'data-qa', 'data-cy', 'aria-label', 'name', 'role'];
            for (var i = 0; i < hooks.length; i++) {
              var v = el.getAttribute && el.getAttribute(hooks[i]);
              if (v) {
                var s = el.tagName.toLowerCase() + '[' + hooks[i] + '="' + CSS.escape(v) + '"]';
                if (unique(s)) return s;
              }
            }
            var classes = (el.className && typeof el.className === 'string')
              ? el.className.trim().split(/\\s+/).filter(steady) : [];
            if (classes.length) {
              var byClass = el.tagName.toLowerCase() + '.' + classes.map(CSS.escape).join('.');
              if (unique(byClass)) return byClass;
            }
            var parts = [], node = el;
            while (node && node.nodeType === 1 && node !== document.documentElement) {
              if (node.id && unique('#' + CSS.escape(node.id))) { parts.unshift('#' + CSS.escape(node.id)); break; }
              var tagName = node.tagName.toLowerCase(), parent = node.parentElement;
              if (!parent) { parts.unshift(tagName); break; }
              var kin = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === node.tagName; });
              parts.unshift(kin.length > 1 ? tagName + ':nth-of-type(' + (kin.indexOf(node) + 1) + ')' : tagName);
              node = parent;
            }
            return parts.join(' > ');
          }

          function usable(el) {
            return el && el.nodeType === 1 && el !== frame && el !== document.documentElement && el !== document.body;
          }

          function tell() {
            if (!target) return;
            say({ picked: { label: name(target), note: shape(target),
                            wider: !!usable(target.parentElement), narrower: trail.length > 0 } });
          }

          // A press on the page does nothing on the page: links don't go,
          // fields don't take the keyboard, menus don't open.
          function swallow(e) {
            if (!live) return;
            e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
          }
          // Touches still reach the page's scrolling, never its own handlers.
          function hush(e) {
            if (!live) return;
            e.stopPropagation(); e.stopImmediatePropagation();
          }

          function onDown(e) { swallow(e); down = { x: e.clientX, y: e.clientY, t: Date.now() }; }

          // A tap, not a scroll: what is under it, outlined.
          function onUp(e) {
            swallow(e);
            if (!down) return;
            var still = Math.abs(e.clientX - down.x) < 10 && Math.abs(e.clientY - down.y) < 10 && Date.now() - down.t < 700;
            down = null;
            if (!still) return;
            var el = document.elementFromPoint(e.clientX, e.clientY);
            if (!usable(el)) return;
            target = el; trail = [];
            place(); tell();
          }

          function onScroll() { if (live && target) place(); }
          function onCancel() { down = null; }

          var swallowed = ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu', 'auxclick'];
          var hushed = ['touchstart', 'touchmove', 'touchend'];

          function off(quiet) {
            if (!live) return;
            live = false; target = null; trail = []; down = null;
            place();
            window.__searchSheet('search-zapping', '');
            document.removeEventListener('pointerdown', onDown, true);
            document.removeEventListener('pointerup', onUp, true);
            document.removeEventListener('pointercancel', onCancel, true);
            swallowed.forEach(function (k) { document.removeEventListener(k, swallow, true); });
            hushed.forEach(function (k) { document.removeEventListener(k, hush, { capture: true, passive: true }); });
            window.removeEventListener('scroll', onScroll, true);
            window.removeEventListener('resize', onScroll);
            window.removeEventListener('pagehide', gone);
            if (quiet !== true) say({ off: true });
          }
          function gone() { off(false); }

          window.__searchZap = {
            on: function () {
              if (live) return;
              live = true;
              chrome();
              window.__searchSheet('search-zapping',
                '* { -webkit-user-select: none !important; -webkit-touch-callout: none !important; -webkit-tap-highlight-color: transparent !important; }');
              document.addEventListener('pointerdown', onDown, true);
              document.addEventListener('pointerup', onUp, true);
              document.addEventListener('pointercancel', onCancel, true);
              swallowed.forEach(function (k) { document.addEventListener(k, swallow, true); });
              hushed.forEach(function (k) { document.addEventListener(k, hush, { capture: true, passive: true }); });
              window.addEventListener('scroll', onScroll, true);
              window.addEventListener('resize', onScroll);
              // The page going away ends the picking with it.
              window.addEventListener('pagehide', gone);
            },
            off: off,
            wider: function () {
              if (!target || !usable(target.parentElement)) return;
              trail.push(target); target = target.parentElement;
              place(); tell();
            },
            narrower: function () {
              if (!trail.length) return;
              target = trail.pop();
              place(); tell();
            },
            hide: function () {
              if (!target) return;
              var el = target;
              var said = { selector: selectorFor(el), label: name(el), note: shape(el) };
              target = null; trail = [];
              place();
              say(said);
            }
          };
        })();
        """
    }
}

// MARK: - the bar

/// Over the page while things are picked from it, where the pill was: what
/// is outlined, Wider and Narrower, Hide; Undo on one side, Done on the
/// other.
struct ZapBar: View {
    @ObservedObject var browser: Browser
    let zap: Zapping

    var body: some View {
        HStack(spacing: 8) {
            round("arrow.uturn.backward", "Undo", on: !zap.taken.isEmpty) { browser.zapUndo() }

            HStack(spacing: 2) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(zap.label ?? String(localized: "Tap what to hide"))
                        .font(.scaled(14, weight: zap.label == nil ? .regular : .medium))
                        .foregroundStyle(zap.label == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if let note = zap.note {
                        Text(note)
                            .font(.scaled(11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 18)

                if zap.label != nil {
                    small("arrow.down.right.and.arrow.up.left", "Narrower", on: zap.narrower) { browser.zapNarrower() }
                    small("arrow.up.left.and.arrow.down.right", "Wider", on: zap.wider) { browser.zapWider() }
                    Button { browser.zapHide() } label: {
                        Text("Hide")
                            .font(.scaled(14, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(Palette.ground)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(Capsule().fill(Palette.ink))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                }
            }
            .frame(height: Metrics.pill)
            .glass(Capsule(), else: .clear)
            .background { if #unavailable(iOS 26.0) { Glass(shape: Capsule()) } }
            .animation(Motion.quick, value: zap.label != nil)

            round("checkmark", "Done", on: true) { browser.stopZap() }
        }
    }

    private func round(_ symbol: String, _ title: LocalizedStringKey, on: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: Metrics.pill, height: Metrics.pill)
                .glass(Circle(), interactive: true, else: .clear)
                .background { if #unavailable(iOS 26.0) { Glass(shape: Circle()) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(on ? 1 : 0.4)
        .disabled(!on)
        .accessibilityLabel(Text(title))
    }

    private func small(_ symbol: String, _ title: LocalizedStringKey, on: Bool, act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(on ? 1 : 0.3)
        .disabled(!on)
        .accessibilityLabel(Text(title))
    }
}

// MARK: - the sheet

/// "This site": everything decided for the site in front, in one place.
struct SiteSheet: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var sites = Sites.shared
    @Environment(\.dismiss) private var done
    /// Half up while a hidden thing is shown again, so it can be seen.
    @State private var detent: PresentationDetent = .medium

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

                hiddenHere

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
        .presentationDetents([.medium, .large], selection: $detent)
        // A plain ground: half up, the page read through the glass under
        // the switches (28 Nov).
        .presentationBackground(Palette.ground)
        // Whatever was shown again from the list goes again with the sheet.
        .onDisappear {
            guard browser.peekedVeil != nil else { return }
            browser.peekedVeil = nil
            browser.unpeekVeil(tab)
        }
    }

    /// What is hidden on the site, each one shown again on the page when
    /// touched, so it's chosen by looking at it, not by reading its name.
    @ViewBuilder private var hiddenHere: some View {
        let veils = browser.veils(tab)
        Section {
            ForEach(veils) { veil in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(veil.label)
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if let note = veil.note, !note.isEmpty {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Palette.muted)
                                .monospacedDigit()
                        }
                    }
                    Spacer(minLength: 8)
                    if browser.peekedVeil == veil.selector {
                        Image(systemName: "eye")
                            .foregroundStyle(Palette.muted)
                    }
                    Button("Show") { browser.restore(veil, on: tab) }
                        .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.settle) { detent = .medium }
                    browser.peekVeil(veil, on: tab)
                }
            }
            Button("Hide Elements") { browser.zap(tab) }
            if veils.count > 1 {
                Button("Show All") { browser.restoreAll(on: tab) }
            }
        } header: {
            if !veils.isEmpty { Text("Hidden on this site") }
        } footer: {
            if !veils.isEmpty { Text("Touch a line to see it on the page.") }
        }
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
