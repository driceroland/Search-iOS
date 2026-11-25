import SwiftUI
import WebKit

/// The one thing on a page: where you are, and how many pages are open.
///
/// At the bottom because that is where a thumb is. Every way in starts here:
/// tap to type, drag sideways to walk the tabs, drag up for all of them, hold
/// for the page's own menu. While the page scrolls it folds down to the site's
/// name, following the page rather than a timer, and a tap opens it again.
struct Pill: View {
    @ObservedObject var tab: Tab
    @ObservedObject var chrome: Chrome
    let count: Int
    /// Shown instead of this page's site while a walk is far enough to land
    /// somewhere else.
    var heading: String?
    let space: Namespace.ID

    var type: () -> Void
    var tabs: () -> Void
    var hold: () -> Void
    var closeAll: () -> Void = {}
    var walk: (CGFloat) -> Void
    var walked: (CGFloat, CGFloat) -> Void
    var lift: (CGFloat) -> Void
    var lifted: (CGFloat, CGFloat) -> Void
    /// Whether the pill's shape is the one the field takes its place from
    /// (on a page), or the one that follows the field's (while typing).
    var source = true
    /// How far the tabs are up: 0 on a page, 1 over the tabs, where the
    /// pill is New tab, Back has gone by the side and Tabs is Bookmarks.
    var morph: CGFloat = 0
    /// The tabs are up: taps and drags are theirs.
    var over = false
    var newTab: () -> Void = {}
    /// New tab makes a private one: the private side of the tabs shows.
    var newPrivate = false
    /// The Duo's column beside the camera, where Back and Tabs stand.
    var rail = Rail()
    var bookmarks: () -> Void = {}

    private enum Axis { case none, walk, lift, ignored }
    @State private var axis: Axis = .none
    /// Where the glass of the three pieces is named, so that on iOS 26 the
    /// side buttons melt into the pill and out of it again.
    @Namespace private var glass

    /// How far the bar has folded, following the page as Safari's does: 0
    /// open, 1 the small capsule with the site's name alone.
    private var f: CGFloat { chrome.fold }
    private var tucked: Bool { f > 0.5 }
    /// The site's name at the folded size, measured, so the capsule can
    /// close in around it.
    @State private var nameWidth: CGFloat = 80

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width - 32
            let small = min(full, nameWidth + 36)
            // Folded: just round the name.
            let folded = 16 + (full - small) / 2
            // Open: between the two buttons; with a rail, from the far edge
            // to the rail, its buttons standing in it.
            let between = 16 + Metrics.pill + 8
            let openL = rail.on ? (rail.leading ? rail.width + 8 : 16) : between
            let openR = rail.on ? (rail.leading ? 16 : rail.width + 8) : between
            let l0 = openL + (folded - openL) * f
            let r0 = openR + (folded - openR) * f
            // Over the tabs, Tabs' room is the pill's: New tab reaches the
            // edge where the thumb that opened the tabs already is.
            let tabsLeading = rail.on && rail.leading
            let l = tabsLeading ? l0 + (16 - l0) * morph : l0
            let r = tabsLeading ? r0 : r0 + (16 - r0) * morph
            ZStack(alignment: .bottom) {
                address
                    .padding(.leading, l)
                    .padding(.trailing, r)
                // Gone once folded, for the same reason as Tabs (below).
                if f < 0.5 {
                    buttons
                        .opacity(Double(max(0, 1 - f * 2)))
                        .scaleEffect(1 - 0.12 * f, anchor: .bottom)
                        .allowsHitTesting(!tucked)
                        .accessibilityHidden(tucked)
                }
            }
            // One glass for the three: each on its own turned light or dark
            // by what was under it alone, and a dark headline under the
            // pill left it black between two white buttons.
            .glassTogether()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Metrics.pill)
        .padding(.bottom, 8 - 6 * f)
        .contentShape(Rectangle())
        .gesture(Pan(action: pan))
        // Folded, the bar is small: a tap anywhere about it opens it again,
        // not only one that lands on the capsule itself.
        .gesture(Tap { if tucked { chrome.unfold(animated: true) } })
        .gesture(Hold { if !tucked, !over { Feel.nudge(); hold() } })
    }

    /// Back and Tabs: either side of the pill on an iPhone; one over the
    /// other in the rail on a Duo, Tabs at the foot by the thumb. They stay
    /// where they are and leave outward, fading, as the pill closes in.
    @ViewBuilder private var buttons: some View {
        if rail.on {
            // Tabs alone here: Back stands up the rail on its own (RailBack).
            // Drawn from here, offset above the bar, it showed but no tap
            // ever reached it, outside the bar's own frame.
            tabsButton
            .padding(rail.edge, rail.inset)
            .offset(x: 28 * f * rail.out)
            .frame(maxWidth: .infinity, alignment: rail.alignment)
        } else {
            HStack(spacing: 0) {
                back.offset(x: -28 * f)
                Spacer(minLength: 0)
                tabsButton.offset(x: 28 * f)
            }
            .padding(.horizontal, 16)
        }
    }

    /// Back on a page, Bookmarks over the tabs: one button, its icon turning.
    private var back: some View {
        side("chevron.left", morph > 0.5 ? "Bookmarks" : "Back",
             strength: tab.canGoBack ? 1 : 0.35 + 0.65 * Double(morph),
             other: "book", turn: morph) {
            if over {
                bookmarks()
            } else if tab.canGoBack {
                Feel.tick()
                tab.back()
            }
        }
    }

    /// Tabs, melting into New tab as the pill reaches it. Still there to
    /// the finger: tapped twice, it opens the tabs, then a new one.
    /// Gone, not only see-through, once the pill has taken its place: in
    /// the glass container a see-through button kept its glass, sat at the
    /// end of New tab and, tapped, opened one more new tab.
    @ViewBuilder private var tabsButton: some View {
        if morph < 0.62 {
            side("square.on.square", "Tabs") {
                if over { newTab() } else { tabs() }
            }
            .opacity(Double(max(0, 1 - morph * 1.6)))
            .scaleEffect(1 - 0.25 * morph)
            .accessibilityValue(Text("\(count)"))
        }
    }

    private var address: some View {
        let height = Metrics.pill - (Metrics.pill - Metrics.pillFolded) * f
        // Everything before the name gives its room back as the bar folds,
        // with the finger: no step where it would vanish all at once.
        return ZStack {
        HStack(spacing: 0) {
            if heading == nil, tab.isPrivate {
                Image(systemName: "eyeglasses")
                    .font(.scaled(12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .collapsing(f)
            }
            if heading == nil, !tab.isBlank {
                Group {
                    if tab.loading {
                        Ring()
                    } else {
                        Mark(icon: tab.icon, letter: tab.letter, size: 15)
                    }
                }
                .collapsing(f)
            }
            if heading == nil, tab.address?.scheme?.lowercased() == "http" {
                // Safari's word for a page sent in the clear.
                Text("Not secure")
                    .font(.scaled(13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .collapsing(f)
            }
            Text(heading ?? tab.short)
                .font(.scaled(15.5 - 3 * f))
                .foregroundStyle(tab.isBlank && heading == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .id(heading ?? tab.short)
                .transition(.opacity)
        }
        .modifier(Handover(t: morph, leaving: true, shrink: 0.08))
        Label(newPrivate ? "New private tab" : "New tab", systemImage: newPrivate ? "eyeglasses" : "plus")
            .labelStyle(.titleAndIcon)
            .font(.scaled(15, weight: .medium))
            .foregroundStyle(.primary)
            .modifier(Handover(t: morph, leaving: false, shrink: 0.08))
            .accessibilityHidden(morph < 0.5)
        }
        .padding(.horizontal, 14 - 4 * f)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            // The name at its folded size, never shown: how narrow the
            // capsule may get.
            Text(heading ?? tab.short)
                .font(.scaled(12.5))
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { nameWidth = $0 }
        }
        .glass(Capsule(), interactive: true, else: .clear)
        .background { if #unavailable(iOS 26.0) { Glass(shape: Capsule()) } }
        .overlay(alignment: .bottom) {
            // The loading line lives in the pill, along its foot, where the
            // eye already is.
            Loading(tab: tab).clipShape(Capsule()).allowsHitTesting(false)
        }
        // The whole pill, its words with it, takes the field's place and
        // gives it back: the words travel with the capsule, not after it.
        .matchedGeometryEffect(id: "pill", in: space, isSource: source)
        .contentShape(Capsule())
        .gesture(Tap {
            if over {
                newTab()
            } else if tucked {
                chrome.unfold(animated: true)
            } else {
                type()
            }
        })
        .animation(Motion.quick, value: heading)
    }

    /// A round glass button either side of the pill: Back on the left, as in
    /// Safari, every tab on the right. White on the glass; dimmed when there
    /// is nowhere to go.
    private func side(_ symbol: String, _ name: LocalizedStringKey, strength: Double = 1, other: String? = nil, turn: CGFloat = 0, action: @escaping () -> Void) -> some View {
        // One button, its icon turning into the other one's.
        ZStack {
            Image(systemName: symbol)
                .modifier(Handover(t: other == nil ? 0 : turn, leaving: true, shrink: 0.3))
            if let other {
                Image(systemName: other)
                    .modifier(Handover(t: turn, leaving: false, shrink: 0.3))
            }
        }
            .font(.scaled(17, weight: .medium))
            .foregroundStyle(.primary)
            .opacity(strength)
            .frame(width: Metrics.pill, height: Metrics.pill)
            .glass(Circle(), interactive: true, else: .clear)
            .background { if #unavailable(iOS 26.0) { Glass(shape: Circle()) } }
            // The whole corner answers, not only the circle: a thumb
            // reaching for it lands around it as often as on it.
            .padding(8)
            .contentShape(Rectangle())
            .gesture(Tap(action: action))
            .padding(-8)
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isButton)
    }

    private func pan(_ recognizer: UIPanGestureRecognizer) {
        let moved = recognizer.translation(in: nil)
        let speed = recognizer.velocity(in: nil)
        switch recognizer.state {
        case .began:
            axis = .none
            if chrome.fold > 0 { chrome.unfold(animated: true) }
        case .changed:
            // One gesture, one direction: whichever the finger set off in.
            // Decided on the first real movement — a pan can begin at zero.
            if axis == .none, max(abs(moved.x), abs(moved.y)) > 3 {
                if over {
                    // Over the tabs the bar is New tab: a drag on it goes
                    // nowhere. Only a card, pulled down, goes back to a page.
                    axis = .ignored
                } else {
                    axis = abs(moved.x) > abs(moved.y) ? .walk : (moved.y < 0 ? .lift : .ignored)
                }
            }
            switch axis {
            case .walk: walk(moved.x)
            case .lift: lift(moved.y)
            case .none, .ignored: break
            }
        case .ended, .cancelled, .failed:
            switch axis {
            case .walk: walked(moved.x, speed.x)
            case .lift: lifted(moved.y, speed.y)
            case .none, .ignored: break
            }
            axis = .none
        default:
            break
        }
    }
}

/// The pill's surface. On iOS 26, Liquid Glass: the system's own glass,
/// bending the page under it and answering the finger. Before, the ground,
/// a little see-through over a blur of the page.
struct Glass<S: InsettableShape>: View {
    let shape: S
    var shadow: CGFloat = 1

    var body: some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular.interactive(), in: shape)
        } else {
            shape
                .fill(.regularMaterial)
                .overlay(shape.fill(Palette.ground.opacity(0.72)))
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.08 * shadow), radius: 20, y: 6)
        }
    }
}

extension View {
    /// The pill's own glass, named so that pieces in one container melt
    /// together; before iOS 26, the old surface.
    @ViewBuilder
    func surface<S: InsettableShape>(_ shape: S, id: String, in space: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape).glassEffectID(id, in: space)
        } else {
            background(Glass(shape: shape))
        }
    }

    /// Glass pieces read the page together, and so turn light or dark
    /// together; before iOS 26, nothing.
    @ViewBuilder
    func glassTogether() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { self }
        } else {
            self
        }
    }

    /// Liquid Glass in this shape on iOS 26; the given colour before.
    @ViewBuilder
    func glass<S: Shape>(_ shape: S, interactive: Bool = false, else fallback: Color = Palette.ground) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }
}

/// How far the page has come, as a hairline along the pill's foot.
private struct Loading: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Palette.ink.opacity(0.55))
                .frame(width: geo.size.width * tab.progress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.easeOut(duration: 0.22), value: tab.progress)
        }
        .opacity(tab.loading ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: tab.loading)
        .allowsHitTesting(false)
    }
}

/// The page's own menu, out of the held pill.
struct Held: View {
    @ObservedObject var browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject private var sites = Sites.shared
    @ObservedObject private var bookmarks = Bookmarks.shared
    var done: () -> Void

    private var zoom: Double { tab.textZoom }

    var body: some View {
        // Whole when it fits; scrolling, Back first, on a screen too short
        // for every row (an open Duo is 669 points high).
        ViewThatFits(in: .vertical) {
            rows
            ScrollView { rows }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
        }
        // A phone's width at most: across a Duo's whole screen the rows
        // were a long way from their words.
        .frame(maxWidth: 440)
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .modifier(Edge(radius: 26))
        .padding(.horizontal, 16)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                arrow("chevron.left", enabled: tab.canGoBack, list: tab.web.backForwardList.backList.reversed()) { tab.back() }
                arrow("chevron.right", enabled: tab.canGoForward, list: tab.web.backForwardList.forwardList) { tab.forward() }
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 0) {
                half("doc.on.doc", "Copy address", enabled: !tab.isBlank) { browser.copyAddress(tab) }
                Rectangle().fill(Palette.hairline).frame(width: 1, height: 26)
                half("doc.on.clipboard", "Paste and go", enabled: UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs) {
                    browser.pasteAndGo()
                }
            }
            line
            if !tab.isBlank {
                sizes
                line
            }
            item(tab.loading ? "xmark" : "arrow.clockwise", tab.loading ? "Stop" : "Reload") {
                tab.loading ? tab.stop() : tab.reload()
            }
            line
            item("square.and.arrow.up", "Share") { browser.share(tab) }
            line
            item("text.magnifyingglass", "Find on page") { browser.find(tab) }
            line
            item("doc.plaintext", tab.reading ? "Leave Reader" : "Reader") { browser.read(tab) }
            if !tab.isBlank {
                line
                item("eye.slash", "Hide Elements") { browser.zap(tab) }
                line
                item("slider.horizontal.3", "This site") { browser.siteSheet = true }
            }
            line
            item(tab.pin != nil ? "pin.slash" : "pin", tab.pin != nil ? "Unpin" : "Pin") { browser.pin(tab) }
            if let url = tab.address, !tab.isPrivate {
                line
                if bookmarks.contains(url) {
                    item("book.fill", "In Bookmarks") { browser.showingBookmarks = true }
                } else {
                    item("book", "Add to Bookmarks") {
                        Bookmarks.shared.add(url, title: tab.title)
                        browser.say(String(localized: "Added to Bookmarks"))
                    }
                }
            }
            if browser.roomy, !Prefs.shared.sidebar {
                line
                item("sidebar.left", "Show Sidebar") { Prefs.shared.sidebar = true }
            }
            line
            item("xmark", "Close Tab") { browser.close(tab) }
        }
    }

    private var line: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 54)
    }

    /// The text size, smaller and larger, and the size now: tapping it
    /// goes back to 100 %. Kept for the site.
    private var sizes: some View {
        HStack(spacing: 0) {
            Button {
                Feel.tick()
                browser.zoom(tab, step: -1)
            } label: {
                Text("A").font(.scaled(13)).frame(maxWidth: .infinity).frame(height: 46).contentShape(Rectangle())
            }
            .buttonStyle(Pressed())
            Button {
                Feel.tick()
                browser.zoom(tab, step: 0)
            } label: {
                Text("\(Int((zoom * 100).rounded())) %")
                    .font(.scaled(14))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity).frame(height: 46).contentShape(Rectangle())
            }
            .buttonStyle(Pressed())
            Button {
                Feel.tick()
                browser.zoom(tab, step: 1)
            } label: {
                Text("A").font(.scaled(19)).frame(maxWidth: .infinity).frame(height: 46).contentShape(Rectangle())
            }
            .buttonStyle(Pressed())
        }
        .foregroundStyle(Palette.ink)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text size")
    }

    /// Back or forward; held, every page that way.
    private func arrow(_ name: String, enabled: Bool, list: [WKBackForwardListItem], action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            action()
            done()
        } label: {
            Image(systemName: name)
                .font(.scaled(17, weight: .medium))
                .foregroundStyle(enabled ? Palette.ink : Palette.off)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .contextMenu {
            ForEach(Array(list.prefix(20).enumerated()), id: \.offset) { _, item in
                Button {
                    tab.web.go(to: item)
                    done()
                } label: {
                    Text(item.title?.isEmpty == false ? item.title! : Address.pretty(item.url))
                }
            }
        }
    }

    private func half(_ symbol: String, _ title: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            action()
            done()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.scaled(14))
                Text(title).font(.scaled(14.5)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? Palette.ink : Palette.off)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressed())
        .disabled(!enabled)
    }

    private func item(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            action()
            done()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.scaled(16))
                    .frame(width: 22)
                Text(title).font(.scaled(16))
                Spacer()
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 18)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressed())
    }
}

/// A row that greys while a finger is on it, the way the Mac's rows do under
/// the pointer.
struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.hover : Color.clear)
    }
}

/// Before iOS 26, the hairline and shadow that stand in for glass.
private struct Edge: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 30, y: 10)
        }
    }
}

/// A piece of the pill that folds away with the bar: it fades, shrinks and
/// hands back its width and the gap after it, all in step with the fold.
private struct Collapsing: ViewModifier {
    let fold: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let keep = max(0, 1 - fold)
        content
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .scaleEffect(0.6 + 0.4 * keep, anchor: .center)
            .opacity(Double(max(0, 1 - fold * 1.6)))
            .frame(width: (width + 7) * keep, alignment: .leading)
            .clipped()
    }
}

extension View {
    func collapsing(_ fold: CGFloat) -> some View { modifier(Collapsing(fold: fold)) }
}

/// One thing giving way to another as `t` goes from 0 to 1: the leaving one
/// gone by half way, the coming one only from there. Worked out on every
/// frame of the motion: left to SwiftUI, the end opacities were blended
/// straight, and half way both showed at once, one over the other.
struct Handover: ViewModifier, Animatable {
    var t: CGFloat
    let leaving: Bool
    let shrink: CGFloat

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func body(content: Content) -> some View {
        let p = max(0, min(1, t))
        return content
            .opacity(Double(leaving ? max(0, 1 - p * 2) : max(0, p * 2 - 1)))
            .scaleEffect(leaving ? 1 - shrink * p : 1 - shrink + shrink * p)
    }
}

/// Back, standing up a Duo's rail under the clock, where a thumb reaches
/// it; Bookmarks over the tabs, its icon turning as the bar's do.
struct RailBack: View {
    @ObservedObject var tab: Tab
    let morph: CGFloat
    let over: Bool
    let bookmarks: () -> Void

    var body: some View {
        ZStack {
            Image(systemName: "chevron.left")
                .modifier(Handover(t: morph, leaving: true, shrink: 0.3))
            Image(systemName: "book")
                .modifier(Handover(t: morph, leaving: false, shrink: 0.3))
        }
        .font(.scaled(17, weight: .medium))
        .foregroundStyle(.primary)
        .opacity(tab.canGoBack || over ? 1 : 0.35 + 0.65 * Double(morph))
        .frame(width: Metrics.pill, height: Metrics.pill)
        .glass(Circle(), interactive: true, else: .clear)
        .background { if #unavailable(iOS 26.0) { Glass(shape: Circle()) } }
        .contentShape(Circle())
        .onTapGesture {
            if over {
                bookmarks()
            } else if tab.canGoBack {
                Feel.tick()
                tab.back()
            }
        }
        .accessibilityLabel(morph > 0.5 ? "Bookmarks" : "Back")
        .accessibilityAddTraits(.isButton)
    }
}
