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
    private var loose: [Tab] { browser.tabs.filter { $0.pin == nil } }

    private let row: CGFloat = 48


    /// How tall the top and the foot are, to come in from just out of sight.
    @State private var topTall: CGFloat = 120
    @State private var footTall: CGFloat = 70
    /// Where the tabs themselves are: a drag down that starts off them, on
    /// the top or the foot, always takes the screen away.
    @State private var tabsFrame: CGRect = .zero

    var body: some View {
        let shown = max(0, min(1, lift))
        let out = 1 - shown
        VStack(spacing: 0) {
            top
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topTall = $0 }
                // Moved, never faded: glass faded drew a grey slab over
                // the whole top while it came.
                .offset(y: -out * (topTall + browser.safe.top + 12))
            Group {
                if prefs.tabCards { cards } else { list }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // Cards scrolled under the pins or down to the foot fade there,
            // rather than being cut.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                }
                .padding(.horizontal, -40)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tabsFrame = $0 }
            // Never quite 0: at 0 the grid wasn't laid out, and the page had no
            // card to go to until it was let go.
            .opacity(max(0.002, Double(shown)))
            foot
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footTall = $0 }
                .offset(y: out * (footTall + browser.safe.bottom + 12))
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A screen of its own, not a sheet: the ground comes up quickly, so
        // the page shrinking into its card does so on it.
        .background(Palette.ground.opacity(Double(min(1, shown * 1.8))).ignoresSafeArea())
        // Down from anywhere on it: the rows, the empty room, the foot. A
        // drag that sets off sideways is a row's to close or pin, and a tap
        // still picks; only one going down moves the sheet.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    if dragging == nil {
                        let down = value.translation.height > 0
                            && value.translation.height > abs(value.translation.width) * 1.2
                        dragging = down && (atTop || !tabsFrame.contains(value.startLocation))
                    }
                    if dragging == true { drag(max(0, value.translation.height)) }
                }
                .onEnded { value in
                    if dragging == true {
                        dropped(max(0, value.translation.height), value.velocity.height)
                    }
                    dragging = nil
                }
        )
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
                VStack(spacing: 6) {
                    ForEach(Array(Self.rows(of: pinned).enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 6) {
                            ForEach(line) { tab in
                                Letter(tab: tab, live: tab.id == browser.activeID, space: space) {
                                    pick(tab)
                                } unpin: {
                                    Feel.nudge()
                                    withAnimation(Motion.settle) { browser.pin(tab) }
                                }
                                // Held and moved: the pin goes where it's let go.
                                .draggable(tab.id.uuidString) { Mark(icon: tab.icon, letter: tab.pin ?? "", size: 28) }
                                .dropDestination(for: String.self) { ids, _ in drop(ids, on: tab) }
                            }
                            // One short row still keeps three places, as on
                            // the Mac: a lone pin is a square, not a bar.
                            if pinned.count < 3 {
                                ForEach(0..<(3 - pinned.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity).frame(height: 50)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
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
            .padding(.horizontal, 14)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            pull = max(0, -offset)
            atTop = offset <= 1
        }
        .onScrollPhaseChange { old, new in
            // A long list pulled down past its start: let go and it goes.
            if old == .interacting, new != .interacting, pull > 70 {
                dropped(pull, 1200)
            }
        }
    }

    // MARK: - cards

    private let gap: CGFloat = 12
    private var cardWidth: CGFloat { max(80, (gridWidth - gap) / 2) }
    /// A little taller than wide: the top of the page, where it says what it is.
    private var pictureHeight: CGFloat { (cardWidth * 1.3).rounded() }
    private var cardHeight: CGFloat { pictureHeight + 26 }
    private var cardsHeight: CGFloat {
        let rows = CGFloat((loose.count + 1) / 2)
        return rows * cardHeight + max(0, rows - 1) * gap + 8
    }

    private var cards: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: gap), GridItem(.flexible(), spacing: gap)], spacing: gap) {
                    ForEach(loose) { tab in
                        Card(tab: tab, live: tab.id == browser.activeID, hidden: browser.locked && tab.isPrivate, pictureHeight: pictureHeight, waiting: zooming == tab.id) {
                            pick(tab)
                        } report: { frames(tab.id, $0) } close: {
                            Feel.tick()
                            withAnimation(Motion.bouncy) { browser.close(tab) }
                        }
                        .contextMenu { menu(for: tab) }
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
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 4)
            }
            // Always free to scroll: whatever doesn't fit is a drag away.
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, tall in
                if abs(tall - gridContent) > 0.5 { gridContent = tall }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 28 } action: { gridWidth = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                pull = max(0, -offset)
                atTop = offset <= 1
            }
            .onScrollPhaseChange { old, new in
                if old == .interacting, new != .interacting, pull > 70 {
                    dropped(pull, 1200)
                }
            }
            // The page you're on in sight, not left three rows down: put
            // there while the screen is away, never while it shows or
            // moves, so the page always zooms to a card that stays put.
            .onChange(of: away, initial: true) { _, away in
                guard away, let id = browser.activeID else { return }
                reader.scrollTo(id, anchor: .center)
            }
            .onChange(of: browser.activeID) { _, id in
                guard away, let id else { return }
                reader.scrollTo(id, anchor: .center)
            }
        }
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
        }
        Button(role: .destructive) {
            withAnimation(Motion.settle) { browser.close(tab) }
        } label: { Label("Close Tab", systemImage: "xmark") }
    }

    /// What the sheet does besides the tabs, as a row of round buttons
    /// along its foot: a new tab, a private one, the bookmarks, the other
    /// devices' tabs, Settings. Icons only; each says what it is to
    /// VoiceOver, and the new tab button, held, lists what was closed.
    private var foot: some View {
        VStack(spacing: 0) {
        pins
        HStack(spacing: 10) {
            Button {
                Feel.tick()
                browser.newTab()
            } label: {
                Label("New tab", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .font(.scaled(15, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .glass(Capsule(), interactive: true, else: Palette.wash)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contextMenu {
                if browser.closed.isEmpty {
                    Text("Nothing closed lately")
                } else {
                    Section("Recently Closed") {
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
                }
            }
            round("book", "Bookmarks") { browser.showingBookmarks = true }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// The screen's head: what can be done with all the tabs, as glass
    /// buttons on the left, by the thumb's reach from the side. No Done:
    /// a card, a drag down or the page itself takes the screen away.
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Feel.nudge()
                browser.askingCloseAll = true
            } label: { headerButton("xmark") }
            .buttonStyle(.plain)
            .disabled(loose.isEmpty)
            .accessibilityLabel("Close All")

            Button {
                Feel.tick()
                browser.newTab(private: true)
            } label: { headerButton("eyeglasses") }
            .buttonStyle(.plain)
            .accessibilityLabel("New private tab")

            Button {
                Feel.tick()
                withAnimation(Motion.settle) { prefs.tabCards.toggle() }
            } label: { headerButton(prefs.tabCards ? "list.bullet" : "square.grid.2x2") }
            .buttonStyle(.plain)
            .accessibilityLabel(prefs.tabCards ? "Show as List" : "Show as Cards")

            if prefs.sync {
                Button { browser.showingOthers = true } label: { headerButton("laptopcomputer.and.iphone") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Other devices")
            }

            Button { browser.settings = true } label: { headerButton("gearshape") }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")

            Spacer(minLength: 0)
        }
    }

    private func headerButton(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.scaled(15, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .frame(width: 40, height: 40)
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
    private struct Swipe<Content: View>: View {
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
    private struct Letter: View {
        @ObservedObject var tab: Tab
        let live: Bool
        let space: Namespace.ID
        let open: () -> Void
        let unpin: () -> Void

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
                        .fill(live ? Palette.pinLive : Palette.wash.opacity(0.55))
                }
                .overlay(alignment: .bottom) {
                    if tab.loading { Ring(size: 9).padding(.bottom, 5) }
                }
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .onTapGesture(perform: open)
                // Held: what can be done with it, said, rather than done.
                .contextMenu {
                    Button(action: unpin) { Label("Unpin", systemImage: "pin.slash") }
                    if let url = tab.pinHome ?? tab.address {
                        Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
                    }
                }
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
                    name
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

        private var name: some View {
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

        @ViewBuilder private var picture: some View {
            if hidden {
                Palette.wash.overlay {
                    Image(systemName: "lock.fill")
                        .font(.scaled(20))
                        .foregroundStyle(Palette.muted)
                }
            } else if let image = tab.snapshot, !tab.isBlank {
                // The top of the page, across its whole width.
                Palette.wash.overlay(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
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

    /// One line: what it is, then where it came from.
    private struct Line: View {
        @ObservedObject var tab: Tab
        let live: Bool
        /// A private tab while private tabs are locked: no title, no site.
        var hidden = false
        let space: Namespace.ID

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
                if let url = tab.address, !hidden {
                    Text(Address.host(url))
                        .font(.scaled(12.5))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background {
                if live {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.wash)
                        .matchedGeometryEffect(id: "live", in: space)
                }
            }
        }
    }
}
