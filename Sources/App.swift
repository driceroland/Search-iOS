import SwiftUI

// A page, and a pill at the bottom. Everything else is summoned and put away,
// and everything that moves goes where the finger takes it.

@main
struct SearchApp: App {
    @StateObject private var browser = Browser()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let number = Mock.screen {
                MockScreen(number: number)
            } else {
                ContentView(browser: browser)
                    .preferredColorScheme(.light)
            }
            #else
            ContentView(browser: browser)
                .preferredColorScheme(.light)
            #endif
        }
        .onChange(of: phase) { _, now in
            if now == .background { browser.rest() }
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
    @State private var sheetHeight: CGFloat = 420
    /// The page, as a picture, while it's walked or shrunk for the sheet:
    /// the web view itself stays where it is, at its size, untouched.
    @State private var frozen: UIView?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            ZStack(alignment: .bottom) {
                // Behind the pages: a grey, not black, so the clock can still
                // be read when the page steps back for the sheet.
                Palette.backdrop.ignoresSafeArea()

                deck(width: width, top: geo.safeAreaInsets.top)

                // The page fades into a blur toward the bottom edge, under
                // the pill, the way iOS's own bars sit on what scrolls.
                Fade()
                    .frame(height: geo.safeAreaInsets.bottom + Metrics.pill + 52)
                    .opacity(Double(1 - min(1, lift)))
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .bottom)

                if browser.editing {
                    Palette.ground.opacity(0.74)
                        .ignoresSafeArea()
                        .onTapGesture { browser.dismiss() }
                        .transition(.opacity)
                }

                if !browser.editing, let tab = browser.active {
                    Pill(
                        tab: tab,
                        chrome: browser.chrome,
                        count: browser.tabs.count,
                        heading: heading(width: width),
                        space: space,
                        type: { withAnimation(Motion.glide) { browser.edit() } },
                        tabs: { Feel.tick(); browser.showingTabs = true },
                        hold: { withAnimation(Motion.settle) { browser.holding = true } },
                        walk: { walking($0, width: width) },
                        walked: { walked($0, speed: $1, width: width) },
                        lift: { lifting($0) },
                        lifted: { lifted($0, speed: $1) }
                    )
                    .opacity(1 - lift)
                    .allowsHitTesting(lift == 0 && !landing && !browser.holding)
                    .transition(.opacity)
                }

                if browser.holding, let tab = browser.active {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(Motion.settle) { browser.holding = false } }
                    Held(tab: tab, pinned: tab.pin != nil) {
                        withAnimation(Motion.settle) { browser.holding = false }
                    } pin: {
                        browser.pin(tab)
                    } read: {
                        browser.read(tab)
                    } shield: {
                        browser.shield(tab)
                    } share: {
                        browser.share(tab)
                    } find: {
                        browser.find(tab)
                    }
                    .padding(.bottom, Metrics.pill + 18)
                    .transition(.scale(0.9, anchor: .bottom).combined(with: .opacity))
                }

                // Always there, below the edge when down, so that letting it
                // go can animate it all the way out.
                Sheet(
                        browser: browser,
                        space: space,
                        drag: { moved in lift = moved < 0 ? 1 + Self.give(-moved) / sheetHeight : 1 - moved / sheetHeight },
                        dropped: { moved, speed in dropped(moved, speed: speed) },
                        height: { sheetHeight = max(200, $0) }
                    )
                    .offset(y: (1 - lift) * (sheetHeight + 40))
                    .allowsHitTesting(browser.showingTabs)
                    .accessibilityHidden(!browser.showingTabs)

                if browser.editing {
                    Field(browser: browser, space: space)
                        // Above the keyboard, by the keyboard's own measure:
                        // this view ignores it, so nothing else moves when
                        // it comes and goes.
                        .padding(.bottom, max(0, keyboard.height - geo.safeAreaInsets.bottom))
                        .transition(.opacity)
                }

                if let words = browser.toast {
                    Text(words)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(Glass(shape: Capsule()))
                        .padding(.bottom, Metrics.pill + 22)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
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
            if open, lift == 0 { freeze() }
            withAnimation(still ? Motion.quick : Motion.glide) { lift = target } completion: {
                thaw()
            }
        }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { browser.safe = $0 }
        .onOpenURL { browser.open($0) }
    }

    // MARK: - the pages

    /// This page, and the one either side of it when walked. The page shrinks
    /// back into a card while the sheet is up, and while it is being walked,
    /// so the edge between two pages reads as an edge.
    private func deck(width: CGFloat, top: CGFloat) -> some View {
        let away = min(1, abs(walk) / 60)
        let scale = 1 - 0.08 * lift - 0.04 * away
        let corner = 44 * max(lift, away)
        return ZStack {
            // The live page, always at its full size. Hidden, not moved,
            // while its picture stands in for it.
            if let tab = browser.active {
                Page(tab: tab, top: top)
                    .opacity(frozen == nil ? 1 : 0)
            }

            if frozen != nil {
                ZStack {
                    if walk < 0 {
                        Card(tab: browser.neighbour(1), top: top)
                            .offset(x: width + Metrics.gap + walk)
                    }
                    if walk > 0 {
                        Card(tab: browser.neighbour(-1), top: top)
                            .offset(x: -(width + Metrics.gap) + walk)
                    }
                    Still(view: frozen, tint: browser.active?.tint, top: top)
                        .offset(x: walk)
                }
                .frame(width: width)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .scaleEffect(scale, anchor: lift > 0 ? .top : .center)
                .offset(y: 54 * lift)
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
        .ignoresSafeArea()
    }

    /// The page in front becomes a picture, for as long as something moves it.
    private func freeze() {
        guard frozen == nil else { return }
        browser.active?.capture()
        frozen = browser.active?.freeze() ?? UIView()
    }

    /// Nothing moving any more: the live page again.
    private func thaw() {
        guard walk == 0, lift == 0, !landing else { return }
        frozen = nil
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
        if walk == 0 { freeze() }
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
        guard !landing else { return }
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
        if !browser.showingTabs, lift == 0 { freeze() }
        let up = -moved
        lift = up <= sheetHeight ? max(0, up / sheetHeight) : 1 + Self.give(up - sheetHeight) / sheetHeight
    }

    private func lifted(_ moved: CGFloat, speed: CGFloat) {
        settle(open: lift + (-speed * 0.15) / sheetHeight > 0.5, speed: -speed)
    }

    private func dropped(_ moved: CGFloat, speed: CGFloat) {
        settle(open: lift - (speed * 0.15) / sheetHeight > 0.5, speed: -speed)
    }

    /// Past its resting place the sheet gives a few points, and no more.
    static func give(_ over: CGFloat) -> CGFloat {
        8 * (1 - exp(-over / 40))
    }

    /// Lets the sheet go, up or down, at the speed it was let go at.
    private func settle(open: Bool, speed: CGFloat) {
        let target: CGFloat = open ? 1 : 0
        // SwiftUI wants the speed as a share of what's left to travel.
        let rate = speed / sheetHeight
        let left = target - lift
        let share = abs(left) < 0.02 ? 0 : max(-12, min(12, rate / left))
        withAnimation(
            still ? Motion.quick : .interpolatingSpring(
                Spring(response: 0.34, dampingRatio: 0.86), initialVelocity: share
            )
        ) {
            lift = target
        } completion: {
            thaw()
        }
        if browser.showingTabs != open {
            if open { Feel.tick() }
            browser.showingTabs = open
        }
    }
}
