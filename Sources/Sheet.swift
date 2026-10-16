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

    private var pinned: [Tab] { browser.tabs.filter { $0.pin != nil } }
    private var loose: [Tab] { browser.tabs.filter { $0.pin == nil } }

    private let row: CGFloat = 48

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
        .gesture(Pan(action: pan))
    }

    private var list: some View {
        List {
            ForEach(loose) { tab in
                Line(tab: tab, live: tab.id == browser.activeID, space: space)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(tab) }
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button {
                            Feel.tick()
                            withAnimation(Motion.settle) { browser.close(tab) }
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                        .tint(Color(white: 0.55))
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Feel.nudge()
                            withAnimation(Motion.settle) { browser.pin(tab) }
                        } label: {
                            Label("Pin", systemImage: "pin")
                        }
                        .tint(Color(white: 0.3))
                    }
            }

            HStack(spacing: 0) {
                Button {
                    Feel.tick()
                    browser.newTab()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18)
                        Text("New tab").font(.system(size: 15))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    browser.settings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                        .frame(width: 40, height: row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")

                // A tab that keeps nothing: no history, no cookies once
                // the last private tab closes, never written down.
                Button {
                    Feel.tick()
                    browser.newTab(private: true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 12, weight: .medium))
                        Text("Private").font(.system(size: 14))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: row)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Palette.muted)
            .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, row)
        .scrollBounceBehavior(.basedOnSize)
        // Hugs what it holds. A sheet that always reserves room for ten tabs
        // looks broken when it is showing one.
        .frame(height: min(CGFloat(loose.count + 1) * (row + 2) + 4, 420))
        // Pulled down past its start: the sheet follows, and goes on release.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            pull = max(0, -offset)
        }
        .onScrollPhaseChange { old, new in
            if old == .interacting, new != .interacting, pull > 70 {
                dropped(pull, 1200)
            }
        }
    }

    private var foot: some View {
        Color.clear
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(Pan(action: pan))
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
                        .font(.system(size: 16, weight: .medium))
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
        let space: Namespace.ID

        var body: some View {
            HStack(spacing: 10) {
                Group {
                    if tab.loading {
                        Ring(size: 12)
                    } else if !tab.isBlank {
                        // A new tab isn't a site: no icon, no letter.
                        Mark(icon: tab.icon, letter: tab.letter, size: 18)
                    }
                }
                .frame(width: 18, height: 18)

                Text(tab.label)
                    .font(.system(size: 15))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
                    .lineLimit(1)

                if tab.isPrivate {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }

                Spacer(minLength: 8)

                // The domain keeps its room: it is the shorter of the two and
                // the one that tells you which of three tabs on the same site
                // you are looking at.
                if let url = tab.address {
                    Text(Address.host(url))
                        .font(.system(size: 12.5))
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
