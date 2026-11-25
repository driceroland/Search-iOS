import SwiftUI

// On a screen wide and tall enough to hold it (an open iPhone Duo, an iPad):
// the Mac's sidebar. The pins on top, the tabs one to a line, New tab under
// them; Bookmarks and Settings at its foot. The page and the pill sit beside
// it, as on a narrower screen.

/// The screen, with the sidebar beside it when there's room for one.
struct Shell: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var prefs = Prefs.shared

    /// Wide enough for the sidebar and a page beside it at a phone's width,
    /// and tall enough that it isn't an iPhone on its side.
    static func roomy(_ size: CGSize) -> Bool { size.width >= 700 && size.height >= 500 }

    @State private var roomy = false

    var body: some View {
        HStack(spacing: 0) {
            if roomy && prefs.sidebar {
                Sidebar(browser: browser)
                    .transition(.move(edge: .leading))
            }
            ContentView(browser: browser)
        }
        .animation(Motion.settle, value: prefs.sidebar)
        // The screen below makes no room for the keyboard by itself (the
        // field follows it); this row mustn't either.
        .ignoresSafeArea(.keyboard)
        // The whole screen's size, the safe area's bands included.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
            )
        } action: { screen in
            roomy = Self.roomy(screen)
            browser.roomy = roomy
        }
    }
}

struct Sidebar: View {
    @ObservedObject var browser: Browser
    @Namespace private var space

    static let width: CGFloat = 264

    private var pinned: [Tab] { browser.tabs.filter { $0.pin != nil } }
    private var loose: [Tab] { browser.tabs.filter { $0.pin == nil && $0.isPrivate == browser.privateView } }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 2) {
                    pins
                    ForEach(loose) { tab in
                        Sheet.Swipe {
                            Feel.tick()
                            withAnimation(Motion.settle) { browser.close(tab) }
                        } pin: {
                            Feel.nudge()
                            withAnimation(Motion.settle) { browser.pin(tab) }
                        } content: {
                            Sheet.Line(tab: tab, live: tab.id == browser.activeID, hidden: browser.locked && tab.isPrivate, space: space, side: true)
                                .contentShape(Rectangle())
                                .onTapGesture { pick(tab) }
                        }
                        .contextMenu { menu(for: tab) }
                        .transition(.opacity.combined(with: .scale(0.96, anchor: .leading)))
                    }
                    newTab
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                .animation(Motion.settle, value: loose.map(\.id))
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            foot
        }
        .frame(width: Self.width)
        .background(Palette.wash.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Palette.hairline.frame(width: 0.5).ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            round("sidebar.left", "Hide Sidebar") {
                Prefs.shared.sidebar = false
            }
            Spacer()
            round(browser.privateView ? "eyeglasses.slash" : "eyeglasses",
                  browser.privateView ? "Tabs" : "Private") {
                withAnimation(Motion.settle) { browser.privateView.toggle() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    /// The pins, as on the Mac: squares, at most four to a row.
    @ViewBuilder private var pins: some View {
        if !pinned.isEmpty {
            let rows = Sheet.rows(of: pinned)
            VStack(spacing: 6) {
                ForEach(rows.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        ForEach(rows[index]) { tab in
                            Sheet.Letter(
                                tab: tab, live: tab.id == browser.activeID, space: space,
                                open: { pick(tab) },
                                unpin: {
                                    Feel.nudge()
                                    withAnimation(Motion.settle) { browser.pin(tab) }
                                },
                                side: true
                            )
                            .contextMenu {
                                Button {
                                    withAnimation(Motion.settle) { browser.pin(tab) }
                                } label: { Label("Unpin", systemImage: "pin.slash") }
                                if let url = tab.pinHome ?? tab.address {
                                    Button { UIPasteboard.general.url = url } label: {
                                        Label("Copy Link", systemImage: "link")
                                    }
                                }
                            }
                        }
                        // Fewer than three pins still keep three places,
                        // the Mac's rule: one pin isn't a bar across.
                        if pinned.count < 3 {
                            ForEach(0..<(3 - pinned.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity).frame(height: 50)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .animation(Motion.settle, value: pinned.map(\.id))
        }
    }

    private var newTab: some View {
        Button {
            Feel.tick()
            browser.newTab(private: browser.privateView)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.scaled(14, weight: .medium))
                    .frame(width: 18, height: 18)
                Text(browser.privateView ? "New private tab" : "New tab")
                    .font(.scaled(15))
                Spacer()
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var foot: some View {
        HStack(spacing: 6) {
            round("book", "Bookmarks") { browser.showingBookmarks = true }
            round("gearshape", "Settings") { browser.settings = true }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func round(_ symbol: String, _ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.scaled(16))
                .foregroundStyle(Palette.muted)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    private func pick(_ tab: Tab) {
        Feel.tick()
        withAnimation(Motion.glide) { browser.pickBeside(tab) }
    }

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
}
