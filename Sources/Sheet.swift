import SwiftUI

/// Every open page — the Mac's column, risen from the bottom.
///
/// Pins first, as letters in rows of at most four, fuller rows first (the
/// Mac's rule: 5 → 3 + 2). Then one line per page, the way the Mac's tabs are
/// one line: what it is, then where it came from, and the grey behind the one
/// you're on, which slides to the one you pick. Swipe a line left to close it,
/// right to pin it. Or, as most people know them on a phone and by default,
/// as cards: a picture of each page, two by two, its name under it.
///
/// The sheet goes where the finger takes it. Drag it down by its top, or pull
/// the list down past its start, and let go.
struct Sheet: View {
    @ObservedObject var browser: Browser
    let space: Namespace.ID

    var drag: (CGFloat) -> Void
    var dropped: (CGFloat, CGFloat) -> Void
    /// The card under a point on screen, if any.
    var cardAt: (CGPoint) -> Tab.ID? = { _ in nil }
    /// A drag down set off from this card: its page is the one to go back to.
    var grab: (Tab.ID) -> Void = { _ in }
    /// How far it has come: 0 away, 1 all there. The top comes down from
    /// above and the foot up from below as it does; the cards in between.
    var lift: CGFloat
    /// All the way gone and nothing moving: the grid may be scrolled
    /// unseen.
    var away = true
    /// Where each card's picture is on screen, for the page to zoom into.
    var frames: (Tab.ID, CGRect) -> Void = { _, _ in }
    /// The card the page is zooming into or out of: its own picture waits.
    var zooming: Tab.ID?
    /// Which part this is. The cards and the pins go under the page as it
    /// shrinks; the buttons along the top come down over it.
    var layer: Layer = .tabs
    /// The page's card where it rests, on screen: the camera every other
    /// card moves with.
    var anchor: CGRect?
    /// The whole screen, safe areas and all, as the page fills it.
    var screen: CGSize = .zero
    /// Where the page starts across (past a rail on the left).
    var pageX: CGFloat = 0

    enum Layer { case tabs, chrome }

    @State private var pull: CGFloat = 0
    /// The list shows its first line: a drag down anywhere moves the sheet.
    @State private var atTop = true
    /// The drag under way is the sheet's (true), someone else's (false), or
    /// not decided yet (nil).
    @State private var dragging: Bool?
    /// A line lifted to be put somewhere else.
    @State private var carried: Tab?
    @ObservedObject private var prefs = Prefs.shared
    /// How wide the cards have to share.
    @State private var gridWidth: CGFloat = 360
    /// How tall the cards really are, all of them, as laid out (names grow
    /// with the iPhone's text size, so no sum of guesses holds).
    @State private var gridContent: CGFloat = 0

    private var pinned: [Tab] { browser.tabs.filter { $0.pin != nil } }
    /// The tabs of the side shown: private, or the others.
    private var loose: [Tab] { browser.tabs.filter { $0.pin == nil && $0.isPrivate == browser.privateView } }

    private let row: CGFloat = 48


    /// Where the pins and the bar are: a drag down that starts there always
    /// takes the screen away.
    @State private var footFrame: CGRect = .zero

    private var shown: CGFloat { max(0, min(1, lift)) }
    /// The buttons along the top: the cards scroll on under them.
    private var rail: Rail { browser.rail }
    /// The buttons along the top; none with a rail, where they stand in it.
    private var topRoom: CGFloat { rail.on ? 12 : 56 - rise }
    /// A tall band for the clock with nothing on its left (the Duo's inner
    /// screen): the buttons go up into it, level with the clock, rather
    /// than leaving it empty over them.
    private var rise: CGFloat { !rail.on && browser.safe.top > 70 ? browser.safe.top - 26 : 0 }
    /// Room the tabs leave at each side: the rail's column on its side.
    private var padL: CGFloat { rail.on && rail.leading ? rail.width + 6 : 14 }
    private var padR: CGFloat { rail.on && !rail.leading ? rail.width + 6 : 14 }
    /// As many across as fit at a card's least width: two on an iPhone,
    /// more on a Duo's wide screen.
    private var cols: Int { max(2, Int((gridWidth + gap) / (170 + gap))) }
    private var pinsTall: CGFloat {
        let rows = CGFloat(Self.rows(of: pinned).count)
        return rows == 0 ? 0 : 10 + rows * 50 + (rows - 1) * 6
    }
    /// The pins and the room for the bar, which stays where it is on a page
    /// and becomes New tab here.
    private var footRoom: CGFloat { pinsTall + 10 + Metrics.pill + 8 }

    var body: some View {
        switch layer {
        case .tabs: tabsLayer
        case .chrome: chromeLayer
        }
    }

    private var tabsLayer: some View {
        let out = 1 - shown
        return ZStack(alignment: .bottom) {
            Group {
                if !prefs.tabCards { list } else if prefs.tabDeck { deck } else { cards }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if loose.isEmpty {
                    Text(browser.privateView ? "No private tabs" : "No tabs")
                        .font(.scaled(15))
                        .foregroundStyle(Palette.muted)
                        .allowsHitTesting(false)
                }
            }
            // Never quite 0: at 0 the grid wasn't laid out, and the page had
            // no card to go to until it was let go.
            // Fully away and still, nothing at all: the large cards, page
            // sized, showed through the page as a ghost even at 0.002.
            .opacity(away ? 0 : max(0.002, Double(min(1, shown * 2))))
            .simultaneousGesture(down)

            // The pins over a plain floor: the cards stop at a straight line,
            // no shadow, no fade.
            foot
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { footFrame = $0 }
                .offset(y: out * (footRoom + browser.safe.bottom + 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A screen of its own, not a sheet: the ground comes up quickly, so
        // the page shrinking into its card does so on it.
        .background(Palette.ground.opacity(Double(min(1, shown * 1.8))).ignoresSafeArea())
    }

    @ViewBuilder private var chromeLayer: some View {
        if rail.on {
            // In the rail, over Bookmarks, by the hand: they come in from
            // the column's edge.
            column
                .padding(rail.edge, rail.inset)
                .padding(.bottom, 8 + Metrics.pill + 10)
                .offset(x: (1 - shown) * (rail.width + 20) * rail.out)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: rail.alignment)
        } else {
            topChrome
        }
    }

    private var topChrome: some View {
        VStack(spacing: 0) {
            // Moved, never faded: glass faded drew a grey slab over the top.
            top
                .padding(.top, -rise)
                .offset(y: -(1 - shown) * (topRoom + browser.safe.top + 40))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A drag down that takes the screen away: from the top or the pins
    /// always; from the cards once they're scrolled to their start. A drag
    /// that sets off sideways is a card's, and a tap still picks.
    private var down: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if dragging == nil {
                    let down = value.translation.height > 0
                        && value.translation.height > abs(value.translation.width) * 1.2
                    // Only from a card, and only with the cards at their
                    // start: anywhere else a drag down is a scroll, even one
                    // with nowhere to go.
                    if down, atTop, let id = cardAt(value.startLocation) {
                        dragging = true
                        grab(id)
                    } else {
                        dragging = false
                    }
                }
                if dragging == true { drag(max(0, value.translation.height)) }
            }
            .onEnded { value in
                if dragging == true {
                    dropped(max(0, value.translation.height), value.velocity.height)
                }
                dragging = nil
            }
    }

    // MARK: - the parts

    private var top: some View {
        header
            .padding(.top, 6)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    /// The pins, down by the thumb, just over New tab.
    @ViewBuilder private var pins: some View {
        if !pinned.isEmpty {
            let slots = pinSlots(gridWidth)
            let tall = (slots.map(\.rect.maxY).max() ?? 50)
            ZStack(alignment: .topLeading) {
                ForEach(slots) { slot in
                    let tab = slot.tab
                    let carried = carry == tab.id
                    Letter(tab: tab, live: tab.id == browser.activeID, space: space) {
                        pick(tab)
                    } unpin: {
                        Feel.nudge()
                        withAnimation(Motion.settle) { browser.pin(tab) }
                    }
                    .frame(width: slot.rect.width, height: slot.rect.height)
                    .scaleEffect(carried ? 1.06 : 1)
                    .shadow(color: .black.opacity(carried ? 0.16 : 0), radius: 12, y: 4)
                    // Carried, it is where the finger is; the others where
                    // their place is, sliding there as places change.
                    .offset(carried
                            ? CGSize(width: finger.x - grabbed.x, height: finger.y - grabbed.y)
                            : CGSize(width: slot.rect.minX, height: slot.rect.minY))
                    .zIndex(carried ? 1 : 0)
                    .gesture(reorder(tab))
                    .dropDestination(for: String.self) { ids, _ in drop(ids, on: tab) }
                }
            }
            .frame(width: gridWidth, height: tall, alignment: .topLeading)
            .coordinateSpace(.named("pins"))
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: pinned.map(\.id))
            .padding(.leading, padL)
            .padding(.trailing, padR)
            .padding(.top, 10)
            .confirmationDialog(pinMenu?.label ?? "", isPresented: Binding(get: { pinMenu != nil }, set: { if !$0 { pinMenu = nil } })) {
                if let tab = pinMenu {
                    Button("Unpin") {
                        Feel.nudge()
                        withAnimation(Motion.settle) { browser.pin(tab) }
                    }
                    if let url = tab.pinHome ?? tab.address {
                        Button("Copy Link") { UIPasteboard.general.url = url }
                    }
                }
            }
        }
    }

    /// A pin and where it stands: rows of at most four, fuller rows first
    /// (the Mac's rule), and a lone short row still keeping three places.
    struct PinSlot: Identifiable {
        let tab: Tab
        let rect: CGRect
        var id: Tab.ID { tab.id }
    }

    private func pinSlots(_ width: CGFloat) -> [PinSlot] {
        var out: [PinSlot] = []
        for (row, line) in Self.rows(of: pinned).enumerated() {
            let places = CGFloat(pinned.count < 3 ? 3 : line.count)
            let w = (width - 6 * (places - 1)) / places
            for (index, tab) in line.enumerated() {
                out.append(PinSlot(tab: tab, rect: CGRect(x: CGFloat(index) * (w + 6), y: CGFloat(row) * 56, width: w, height: 50)))
            }
        }
        return out
    }

    /// Held, then moved: the pin lifts, whole, and follows the finger; the
    /// pin it passes over makes room, the others sliding along. Held and let
    /// go without moving: what can be done with it.
    private func reorder(_ tab: Tab) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("pins")))
            .onChanged { value in
                guard case .second(true, let drag?) = value else {
                    if case .second(true, nil) = value, carry != tab.id { lift(tab, at: nil) }
                    return
                }
                if carry != tab.id { lift(tab, at: drag.startLocation) }
                finger = drag.location
                if hypot(drag.translation.width, drag.translation.height) > 6 { carriedFar = true }
                // Over another pin: it takes this one's place.
                let slots = pinSlots(gridWidth)
                if let over = slots.first(where: { $0.tab.id != tab.id && $0.rect.contains(drag.location) }) {
                    Feel.tick()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { browser.move(tab, before: over.tab) }
                }
            }
            .onEnded { _ in
                if carry == tab.id, !carriedFar { pinMenu = tab }
                // Back into its place from wherever the finger let it go.
                if let slot = pinSlots(gridWidth).first(where: { $0.tab.id == tab.id }) {
                    finger = CGPoint(x: slot.rect.minX + grabbed.x, y: slot.rect.minY + grabbed.y)
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { carry = nil }
            }
    }

    private func lift(_ tab: Tab, at start: CGPoint?) {
        guard let slot = pinSlots(gridWidth).first(where: { $0.tab.id == tab.id }) else { return }
        Feel.nudge()
        let at = start ?? CGPoint(x: slot.rect.midX, y: slot.rect.midY)
        grabbed = CGPoint(x: at.x - slot.rect.minX, y: at.y - slot.rect.minY)
        finger = at
        carriedFar = false
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { carry = tab.id }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(loose) { tab in
                    Swipe {
                        Feel.tick()
                        withAnimation(Motion.settle) { browser.close(tab) }
                    } pin: {
                        Feel.nudge()
                        withAnimation(Motion.settle) { browser.pin(tab) }
                    } content: {
                        Line(tab: tab, live: tab.id == browser.activeID, hidden: browser.locked && tab.isPrivate, space: space)
                            .contentShape(Rectangle())
                            .onTapGesture { pick(tab) }
                    }
                    // Held: what can be done with it. Held and moved: it
                    // goes where it's let go.
                    .contextMenu { menu(for: tab) }
                    .draggable(tab.id.uuidString) {
                        Line(tab: tab, live: false, space: space).frame(width: 300)
                    }
                    .dropDestination(for: String.self) { ids, _ in drop(ids, on: tab) }
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .leading)))
                }

            }
            .padding(.leading, padL)
            .padding(.trailing, padR)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .contentMargins(.top, topRoom + 4, for: .scrollContent)
        .contentMargins(.bottom, footRoom + 8, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            pull = max(0, -offset)
            atTop = offset <= 1
        }
    }

    // MARK: - cards

    private let gap: CGFloat = 12
    private var cardWidth: CGFloat { max(80, (gridWidth - gap * CGFloat(cols - 1)) / CGFloat(cols)) }
    /// A little taller than wide: the top of the page, where it says what it is.
    private var pictureHeight: CGFloat {
        // The screen's own shape, as far as a card can take it: a screen
        // held sideways makes a wider card, so the page's top fits it.
        let shape = screen.width > 1 ? max(0.75, min(1.3, screen.height / screen.width)) : 1.3
        return (cardWidth * shape).rounded()
    }
    private var cardHeight: CGFloat { pictureHeight + 26 }
    private var cardsHeight: CGFloat {
        let rows = CGFloat((loose.count + cols - 1) / cols)
        return rows * cardHeight + max(0, rows - 1) * gap + 8
    }

    private var cards: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: cols), spacing: gap) {
                    let order = loose
                    let at = order.firstIndex { $0.id == browser.activeID }
                    ForEach(Array(order.enumerated()), id: \.element.id) { index, tab in
                        Card(tab: tab, live: tab.id == browser.activeID, hidden: browser.locked && tab.isPrivate, pictureHeight: pictureHeight, waiting: zooming == tab.id) {
                            pick(tab)
                        } report: { frames(tab.id, $0) } close: {
                            Feel.tick()
                            withAnimation(Motion.bouncy) { browser.close(tab) }
                        }
                        .contentShape(.contextMenuPreview, PictureShape(top: 0, height: pictureHeight, radius: 18))
                        .contextMenu { menu(for: tab) }
                        // Every other card moves with the page, as if the
                        // page were one card seen up close: the rest were
                        // there all along, out of the frame, and come into it
                        // as the camera steps back, the farther a moment later.
                        .modifier(Camera(
                            progress: shown,
                            place: place(index, from: at),
                            anchor: tab.id == browser.activeID ? nil : anchor,
                            screen: screen,
                            x0: pageX
                        ))
                        .draggable(tab.id.uuidString) {
                            Line(tab: tab, live: false, space: space).frame(width: 300)
                        }
                        .dropDestination(for: String.self) { ids, _ in drop(ids, on: tab) }
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                        .id(tab.id)
                    }
                }
                .padding(.leading, padL)
                .padding(.trailing, padR)
            }
            // Always free to scroll: whatever doesn't fit is a drag away.
            .scrollBounceBehavior(.basedOnSize)
            // Under the buttons along the top, and down to the pins' floor.
            .contentMargins(.top, topRoom + 4, for: .scrollContent)
            .contentMargins(.bottom, footRoom + 8, for: .scrollContent)
            // Cards moving with the page run past the grid's edges.
            .scrollClipDisabled()
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, tall in
                if abs(tall - gridContent) > 0.5 { gridContent = tall }
            }
            .onScrollGeometryChange(for: Room.self) { geo in
                Room(content: geo.contentSize.height, container: geo.containerSize.height,
                     top: geo.contentInsets.top, bottom: geo.contentInsets.bottom)
            } action: { _, room in self.room = room }
            .scrollPosition($position)
            .scrollIndicators(.hidden)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 - padL - padR }
            .onChange(of: rail) { _, _ in gridWidth = max(80, gridWidth) }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                pull = max(0, -offset)
                atTop = offset <= 1
            }
            // The page you're on in sight, not left three rows down: put
            // there while the screen is away, never while it shows or
            // moves, so the page always zooms to a card that stays put.
            .onChange(of: away, initial: true) { _, away in
                if away { aim() }
            }
            .onChange(of: browser.activeID) { _, _ in
                if away { aim() }
            }
            // The other side: from its start.
            .onChange(of: browser.privateView) { _, _ in
                if !away { position.scrollTo(edge: .top) }
            }
            // The room changed (a tab came or went, the cards were measured
            // for the first time): aimed again while unseen.
            .onChange(of: room) { _, _ in
                if away { aim() }
            }
        }
    }

    // MARK: - large cards

    /// Which card is in the middle, counted along the tabs: whole at rest,
    /// in between while the finger walks them.
    @State private var deckAt: CGFloat = 0
    /// Where the walk set off from; nil when no finger is walking.
    @State private var deckFrom: CGFloat?
    /// The walk under way is sideways (true), not (false), or undecided.
    @State private var deckSideways: Bool?

    /// The page's own shape: a large card is the whole page, made small.
    private var deckShape: CGFloat {
        // Held sideways (a Duo open), the page is wider than tall: so is
        // its card.
        screen.width > 1 ? max(0.5, min(2.4, screen.height / screen.width)) : 2.1
    }
    /// Room over a card for its name.
    private let deckName: CGFloat = 30

    private func deckWidth(_ size: CGSize) -> CGFloat {
        let across = (size.width - padL - padR) * 0.62
        let tall = size.height - topRoom - footRoom - deckName - 48
        return max(80, min(across, tall / deckShape)).rounded()
    }

    /// Across from the middle, in card widths, for a card `d` places along:
    /// the ones after it side by side on its right, over it; the ones before
    /// it tucked in under its left edge, a sliver each. The iPhone's own
    /// app switcher's rule.
    private func deckX(_ d: CGFloat) -> CGFloat {
        if d >= 0 { return d * 1.05 }
        // The one just before shows a sliver; the ones before it, less.
        return d > -1 ? d * 0.15 : -0.15 + (d + 1) * 0.05
    }

    private var deck: some View {
        GeometryReader { geo in
            let order = loose
            let width = deckWidth(geo.size)
            let height = (width * deckShape).rounded()
            let left = padL + (geo.size.width - padL - padR - width) / 2
            let free = geo.size.height - topRoom - footRoom - deckName - height
            let top = topRoom + deckName + max(0, free / 2)
            let at = order.firstIndex { $0.id == browser.activeID }
            let atX = at.map { deckX(CGFloat($0) - deckAt) * width } ?? 0
            ZStack(alignment: .topLeading) {
                ForEach(Array(order.enumerated()), id: \.element.id) { index, tab in
                    let d = CGFloat(index) - deckAt
                    if d > -5, d < 3 {
                        let x = deckX(d) * width
                        DeckCard(
                            tab: tab,
                            width: width, height: height,
                            hidden: browser.locked && tab.isPrivate,
                            waiting: zooming == tab.id,
                            // The name over a card tucked away fades with it.
                            nameShown: d < 0 ? max(0, 1 + Double(d) * 1.6) : 1,
                            gone: { frames(tab.id, .zero) },
                            open: { pick(tab) },
                            report: { frames(tab.id, $0) },
                            close: {
                                Feel.tick()
                                withAnimation(Motion.bouncy) { browser.close(tab) }
                            }
                        )
                        // Held: the menu takes the card itself, before it's
                        // moved into place: taken after, its picture was
                        // cut off at the card's first place (28 Nov). The
                        // picture alone lifts, round, not the name above it
                        // in a square of ground with its shadow cut off.
                        .contentShape(.contextMenuPreview, PictureShape(top: deckName, height: height, radius: 22))
                        .contextMenu { menu(for: tab) }
                        .offset(x: left + x, y: top - deckName)
                        // As the page shrinks into its card, the others come
                        // in with the camera stepping back, as in the grid.
                        .modifier(Camera(
                            progress: shown,
                            place: .init(delta: CGSize(width: x - atX, height: 0), steps: abs(d.rounded())),
                            anchor: tab.id == browser.activeID ? nil : anchor,
                            screen: screen,
                            x0: pageX
                        ))
                        .zIndex(Double(index))
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .simultaneousGesture(walk(width: width, count: order.count))
        }
        // Always the page's card in the middle when the screen comes up:
        // put there while unseen, so the page lands on a card that stays.
        .onAppear(perform: centreDeck)
        .onChange(of: away, initial: true) { _, away in if away { centreDeck() } }
        .onChange(of: browser.activeID) { _, _ in if away { centreDeck() } }
        .onChange(of: browser.privateView) { _, _ in centreDeck() }
        .onChange(of: loose.count) { _, count in
            // One closed at the end: the one before it comes to the middle.
            if deckAt > CGFloat(max(0, count - 1)) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) { deckAt = CGFloat(max(0, count - 1)) }
            }
        }
    }

    private func centreDeck() {
        let order = loose
        deckAt = CGFloat(order.firstIndex { $0.id == browser.activeID } ?? max(0, order.count - 1))
    }

    /// Sideways, the cards follow the finger one for one; let go, the
    /// nearest settles in the middle, a quick flick going on one more.
    private func walk(width: CGFloat, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                if deckSideways == nil {
                    deckSideways = abs(value.translation.width) > abs(value.translation.height) * 1.2
                    if deckSideways == true { deckFrom = deckAt }
                }
                guard deckSideways == true, let from = deckFrom else { return }
                var next = from - value.translation.width / width
                let last = CGFloat(max(0, count - 1))
                // Past either end it gives a little, no more.
                if next < 0 { next *= 0.3 } else if next > last { next = last + (next - last) * 0.3 }
                if next.rounded() != deckAt.rounded() { Feel.tick() }
                deckAt = next
            }
            .onEnded { value in
                defer { deckSideways = nil; deckFrom = nil }
                guard deckSideways == true else { return }
                let thrown = deckAt - value.velocity.width / width * 0.25
                let last = CGFloat(max(0, count - 1))
                let target = max(0, min(last, thrown.rounded()))
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) { deckAt = target }
            }
    }

    /// What the grid has and what it shows, to know where it may be scrolled.
    struct Room: Equatable {
        var content: CGFloat = 0
        var container: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0
    }
    @State private var room = Room()
    @State private var position = ScrollPosition(edge: .top)
    @Namespace private var sideSpace
    /// The pin held and moved, where the finger is, and where on the pin
    /// it took hold.
    @State private var carry: Tab.ID?
    @State private var finger: CGPoint = .zero
    @State private var grabbed: CGPoint = .zero
    @State private var carriedFar = false
    @State private var pinMenu: Tab?

    /// The page's card in the middle of what shows, never past either end:
    /// cards that all fit stay at the top, under the buttons, whichever is
    /// the page's. Worked out, not left to scrollTo, which with a few cards
    /// put them half way down an empty screen.
    private func aim() {
        guard room.container > 0 else { return }
        let seen = room.container - room.top - room.bottom
        let most = max(0, room.content - seen)
        guard most > 0.5, let at = loose.firstIndex(where: { $0.id == browser.activeID }) else {
            position.scrollTo(edge: .top)
            return
        }
        let rowTop = CGFloat(at / cols) * (cardHeight + gap)
        let y = max(0, min(most, rowTop + cardHeight / 2 - seen / 2))
        position.scrollTo(y: y)
    }

    /// Where a card is from the page's own, in rows and columns, and in
    /// points at rest.
    private func place(_ index: Int, from at: Int?) -> Camera.Place {
        guard let at else { return .init() }
        let across = CGFloat(index % cols - at % cols), rows = CGFloat(index / cols - at / cols)
        return .init(
            delta: CGSize(width: across * (cardWidth + gap), height: rows * (cardHeight + gap)),
            steps: abs(across) + abs(rows)
        )
    }

    /// Held: what can be done with a tab, the same for a line or a card.
    @ViewBuilder private func menu(for tab: Tab) -> some View {
        Button {
            withAnimation(Motion.settle) { browser.pin(tab) }
        } label: { Label("Pin", systemImage: "pin") }
        if let url = tab.address, !tab.isPrivate {
            Button { Bookmarks.shared.add(url, title: tab.title) } label: {
                Label("Add to Bookmarks", systemImage: "book")
            }
            Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
            Button { browser.share(tab) } label: { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Button(role: .destructive) {
            withAnimation(Motion.settle) { browser.close(tab) }
        } label: { Label("Close Tab", systemImage: "xmark") }
    }

    /// The pins, by the thumb, over the room the bar keeps: on a page it
    /// says where you are, here it is New tab.
    private var foot: some View {
        VStack(spacing: 0) {
            pins
            Color.clear.frame(height: 10 + Metrics.pill + 8)
        }
        .frame(maxWidth: .infinity)
        .background(Palette.ground.ignoresSafeArea(edges: .bottom))
        .contentShape(Rectangle())
    }

    /// The screen's head: what can be done with all the tabs, as glass
    /// buttons on the left, by the thumb's reach from the side. No Done:
    /// a card, a drag down or the page itself takes the screen away.
    private var header: some View {
        HStack(spacing: 8) {
            closeAllButton
            sides
            moreMenu
            Spacer(minLength: 0)
        }
    }

    private var closeAllButton: some View {
        Button {
            Feel.nudge()
            browser.askingCloseAll = true
        } label: { headerButton("xmark") }
        .buttonStyle(.plain)
        .disabled(loose.isEmpty)
        .accessibilityLabel("Close All")
    }

    private var moreMenu: some View {
        Menu {
            Picker(selection: Binding(
                get: { !prefs.tabCards ? 2 : prefs.tabDeck ? 1 : 0 },
                set: { look in
                    withAnimation(Motion.settle) {
                        prefs.tabCards = look != 2
                        prefs.tabDeck = look == 1
                    }
                }
            )) {
                Label("Cards", systemImage: "square.grid.2x2").tag(0)
                Label("Large Cards", systemImage: "rectangle.stack").tag(1)
                Label("List", systemImage: "list.bullet").tag(2)
            } label: { Text("Show Tabs As") }
                .pickerStyle(.inline)
            if prefs.sync {
                Button { browser.showingOthers = true } label: {
                    Label("Other devices", systemImage: "laptopcomputer.and.iphone")
                }
            }
            Menu {
                if browser.closed.isEmpty {
                    Text("Nothing closed lately")
                } else {
                    ForEach(Array(browser.closed.prefix(12).enumerated()), id: \.offset) { _, entry in
                        Button {
                            browser.reopen(entry)
                        } label: {
                            let site = URL(string: entry.url).map { Address.host($0) } ?? entry.url
                            Text(entry.title.isEmpty ? site : entry.title)
                            Text(site)
                        }
                    }
                }
            } label: { Label("Recently Closed", systemImage: "clock.arrow.circlepath") }
            // Where people look for it on a wide screen once it's hidden.
            if browser.roomy {
                Button {
                    withAnimation(Motion.settle) { prefs.sidebar.toggle() }
                } label: {
                    Label(prefs.sidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left")
                }
            }
            Divider()
            Button { browser.settings = true } label: { Label("Settings", systemImage: "gearshape") }
        } label: {
            headerButton("ellipsis")
        }
        .accessibilityLabel("More")
    }

    /// The tabs, or the private ones: two sides of one glass switch,
    /// across along the top, or up and down in a rail.
    private var sides: some View {
        let layout = rail.on ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            side("square.on.square", "Tabs", on: !browser.privateView) { browser.privateView = false }
            side("eyeglasses", "Private", on: browser.privateView) { browser.privateView = true }
        }
        .padding(3)
        .glass(Capsule(), interactive: true, else: Palette.wash)
    }

    /// The same buttons as along the top, one over the other in a rail.
    private var column: some View {
        VStack(spacing: 10) {
            closeAllButton
            sides
            moreMenu
        }
    }

    private func side(_ symbol: String, _ name: LocalizedStringKey, on: Bool, pick: @escaping () -> Void) -> some View {
        Button {
            guard !on else { return }
            Feel.tick()
            withAnimation(Motion.settle) { pick() }
        } label: {
            Image(systemName: symbol)
                .font(.scaled(15, weight: .semibold))
                .foregroundStyle(on ? Palette.ink : Palette.muted)
                .frame(width: rail.on ? 42 : 44, height: rail.on ? 40 : 34)
                .background {
                    if on {
                        Capsule().fill(Palette.ink.opacity(0.1))
                            .matchedGeometryEffect(id: "side", in: sideSpace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func headerButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.scaled(15, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(width: rail.on ? Metrics.pill : 40, height: rail.on ? Metrics.pill : 40)
            .glass(Circle(), interactive: true, else: Palette.wash)
            .contentShape(Circle())
    }

    private func round(_ symbol: String, _ name: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.scaled(16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 46, height: 46)
                .glass(Circle(), interactive: true, else: Palette.wash)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }

    // MARK: - moving

    private func pan(_ recognizer: UIPanGestureRecognizer) {
        let moved = recognizer.translation(in: nil).y
        switch recognizer.state {
        case .changed:
            drag(moved)
        case .ended, .cancelled, .failed:
            dropped(moved, recognizer.velocity(in: nil).y)
        default:
            break
        }
    }

    /// A tab let go over another: it takes that one's place.
    private func drop(_ ids: [String], on target: Tab) -> Bool {
        guard let id = ids.first.flatMap(UUID.init(uuidString:)),
              let tab = browser.tabs.first(where: { $0.id == id }), tab.id != target.id
        else { return false }
        Feel.tick()
        withAnimation(Motion.settle) { browser.move(tab, before: target) }
        return true
    }

    private func pick(_ tab: Tab) {
        Feel.tick()
        withAnimation(Motion.glide) { browser.select(tab) }
    }

    /// At most four to a row, balanced, fuller rows first.
    static func rows(of tabs: [Tab]) -> [[Tab]] {
        guard !tabs.isEmpty else { return [] }
        let count = (tabs.count + 3) / 4
        let base = tabs.count / count
        let extra = tabs.count % count
        var rows: [[Tab]] = []
        var start = 0
        for index in 0..<count {
            let size = base + (index < extra ? 1 : 0)
            rows.append(Array(tabs[start..<start + size]))
            start += size
        }
        return rows
    }

    /// A line that can be swiped: left to close, right to pin, a word under
    /// it saying which, and back in place if let go short. Only a drag that
    /// sets off sideways is its; one going down is the sheet's.
    struct Swipe<Content: View>: View {
        let close: () -> Void
        let pin: () -> Void
        @ViewBuilder let content: () -> Content

        @State private var shift: CGFloat = 0
        @State private var sideways: Bool?
        private let reach: CGFloat = 96

        var body: some View {
            content()
                .offset(x: shift)
                .background {
                    HStack {
                        if shift > 0 {
                            Label("Pin", systemImage: "pin").padding(.leading, 18)
                            Spacer()
                        } else if shift < 0 {
                            Spacer()
                            Label("Close", systemImage: "xmark").padding(.trailing, 18)
                        }
                    }
                    .font(.scaled(13, weight: .medium))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(abs(shift) > reach ? Palette.ink : Palette.muted)
                    .opacity(Double(min(1, abs(shift) / 40)))
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            if sideways == nil {
                                sideways = abs(value.translation.width) > abs(value.translation.height) * 1.2
                            }
                            guard sideways == true else { return }
                            let was = abs(shift) > reach
                            shift = value.translation.width
                            if was != (abs(shift) > reach) { Feel.tick() }
                        }
                        .onEnded { value in
                            defer { sideways = nil }
                            guard sideways == true else { return }
                            let landing = value.translation.width + value.velocity.width * 0.1
                            if landing < -reach {
                                close()
                            } else if landing > reach {
                                pin()
                            }
                            withAnimation(Motion.settle) { shift = 0 }
                        }
                )
        }
    }

    /// Where a carried line goes: before the line it's over.
    private struct Reorder: DropDelegate {
        let target: Tab
        @Binding var carried: Tab?
        let browser: Browser

        func dropEntered(info: DropInfo) {
            guard let carried, carried.id != target.id else { return }
            withAnimation(Motion.settle) { browser.move(carried, before: target) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        func performDrop(info: DropInfo) -> Bool {
            carried = nil
            return true
        }
    }

    /// A pinned tab: one letter, and its place at the head.
    struct Letter: View {
        @ObservedObject var tab: Tab
        let live: Bool
        let space: Namespace.ID
        let open: () -> Void
        let unpin: () -> Void
        /// In the sidebar, on its lighter ground: squares of the page's white.
        var side = false

        var body: some View {
            Group {
                if let icon = tab.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .opacity(live ? 1 : 0.8)
                } else {
                    Text(tab.pin ?? "")
                        .font(.scaled(16, weight: .medium))
                        .foregroundStyle(live ? Palette.ink : Palette.muted)
                }
            }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(side ? Palette.ground.opacity(live ? 1 : 0.55) : live ? Palette.pinLive : Palette.wash.opacity(0.55))
                }
                .overlay(alignment: .bottom) {
                    if tab.loading { Ring(size: 9).padding(.bottom, 5) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .onTapGesture(perform: open)
        }
    }

    /// A card: the page as it last looked, its name under it, a cross to
    /// close it. Tapped, it opens; swiped left, it follows the
    /// finger and, let go far enough, flies off the way it was thrown.
    private struct Card: View {
        @ObservedObject var tab: Tab
        let live: Bool
        /// A private tab while private tabs are locked: no picture, no name.
        var hidden = false
        let pictureHeight: CGFloat
        /// The page is on its way into this card (or out of it): the card
        /// keeps its place, empty, until it lands.
        var waiting = false
        let open: () -> Void
        let report: (CGRect) -> Void
        let close: () -> Void

        @State private var shift: CGFloat = 0
        @State private var sideways: Bool?
        @State private var gone = false
        private let reach: CGFloat = 90

        var body: some View {
            VStack(spacing: 7) {
                    picture
                        .frame(maxWidth: .infinity)
                        .frame(height: pictureHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .opacity(waiting ? 0 : 1)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Palette.faint.opacity(0.35), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(live ? 0.16 : 0.07), radius: live ? 12 : 7, y: live ? 4 : 2)
                    // Waiting too: the page brings its name down with it.
                    CardName(tab: tab, live: live, hidden: hidden)
                        .opacity(waiting ? 0 : 1)
            }
            .contentShape(Rectangle())
            // A tap, and only a tap: a finger that moves (to scroll, to
            // swipe a card away) never opens what it was resting on.
            .onTapGesture(perform: open)
            .overlay(alignment: .topTrailing) {
                Button {
                    flyOff(to: 0)
                } label: {
                    Image(systemName: "xmark")
                        .font(.scaled(9.5, weight: .bold))
                        .foregroundStyle(Palette.ink.opacity(0.75))
                        .frame(width: 22, height: 22)
                        .background(.ultraThinMaterial, in: Circle())
                        // Bigger to the finger than to the eye.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Tab")
            }
            .offset(x: shift)
            .scaleEffect(gone ? 0.85 : 1)
            .opacity(gone ? 0 : 1)
            .simultaneousGesture(
                DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        if sideways == nil {
                            sideways = value.translation.width < 0
                                && abs(value.translation.width) > abs(value.translation.height) * 1.3
                        }
                        guard sideways == true else { return }
                        let was = -shift > reach
                        // Free going left; a little give the other way.
                        let x = value.translation.width
                        shift = x < 0 ? x : x * 0.15
                        if was != (-shift > reach) { Feel.tick() }
                    }
                    .onEnded { value in
                        defer { sideways = nil }
                        guard sideways == true else { return }
                        let landing = value.translation.width + value.velocity.width * 0.15
                        if landing < -reach {
                            flyOff(to: -420, speed: value.velocity.width)
                        } else {
                            withAnimation(Motion.bouncy) { shift = 0 }
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(live ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: "Close Tab") { close() }
        }

        /// Off the way it was going, then gone from the grid, the others
        /// closing up behind it.
        private func flyOff(to x: CGFloat, speed: CGFloat = 0) {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                if x != 0 { shift = x } else { gone = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { close() }
        }

        @ViewBuilder private var picture: some View {
            if hidden {
                Palette.wash.overlay {
                    Image(systemName: "lock.fill")
                        .font(.scaled(20))
                        .foregroundStyle(Palette.muted)
                }
            } else if let image = tab.snapshot, !tab.isBlank {
                // The top of the page, across its whole width, exactly as
                // the page zooming into it draws it: filled instead, a page
                // wider than the card was scaled up and the card changed
                // under it when the zoom handed over (a jump, on the Duo).
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: geo.size.width,
                               height: geo.size.width * image.size.height / max(1, image.size.width))
                }
                .background(Palette.ground)
                .clipped()
            } else if tab.isBlank {
                Palette.wash.overlay {
                    Image(systemName: "plus")
                        .font(.scaled(22, weight: .light))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Palette.wash.overlay {
                    Mark(icon: tab.icon, letter: tab.letter, size: 34)
                }
            }
        }

    }

    /// A large card: the whole page made small, its name over it. Tapped,
    /// it opens; thrown up, it closes.
    private struct DeckCard: View {
        @ObservedObject var tab: Tab
        let width: CGFloat
        let height: CGFloat
        var hidden = false
        var waiting = false
        var nameShown: Double = 1
        /// Out of the deck's reach: its place forgotten, so a finger there
        /// never finds it.
        var gone: () -> Void = {}
        let open: () -> Void
        let report: (CGRect) -> Void
        let close: () -> Void

        @State private var lift: CGFloat = 0
        @State private var upward: Bool?

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                CardName(tab: tab, live: true, hidden: hidden)
                    .frame(width: width, height: 30, alignment: .leading)
                    .opacity(waiting ? 0 : nameShown)
                picture
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Palette.faint.opacity(0.3), lineWidth: 0.5)
                    }
                    .opacity(waiting ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { report($0) }
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onDisappear(perform: gone)
            .offset(y: lift)
            .opacity(Double(1 + min(0, lift) / (height * 1.4)))
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        if upward == nil {
                            upward = value.translation.height < 0
                                && abs(value.translation.height) > abs(value.translation.width) * 1.2
                        }
                        guard upward == true else { return }
                        let y = value.translation.height
                        let was = lift < -height * 0.25
                        lift = y < 0 ? y : y * 0.1
                        if was != (lift < -height * 0.25) { Feel.tick() }
                    }
                    .onEnded { value in
                        defer { upward = nil }
                        guard upward == true else { return }
                        let landing = value.translation.height + value.velocity.height * 0.2
                        if landing < -height * 0.25 {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.95)) { lift = -height * 1.4 }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { close() }
                        } else {
                            withAnimation(Motion.bouncy) { lift = 0 }
                        }
                    }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Close Tab") { close() }
        }

        @ViewBuilder private var picture: some View {
            if hidden {
                Palette.wash.overlay {
                    Image(systemName: "lock.fill").font(.scaled(24)).foregroundStyle(Palette.muted)
                }
            } else if let image = tab.snapshot, !tab.isBlank {
                // Drawn as the page zooming into it draws it: across its
                // whole width, from the top.
                Image(uiImage: image)
                    .resizable()
                    .frame(width: width, height: width * image.size.height / max(1, image.size.width))
                    .frame(width: width, height: height, alignment: .top)
                    .background(Palette.ground)
                    .clipped()
            } else if tab.isBlank {
                Palette.wash.overlay {
                    Image(systemName: "plus").font(.scaled(26, weight: .light)).foregroundStyle(Palette.muted)
                }
            } else {
                Palette.wash.overlay { Mark(icon: tab.icon, letter: tab.letter, size: 40) }
            }
        }
    }

    /// One line: what it is, then where it came from.
    struct Line: View {
        @ObservedObject var tab: Tab
        let live: Bool
        /// A private tab while private tabs are locked: no title, no site.
        var hidden = false
        let space: Namespace.ID
        /// In the sidebar: the name alone, and the open tab lit in the page's
        /// own white, as on the Mac.
        var side = false

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if tab.loading {
                        Ring(size: 12)
                    } else if !tab.isBlank, !hidden {
                        // A new tab isn't a site: no icon, no letter.
                        Mark(icon: tab.icon, letter: tab.letter, size: 18)
                    }
                }
                .frame(width: 18, height: 18)

                Text(hidden ? String(localized: "Private tab") : tab.label)
                    .font(.scaled(15))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
                    .lineLimit(1)

                if tab.isPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.scaled(11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }

                Spacer(minLength: 8)

                // The domain keeps its room: it is the shorter of the two and
                // the one that tells you which of three tabs on the same site
                // you are looking at.
                if let url = tab.address, !hidden, !side {
                    Text(Address.host(url))
                        .font(.scaled(12.5))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: side ? 42 : 48)
            .background {
                if live {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(side ? Palette.ground : Palette.wash)
                        .matchedGeometryEffect(id: "live", in: space)
                }
            }
        }
    }
}

/// A card's name, under its picture: the site's mark and what the page is
/// called. The same under a card and under the page on its way into one.
struct CardName: View {
    @ObservedObject var tab: Tab
    let live: Bool
    var hidden = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if tab.loading {
                    Ring(size: 10)
                } else if !tab.isBlank, !hidden {
                    Mark(icon: tab.icon, letter: tab.letter, size: 14)
                }
            }
            if tab.isPrivate {
                Image(systemName: "eyeglasses")
                    .font(.scaled(10, weight: .medium))
                    .foregroundStyle(Palette.muted)
            }
            Text(hidden ? String(localized: "Private tab") : tab.label)
                .font(.scaled(12.5, weight: live ? .semibold : .regular))
                .foregroundStyle(live ? Palette.ink : Palette.muted)
                .lineLimit(1)
        }
        .frame(height: 19)
        .padding(.horizontal, 4)
    }
}

/// A card seen through the camera that follows the page: at 0 the page's
/// card fills the screen and this one sits where it would be at that size,
/// at 1 everything is where it rests. Cards farther from the page set off a
/// moment later, so they settle one after another, not as one sheet.
struct Camera: GeometryEffect {
    struct Place {
        var delta: CGSize = .zero
        var steps: CGFloat = 0
    }

    var progress: CGFloat
    let place: Place
    /// The page's card at rest, on screen; nil for no camera at all.
    let anchor: CGRect?
    let screen: CGSize
    var x0: CGFloat = 0

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard let a = anchor, a.width > 1, screen.width > 1 else { return ProjectionTransform() }
        let lag = min(0.24, 0.07 * place.steps)
        let q = max(0, min(1, (progress - lag) / (1 - lag)))
        guard q < 1 else { return ProjectionTransform() }
        let start = screen.width / a.width
        let k = start + (1 - start) * q
        // The page's card, now: from the screen's corner to where it rests.
        let ox = x0 + (a.minX - x0) * q, oy = a.minY * q
        // On its way the page is taller than its card (the whole screen's
        // height, cut down as it lands): the rows under it make that room.
        let taller = a.width * screen.height / screen.width - a.height
        let below = place.delta.height > 0.5 ? k * taller * (1 - q) : 0
        let dx = ox + place.delta.width * k - (a.minX + place.delta.width)
        let dy = oy + place.delta.height * k + below - (a.minY + place.delta.height)
        return ProjectionTransform(
            CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: dx, y: dy))
        )
    }
}


/// A card's picture within the card: what lifts when a card is held, round
/// as the picture is, without the name beside it.
struct PictureShape: Shape {
    var top: CGFloat
    var height: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let picture = CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: min(height, rect.height - top))
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: picture)
    }
}
