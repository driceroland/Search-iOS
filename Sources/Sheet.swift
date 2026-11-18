import SwiftUI

/// Every open page — the Mac's column, risen from the bottom.
///
/// Pins first, as letters in rows of at most four, fuller rows first (the
/// Mac's rule: 5 → 3 + 2). Then one line per page, the way the Mac's tabs are
/// one line: what it is, then where it came from, and the grey behind the one
/// you're on, which slides to the one you pick. Swipe a line left to close it,
/// right to pin it. Not a wall of screenshots: titles say more than six blurred
/// pictures do.
///
/// The sheet goes where the finger takes it. Drag it down by its top, or pull
/// the list down past its start, and let go.
struct Sheet: View {
    @ObservedObject var browser: Browser
    let space: Namespace.ID

    var drag: (CGFloat) -> Void
    var dropped: (CGFloat, CGFloat) -> Void
    var height: (CGFloat) -> Void

    @State private var pull: CGFloat = 0
    /// The list shows its first line: a drag down anywhere moves the sheet.
    @State private var atTop = true
    /// The drag under way is the sheet's (true), someone else's (false), or
    /// not decided yet (nil).
    @State private var dragging: Bool?
    /// A line lifted to be put somewhere else.
    @State private var carried: Tab?

    private var pinned: [Tab] { browser.tabs.filter { $0.pin != nil } }
    private var loose: [Tab] { browser.tabs.filter { $0.pin == nil } }

    private let row: CGFloat = 48

    /// More lines than the sheet has room for.
    private var overflows: Bool { CGFloat(loose.count) * (row + 2) + 4 > 420 }

    var body: some View {
        VStack(spacing: 0) {
            top
            list
            foot
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                .fill(Palette.ground)
                .shadow(color: .black.opacity(0.12), radius: 30, y: -6)
                // Runs on below the screen's edge, so the few points it gives
                // when pulled up never show what's under it.
                .padding(.bottom, -200)
                .ignoresSafeArea(edges: .bottom)
        )
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height($0) }
        // Down from anywhere on it: the rows, the empty room, the foot. A
        // drag that sets off sideways is a row's to close or pin, and a tap
        // still picks; only one going down moves the sheet.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .onChanged { value in
                    if dragging == nil {
                        let down = value.translation.height > 0
                            && value.translation.height > abs(value.translation.width) * 1.2
                        dragging = down && atTop
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
        VStack(spacing: 0) {
            Capsule()
                .fill(Palette.faint)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 14)

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
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
                    // Held and dragged: the line goes where it's let go.
                    .onDrag {
                        carried = tab
                        Feel.nudge()
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: Reorder(target: tab, carried: $carried, browser: browser))
                    .transition(.opacity.combined(with: .scale(0.96, anchor: .leading)))
                }

            }
            .padding(.horizontal, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        // A list that fits doesn't scroll at all, so a drag down on it is
        // the sheet's.
        .scrollDisabled(!overflows)
        // Hugs what it holds. A sheet that always reserves room for ten tabs
        // looks broken when it is showing one.
        .frame(height: min(CGFloat(loose.count) * (row + 2) + 4, 420))
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            pull = max(0, -offset)
            atTop = offset <= 1
        }
        .onScrollPhaseChange { old, new in
            // A long list pulled down past its start: let go and it goes.
            if overflows, old == .interacting, new != .interacting, pull > 70 {
                dropped(pull, 1200)
            }
        }
    }

    /// What the sheet does besides the tabs, as a row of round buttons
    /// along its foot: a new tab, a private one, the bookmarks, the other
    /// devices' tabs, Settings. Icons only; each says what it is to
    /// VoiceOver, and the new tab button, held, lists what was closed.
    private var foot: some View {
        HStack(spacing: 14) {
            round("plus", "New tab") {
                Feel.tick()
                browser.newTab()
            }
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
            round("eyeglasses", "New private tab") {
                Feel.tick()
                browser.newTab(private: true)
            }
            round("book", "Bookmarks") { browser.showingBookmarks = true }
            if Prefs.shared.sync {
                round("laptopcomputer.and.iphone", "Other devices") { browser.showingOthers = true }
            }
            round("gearshape", "Settings") { browser.settings = true }
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func round(_ symbol: String, _ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.scaled(16, weight: .medium))
                .foregroundStyle(Palette.ink)
                .frame(width: 50, height: 50)
                .background(Palette.wash, in: Circle())
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
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .onLongPressGesture(minimumDuration: 0.4, perform: unpin)
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

                Text(hidden ? "Private tab" : tab.label)
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
