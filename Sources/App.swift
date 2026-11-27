import SwiftUI

// A page, and a pill at the bottom. Everything else is summoned and put away,
// and everything that moves goes where the finger takes it.

@main
struct SearchApp: App {
    @UIApplicationDelegateAdaptor(Shortcuts.self) private var shortcuts
    @StateObject private var browser = Browser()
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let number = Mock.screen {
                MockScreen(number: number)
            } else {
                Shell(browser: browser)
            }
            #else
            Shell(browser: browser)
            #endif
        }
        .onChange(of: prefs.look, initial: true) { _, look in
            // The window may not be there yet on the first pass: once more after.
            look.apply()
            DispatchQueue.main.async { look.apply() }
        }
        .onChange(of: phase) { _, now in
            if now == .active { prefs.look.apply() }
            if now == .background {
                browser.rest()
                browser.lock()
            }
            if now == .active {
                browser.askToUnlock()
                Sync.shared.refresh()
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var browser: Browser

    @Namespace private var space
    @StateObject private var keyboard = Keyboard()
    @Environment(\.accessibilityReduceMotion) private var still

    /// How far the pages are walked sideways, in points.
    @State private var walk: CGFloat = 0
    /// A walk let go of and on its way; the pill waits for it.
    @State private var landing = false
    /// How far the sheet of tabs is up: 0 down, 1 up.
    @State private var lift: CGFloat = 0
    /// How far a finger goes to bring the tabs all the way: short, so the
    /// page is in its card well before the thumb reaches the middle.
    private let travel: CGFloat = 200
    /// The page, as a picture, while it's walked or shrunk for the sheet:
    /// the web view itself stays where it is, at its size, untouched.
    @State private var frozen: UIImage?
    /// Asked for and on its way: the page's picture takes a frame or two.
    @State private var freezing = false
    /// How far the finger had gone when the picture arrived: the motion
    /// starts from there, so nothing leaps when the picture takes over.
    @State private var walkFrom: CGFloat = 0
    @State private var liftFrom: CGFloat = 0
    /// A finger is walking or lifting the page.
    @State private var dragging = false
    /// When the finger last moved the lift, and where to: a lift whose end
    /// never comes (a second finger dragging a picture took the touches) is
    /// let go from there, not left half open with the page frozen under it.
    @State private var liftSeen = Date.distantPast
    @State private var liftLast: CGFloat = 0
    /// The tabs are on their way, up or down, let go of: the page stays
    /// in the air until they land, whatever `lift` already says.
    @State private var moving = false
    /// Where each card's picture rests on screen once the sheet is up.
    /// Kept out of SwiftUI's sight: cards moving with the page report where
    /// they are on every frame, and each report redrew the whole screen.
    @State private var cardFrames = Frames()
    /// Which tab the frozen picture is of.
    @State private var frozenID: Tab.ID?
    /// The first launch's three screens.
    @State private var welcoming = !Prefs.shared.welcomed

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            // The page's own width: as in Safari on a Duo, it stops at the
            // camera's column, which is a band of the page's colour.
            let rail = browser.rail
            let pageWidth = width - (rail.on ? rail.width : 0)
            let pageX: CGFloat = rail.on && rail.leading ? rail.width : 0
            let page = CGSize(width: pageWidth, height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack(alignment: .bottom) {
                // Behind the pages: a grey, not black, so the clock can still
                // be read when the page steps back for the sheet.
                Palette.backdrop.ignoresSafeArea()

                deck(width: pageWidth, top: geo.safeAreaInsets.top)
                    .frame(width: width, alignment: rail.leading ? .trailing : .leading)
                    .overlay(alignment: rail.leading ? .leading : .trailing) {
                        // The band beside the page: what's at its top edge,
                        // as Safari does, while the page fills the screen.
                        // Laid over, at the rail's width: behind, the page's
                        // own ground covered it.
                        if rail.on, let tab = browser.active {
                            RailBand(tab: tab)
                                .frame(width: rail.width)
                                .opacity(Double(1 - min(1, lift * 3)))
                                .ignoresSafeArea()
                                .allowsHitTesting(false)
                        }
                    }

                // The dim, the pill and the field are always there, shown and
                // hidden by opacity rather than put in and taken out: a view
                // taken out mid-change was leaving in one frame.
                Palette.ground.opacity(0.74)
                    .ignoresSafeArea()
                    .onTapGesture { browser.dismiss() }
                    .opacity(browser.editing ? 1 : 0)
                    .allowsHitTesting(browser.editing)

                // The cards and the pins, under the page as it shrinks.
                sheet(.tabs, size: CGSize(width: width, height: geo.size.height), screen: page, pageX: pageX)

                // The page on its way into its card, or out of it: over the
                // cards, so it lands on one rather than behind it. Laid over
                // a clear view the stack's size: as tall as the whole screen
                // in the stack, it made the stack taller and pushed
                // everything down by as much.
                Color.clear
                    .overlay {
                        // Always there while tabs are cards, and shown or
                        // hidden at once: put in as it moved, it arrived
                        // already landed.
                        if let target = zoomTarget {
                            Zoom(
                                image: frozen, tint: browser.active?.behindClock, top: geo.safeAreaInsets.top,
                                progress: max(0, min(1, lift)),
                                screen: page,
                                x0: pageX,
                                target: target,
                                tab: browser.active,
                                nameAbove: Prefs.shared.tabDeck
                            )
                            .opacity(zoomShown ? 1 : 0)
                            .animation(nil, value: zoomShown)
                            .ignoresSafeArea()
                        }
                    }
                    .allowsHitTesting(false)

                // The page fades into a blur toward the bottom edge, under
                // the pill, the way iOS's own bars sit on what scrolls. Over
                // the page on its way, not under it: under it, it came back
                // all at once when the live page took the picture's place.
                // Gone in the first steps out, back in the last steps home.
                Color.clear
                    .overlay(alignment: .bottom) {
                        Group {
                            if let tab = browser.active { PageFade(tab: tab) } else { Fade() }
                        }
                        .frame(height: Metrics.foot(geo.safeAreaInsets.bottom))
                    }
                    .opacity(Double(max(0, 1 - min(1, lift) * 5)))
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                // The buttons along the top, coming down over the page.
                sheet(.chrome, size: CGSize(width: width, height: geo.size.height), screen: page, pageX: pageX)

                // Over everything, and the same thing on a page and over the
                // tabs: where you are becomes New tab, Back leaves by the
                // side, Tabs becomes Bookmarks. Never put away and brought
                // back: it changes where it stands.
                if let tab = browser.active {
                    Pill(
                        tab: tab,
                        chrome: browser.chrome,
                        count: browser.tabs.count,
                        heading: heading(width: width),
                        space: space,
                        type: { withAnimation(still ? Motion.quick : keyboard.curve) { browser.edit() } },
                        tabs: { Feel.tick(); browser.showingTabs = true },
                        hold: { withAnimation(Motion.settle) { browser.holding = true } },
                        closeAll: { browser.askingCloseAll = true },
                        walk: { walking($0, width: width) },
                        walked: { walked($0, speed: $1, width: width) },
                        lift: { lifting($0) },
                        lifted: { lifted($0, speed: $1) },
                        source: !browser.editing,
                        morph: max(0, min(1, lift)),
                        over: browser.showingTabs,
                        newTab: { Feel.tick(); browser.newTab(private: browser.privateView) },
                        newPrivate: browser.privateView,
                        rail: browser.rail,
                        // Back stands up the rail, under the clock, where a
                        // thumb reaches it as in Safari.
                        bookmarks: { browser.showingBookmarks = true }
                    )
                    .opacity(browser.finding || browser.editing || browser.zapping != nil ? 0 : 1)
                    // Free as soon as it's on its way back: a thumb that came
                    // straight back for the tabs found it deaf until the
                    // page had quite finished landing. Over the tabs at
                    // once too, so two quick taps on Tabs open a new one.
                    .allowsHitTesting(!landing && !browser.holding && !browser.finding && !browser.editing && browser.zapping == nil)
                }

                // Hide Elements: its own bar where the pill was, until Done.
                if let zap = browser.zapping {
                    ZapBar(browser: browser, zap: zap)
                        .padding(.horizontal, 12)
                        .padding(rail.on ? rail.edge : [], rail.on ? rail.width - 8 : 0)
                        .padding(.bottom, 8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Back up the Duo's rail, under the clock: a view of its
                // own, placed from the top, so its taps are its own.
                if rail.on, let tab = browser.active {
                    RailBack(tab: tab, morph: max(0, min(1, lift)), over: browser.showingTabs) {
                        browser.showingBookmarks = true
                    }
                    .padding(rail.edge, rail.inset)
                    .padding(.top, Self.railBack - geo.safeAreaInsets.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rail.leading ? .topLeading : .topTrailing)
                    .opacity(browser.finding || browser.editing || browser.zapping != nil ? 0 : 1)
                    .allowsHitTesting(!landing && !browser.finding && !browser.editing && browser.zapping == nil)
                }

                // Always there, shown by scale and opacity: put in and taken
                // out, it arrived animated and left in one frame.
                if let tab = browser.active {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(Motion.settle) { browser.holding = false } }
                        .allowsHitTesting(browser.holding)
                    // Laid over a clear view the stack's size: in the stack
                    // itself, a menu taller than the screen (an open Duo,
                    // 669 points high) made the stack taller, and the pill
                    // sank under the home bar.
                    Color.clear
                        .overlay(alignment: .bottom) {
                            Held(browser: browser, tab: tab) {
                                withAnimation(Motion.settle) { browser.holding = false }
                            }
                            .padding(.bottom, Metrics.pill + 18)
                            .scaleEffect(browser.holding ? 1 : 0.9, anchor: .bottom)
                            .opacity(browser.holding ? 1 : 0)
                            .allowsHitTesting(browser.holding)
                            .accessibilityHidden(!browser.holding)
                        }
                }

                Field(browser: browser, space: space)
                    // Above the keyboard, by the keyboard's own measure: this
                    // view ignores it, so nothing else moves when it comes
                    // and goes.
                    .padding(.bottom, max(0, keyboard.height - geo.safeAreaInsets.bottom))
                    .opacity(browser.editing ? 1 : 0)
                    .allowsHitTesting(browser.editing)
                    .accessibilityHidden(!browser.editing)

                // A download under way, or just arrived: a round button
                // over Tabs, by the thumb, there only while it matters.
                DownloadButton()
                    .padding(.trailing, rail.on && !rail.leading ? (rail.width - 44) / 2 : 18)
                    .padding(.leading, rail.on && rail.leading ? (rail.width - 44) / 2 : 18)
                    .padding(.bottom, Metrics.pill + 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: rail.on && rail.leading ? .bottomLeading : .bottomTrailing)
                    .opacity(browser.editing || browser.showingTabs || browser.holding || browser.finding || browser.zapping != nil ? 0 : 1)
                    .allowsHitTesting(browser.zapping == nil)
                    .animation(Motion.quick, value: browser.showingTabs)

                // A link held: its page in a card over this one.
                if let peek = browser.peek {
                    PeekView(browser: browser, peek: peek)
                        .zIndex(5)
                }

                if let words = browser.toast {
                    Text(words)
                        .font(.scaled(13))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(Glass(shape: Capsule()))
                        .padding(.bottom, Metrics.pill + 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            // The whole width, the camera's column included: what sits in
            // it (the Duo's rail) is placed there by hand. Left to the safe
            // area, the page (wider than it) pushed everything aside and
            // left a grey strip at the other edge.
            .ignoresSafeArea(.container, edges: .horizontal)
            // The pill becomes the field, and the field the pill, on the
            // keyboard's curve and in its time.
            .animation(still ? Motion.quick : keyboard.curve, value: browser.editing)
        }
        // Nothing here makes room for the keyboard by itself: the field
        // follows it (above), and the pill stays under it, as Safari's does,
        // when a page's own form raises it.
        .ignoresSafeArea(.keyboard)
        .onChange(of: browser.showingTabs) { _, open in
            let target: CGFloat = open ? 1 : 0
            guard lift != target else { return }
            let go = {
                moving = true
                // Up: done once it looks done. Waiting for the spring to be
                // quite removed kept the page's picture over its card (and
                // the card's cross under it) for a second or more on a
                // busy phone. Down: to the end, as the live page takes over.
                withAnimation(still ? Motion.quick : Self.landing,
                              completionCriteria: open ? .logicallyComplete : .removed) { lift = target } completion: {
                    moving = false
                    thaw()
                }
            }
            if open, lift == 0 {
                freeze(then: go)
            } else if !open, frozen != nil, let tab = browser.active, frozenID != tab.id {
                // Another card was picked: it's that page that grows out of
                // its card, from the picture it has.
                frozen = tab.isBlank ? UIImage() : (tab.snapshot ?? UIImage())
                frozenID = tab.id
                go()
            } else if !open, frozen != nil, let tab = browser.active, let image = tab.now() {
                // The page went on living under its picture (a carousel, a
                // video): pictured again, at once, so the live page takes
                // over from what it really looks like now. WebKit's own
                // picture took long enough, now and then, to be felt.
                frozen = image
                go()
            } else {
                go()
            }
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { browser.safe = $0 }
        // Hide Elements ends when its page is left behind.
        .onChange(of: browser.activeID) { _, _ in browser.stopZap() }
        .onChange(of: browser.showingTabs) { _, open in if open { browser.stopZap() } }
        .onChange(of: browser.editing) { _, on in if on { browser.stopZap() } }
        .onChange(of: browser.activeID, initial: true) { _, _ in
            guard !browser.showingTabs else { return }
            browser.privateView = browser.active?.isPrivate ?? false
        }
        // A link from another app (Search as the default browser): the page,
        // in front, whatever was showing over it.
        .onOpenURL { url in
            browser.settings = false
            browser.showingBookmarks = false
            browser.showingOthers = false
            browser.siteSheet = false
            if welcoming {
                Prefs.shared.welcomed = true
                welcoming = false
            }
            browser.open(url)
        }
        .onContinueUserActivity(Handoff.browsing) { activity in
            if let url = Handoff.address(in: activity) { browser.open(url) }
        }
        .sheet(isPresented: $browser.settings) {
            Settings(browser: browser)
                .presentationDetents([.large])
        }
        .fullScreenCover(isPresented: $welcoming) {
            Welcome {
                Prefs.shared.welcomed = true
                welcoming = false
                if browser.active?.isBlank == true { browser.editing = true }
            }
            .onAppear { browser.editing = false }
        }
        .sheet(isPresented: $browser.showingBookmarks) {
            BookmarksView(browser: browser)
        }
        .sheet(isPresented: $browser.showingOthers) {
            OtherTabs(browser: browser)
        }
        .sheet(isPresented: $browser.siteSheet) {
            if let tab = browser.active {
                SiteSheet(browser: browser, tab: tab)
            }
        }
        .confirmationDialog(
            closeAllTitle, isPresented: $browser.askingCloseAll, titleVisibility: .visible
        ) {
            Button(closeAllButton, role: .destructive) {
                Feel.nudge()
                withAnimation(Motion.settle) { browser.closeAll() }
            }
        }
        .onAppear {
            Shortcuts.browser = browser
            #if DEBUG
            // Test runs: `-open https://…` opens it, no typing needed.
            if let address = UserDefaults.standard.string(forKey: "open"), let url = URL(string: address) {
                browser.open(url)
            }
            // `-settings YES` opens Settings; `-look dark` then `-relook system`
            // switches the appearance while it's open, as a person would.
            // `-newtabs N` opens N new tabs, one every 3 seconds, as a person
            // tapping New tab would.
            let count = UserDefaults.standard.integer(forKey: "newtabs")
            for index in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(index) * 3) { browser.newTab() }
            }
            // `-liftTo 0.5` stops the tabs coming up half way, to see a frame.
            let stop = UserDefaults.standard.double(forKey: "liftTo")
            if stop > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { freeze { lift = stop } }
            }
            // `-reader YES` turns Reader on once the page has loaded.
            if UserDefaults.standard.bool(forKey: "reader") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if let tab = browser.active { browser.read(tab) } }
                let down = UserDefaults.standard.integer(forKey: "scrollY")
                DispatchQueue.main.asyncAfter(deadline: .now() + 9) { browser.active?.web.evaluateJavaScript("scrollTo(0,\(down))") }
            }
            // `-tabs YES` raises the tabs sheet once the page has drawn.
            if UserDefaults.standard.bool(forKey: "tabs") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { browser.showingTabs = true }
            }
            if UserDefaults.standard.bool(forKey: "settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { browser.settings = true }
            }
            if let first = UserDefaults.standard.string(forKey: "look").flatMap(Look.init) {
                Prefs.shared.look = first
            }
            if let then = UserDefaults.standard.string(forKey: "relook").flatMap(Look.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Prefs.shared.look = then }
            }
            #endif
        }
    }

    /// Where the page zooms to when the tabs come up: its card's picture,
    /// while tabs are cards and it has one.
    /// One layer of the tabs screen, the whole screen's size, never more: a
    /// taller one grew the stack, and the field above the keyboard slid down.
    /// Where Back stands in the rail, from the screen's top: under the
    /// camera, the clock and the signal, with room for the camera's pill to
    /// grow. A live activity or the camera in use (a call, a delivery)
    /// stretches it and pushes the clock and signal down about 34 points:
    /// at 170 they came over Back (27 Nov, two testers).
    static let railBack: CGFloat = 210

    private func sheet(_ layer: Sheet.Layer, size: CGSize, screen: CGSize, pageX: CGFloat) -> some View {
        Sheet(
            browser: browser,
            space: space,
            drag: { moved in lift = moved < 0 ? 1 + Self.give(-moved) / travel : 1 - moved / travel },
            dropped: { moved, speed in dropped(moved, speed: speed) },
            cardAt: { point in
                // The card's picture and the name under it.
                // Large cards: the topmost under the finger (the ones on
                // the right lie over the ones before them).
                Prefs.shared.tabDeck && Prefs.shared.tabCards
                    ? browser.tabs.last { tab in cardFrames.rects[tab.id].map { $0.insetBy(dx: 0, dy: -30).contains(point) } ?? false }?.id
                    : cardFrames.rects.first { $0.value.insetBy(dx: -4, dy: -4).offsetBy(dx: 0, dy: 15).union($0.value).contains(point) }?.key
            },
            grab: { id in
                // Pulled down from a card: that page grows out of it.
                guard let tab = browser.tabs.first(where: { $0.id == id }) else { return }
                browser.hold(tab)
                frozen = tab.isBlank ? UIImage() : (tab.snapshot ?? UIImage())
                frozenID = tab.id
            },
            lift: lift,
            away: lift == 0 && !moving && !dragging,
            frames: { id, rect in
                cardFrames.rects[id] = rect
            },
            zooming: zoomShown ? browser.activeID : nil,
            layer: layer,
            anchor: zoomTarget,
            screen: screen,
            pageX: pageX
        )
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(browser.showingTabs)
        .accessibilityHidden(!browser.showingTabs)
    }

    /// The page is in the air, between the screen and its card.
    private var zoomShown: Bool {
        zoomTarget != nil && frozen != nil && (moving || (lift > 0.001 && lift < 0.999))
    }

    /// How the tabs land: no bounce, so the page settles on its card
    /// rather than past it and back.
    static let landing = Animation.spring(response: 0.38, dampingFraction: 1)

    private var zoomTarget: CGRect? {
        guard Prefs.shared.tabCards, let tab = browser.active, tab.pin == nil,
              tab.isPrivate == browser.privateView,
              let rect = cardFrames.rects[tab.id], rect.width > 10 else { return nil }
        return rect
    }

    private var loose: Int { browser.tabs.filter { $0.pin == nil }.count }
    private var closeAllTitle: String {
        browser.pinnedCount > 0 ? String(localized: "Close every tab but the pinned ones?") : String(localized: "Close every tab?")
    }
    private var closeAllButton: String { loose == 1 ? String(localized: "Close 1 Tab") : String(localized: "Close \(loose) Tabs") }

    // MARK: - the pages

    /// This page, and the one either side of it when walked. The page shrinks
    /// back into a card while the sheet is up, and while it is being walked,
    /// so the edge between two pages reads as an edge.
    private func deck(width: CGFloat, top: CGFloat) -> some View {
        // How far the nearest page is from filling the screen: nothing at
        // rest and nothing again once a walk has landed on the next one, so
        // the landed picture is already full size when the live page takes
        // its place.
        let reach = width + Metrics.gap
        let away = min(1, min(abs(walk), max(0, reach - abs(walk))) / 60)
        // With cards, the page zooms into its own card (above the sheet):
        // here it only steps aside.
        let zooms = zoomTarget != nil
        let scale = 1 - (zooms ? 0 : 0.08 * lift) - 0.04 * away
        let corner = 44 * max(zooms ? 0 : lift, away)
        // Beside a Duo's rail the page stops at it: under it, ignoring the
        // safe area, the page ran on behind the rail's band.
        let edges: Edge.Set = browser.rail.on ? .vertical : .all
        return ZStack {
            // The live page, always at its full size. Hidden, not moved,
            // while its picture stands in for it.
            if let tab = browser.active {
                Page(tab: tab, top: top, covered: lift > 0.02 || browser.editing || frozen != nil, edges: edges)
                    .opacity(frozen == nil ? 1 : 0)
                    .overlay {
                        if browser.locked, tab.isPrivate { Locked(browser: browser) }
                    }
            }

            if frozen != nil {
                ZStack {
                    if walk < 0 {
                        Card(tab: browser.neighbour(1), top: top, edges: edges)
                            .offset(x: width + Metrics.gap + walk)
                    }
                    if walk > 0 {
                        Card(tab: browser.neighbour(-1), top: top, edges: edges)
                            .offset(x: -(width + Metrics.gap) + walk)
                    }
                    Still(image: frozen, tint: browser.active?.behindClock, top: top, band: max(0, 1 - lift * 4))
                        .overlay {
                            if browser.locked, browser.active?.isPrivate == true { Locked(browser: browser) }
                        }
                        .offset(x: walk)
                }
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .scaleEffect(scale, anchor: lift > 0 ? .top : .center)
                .offset(y: zooms ? 0 : 54 * lift)
                .opacity(zooms && (lift > 0.001 || moving) ? 0 : 1)
            }
        }
        .frame(width: width)
        .overlay {
            Color.black
                .opacity(0.08 * lift)
                .ignoresSafeArea()
                .allowsHitTesting(lift > 0)
                .onTapGesture { browser.showingTabs = false }
        }
        .ignoresSafeArea(edges: edges)
    }

    /// The page in front becomes a picture, for as long as something moves it.
    /// The page in front becomes its picture, for as long as something
    /// moves it; `then` runs once the picture is in place. Until then the
    /// live page stays, still.
    private func freeze(then: (() -> Void)? = nil) {
        guard frozen == nil else { then?(); return }
        guard !freezing else { return }
        guard let tab = browser.active, !tab.isBlank else {
            frozen = UIImage()
            frozenID = browser.activeID
            then?()
            return
        }
        // At once when it can be had, so the page moves from the finger's
        // first point; WebKit's picture still comes, for the card.
        if let image = tab.now() {
            frozen = image
            frozenID = tab.id
            then?()
            return
        }
        freezing = true
        tab.snap { image in
            freezing = false
            frozen = image ?? tab.snapshot ?? UIImage()
            if let image { tab.keep(image) }
            frozenID = tab.id
            then?()
            // A drag that ended before the picture came: nothing to move.
            if then == nil, !dragging { thaw() }
        }
    }

    /// Nothing moving any more: the live page again.
    private func thaw() {
        guard walk == 0, lift == 0, !landing else { return }
        frozen = nil
        frozenID = nil
    }

    /// The site the pill names while a walk is far enough to land on another
    /// page.
    private func heading(width: CGFloat) -> String? {
        guard abs(walk) > width * 0.33 else { return nil }
        if let there = browser.neighbour(walk < 0 ? 1 : -1) { return there.short }
        return walk < 0 ? "New tab" : nil
    }

    private func walking(_ moved: CGFloat, width: CGFloat) {
        guard !landing else { return }
        dragging = true
        if frozen == nil {
            freeze()
            guard frozen != nil else { walkFrom = moved; return }
            walkFrom = 0
        }
        let moved = moved - walkFrom
        let reach = moved < 0 ? 1 : -1
        // Past the first page there is nothing: the page gives, and comes
        // back. Past the last there is a new one.
        let open = browser.neighbour(reach) != nil || reach == 1
        let next = open ? moved : moved * 0.25
        let crossed = abs(next) > width * 0.33
        if crossed != (abs(walk) > width * 0.33) { Feel.tick() }
        walk = next
    }

    private func walked(_ moved: CGFloat, speed: CGFloat, width: CGFloat) {
        dragging = false
        guard !landing else { return }
        guard frozen != nil else { return }
        let moved = moved - walkFrom
        let reach = moved < 0 ? 1 : -1
        let there = browser.neighbour(reach)
        let open = there != nil || reach == 1
        let landingAt = moved + speed * 0.15
        guard open, abs(landingAt) > width * 0.5, (landingAt < 0) == (moved < 0) else {
            withAnimation(Motion.thrown(velocity: speed, distance: -walk)) { walk = 0 } completion: {
                thaw()
            }
            return
        }
        let end = CGFloat(-reach) * (width + Metrics.gap)
        landing = true
        withAnimation(still ? Motion.quick : Motion.thrown(velocity: speed, distance: end - walk)) {
            walk = end
        } completion: {
            var now = Transaction()
            now.disablesAnimations = true
            withTransaction(now) {
                if let there {
                    browser.select(there)
                } else {
                    browser.newTab()
                }
                walk = 0
                landing = false
                frozen = nil
            }
        }
    }

    // MARK: - the sheet

    private func lifting(_ moved: CGFloat) {
        let first = !dragging
        dragging = true
        liftSeen = Date()
        liftLast = moved
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard dragging, Date().timeIntervalSince(liftSeen) >= 1.9 else { return }
            lifted(liftLast, speed: 0)
        }
        // Over the tabs the bar takes them away, down.
        if browser.showingTabs {
            lift = 1 - max(0, moved) / travel
            return
        }
        if frozen == nil {
            freeze()
            // Pictured at once: the page goes from where the finger set
            // off. Waited for: from where the finger is when it comes.
            guard frozen != nil else { liftFrom = moved; return }
            liftFrom = 0
        } else if first {
            // Caught while still settling back into the page: it goes on
            // from where it is, not from where the last drag left off.
            liftFrom = moved + max(0, lift) * travel
        }
        let up = -(moved - liftFrom)
        lift = up <= travel ? max(0, up / travel) : 1 + Self.give(up - travel) / travel
    }

    private func lifted(_ moved: CGFloat, speed: CGFloat) {
        dragging = false
        if browser.showingTabs {
            dropped(max(0, moved), speed: speed)
            return
        }
        guard frozen != nil else { return }
        settle(open: Self.goes(lift, up: -speed, opening: true), speed: -speed)
    }

    private func dropped(_ moved: CGFloat, speed: CGFloat) {
        settle(open: Self.goes(lift, up: -speed, opening: false), speed: -speed)
    }

    /// Whether a let-go lift ends open. A finger still moving says where it
    /// was going, however little it went; a finger at rest finishes what it
    /// began once it's a third of the way.
    static func goes(_ lift: CGFloat, up: CGFloat, opening: Bool) -> Bool {
        if up > 120 { return true }
        if up < -120 { return false }
        return opening ? lift > 0.3 : lift > 0.7
    }

    /// Past its resting place the sheet gives a few points, and no more.
    static func give(_ over: CGFloat) -> CGFloat {
        8 * (1 - exp(-over / 40))
    }

    /// Lets the sheet go, up or down, at the speed it was let go at.
    private func settle(open: Bool, speed: CGFloat) {
        let target: CGFloat = open ? 1 : 0
        // SwiftUI wants the speed as a share of what's left to travel.
        let rate = speed / travel
        let left = target - lift
        let share = abs(left) < 0.02 ? 0 : max(-8, min(8, rate / left))
        moving = true
        withAnimation(
            still ? Motion.quick : .interpolatingSpring(
                Spring(response: 0.38, dampingRatio: 1), initialVelocity: share
            ),
            completionCriteria: .removed
        ) {
            lift = target
        } completion: {
            moving = false
            thaw()
        }
        if browser.showingTabs != open {
            if open { Feel.tick() }
            browser.showingTabs = open
        }
    }
}

/// Where each card's picture is on screen, by tab.
final class Frames {
    var rects: [Tab.ID: CGRect] = [:]
}

/// The band beside a Duo's rail: the colour at the top of the page, as it
/// changes (watched here: read from above, it stayed the colour it had
/// before the page drew).
struct RailBand: View {
    @ObservedObject var tab: Tab

    var body: some View {
        (tab.isBlank || tab.failure != nil ? nil : tab.railColour).map { Color(uiColor: $0) } ?? Palette.ground
    }
}
