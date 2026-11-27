import SwiftUI

/// The address field: the pill, lifted above the keyboard, with what it thinks
/// you mean above it. The first suggestion is the one Go takes, so it is the one
/// that looks taken; the rest of the address it guessed is typed in for you,
/// selected, as on the Mac.
///
/// On an empty tab it is the only thing on screen, with the Mac's slow breath
/// under it. Drag it down, or tap the page, to put it away.
struct Field: View {
    @ObservedObject var browser: Browser
    let space: Namespace.ID

    @FocusState private var typing: Bool
    @State private var shake: CGFloat = 0
    @State private var refused = false
    @State private var drop: CGFloat = 0
    /// The address it opens on is selected, as in Safari: the first letter
    /// typed replaces it, and a tap places the caret to edit it instead.
    /// Done by the text field itself (select all), never through SwiftUI's
    /// selection binding: its indices come from the field's own copy of the
    /// text, and checking them against ours stopped the app (iOS 18 in build
    /// 6, every iOS in build 8). Text put in by code leaves the caret at its
    /// end, which is what Fill In wants.
    private var blank: Bool { browser.active?.isBlank ?? true }

    /// Put text in the field with the caret after it, to go on typing.
    private func fill(_ text: String) {
        browser.typed = text
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if !(browser.offers.isEmpty && browser.searches.isEmpty) {
                offers
                    .transition(.scale(0.98, anchor: .bottom).combined(with: .opacity))
            } else if blank, browser.typed.isEmpty {
                // A new tab: where one usually goes, ready to be tapped.
                Start(browser: browser)
                    .transition(.opacity)
            }

            field
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .offset(y: drop)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    drop = max(0, value.translation.height)
                }
                .onEnded { value in
                    let landing = value.translation.height + value.velocity.height * 0.15
                    if landing > 90 {
                        browser.dismiss()
                    }
                    withAnimation(Motion.settle) { drop = 0 }
                }
        )
        // Always there, hidden while the pill shows: it takes the caret when
        // it's raised and gives it back when it's put away.
        .onChange(of: browser.editing, initial: true) { _, raised in
            typing = raised
            guard raised else { return }
            // Selected once the field has the caret: before, the focus
            // change drops it. Sent to whatever has the caret: the field.
            DispatchQueue.main.async {
                guard browser.editing, !browser.typed.isEmpty else { return }
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
        .onChange(of: browser.refusals) { _, _ in
            Feel.refuse()
            shake = 0
            refused = true
            withAnimation(.easeOut(duration: 0.5)) { shake = 1 }
        }
        .onChange(of: browser.typed) { _, _ in
            withAnimation(Motion.quick) { refused = false }
        }
        .animation(Motion.settle, value: browser.offers)
        .animation(Motion.settle, value: browser.searches)
    }

    private var offers: some View {
        VStack(spacing: 2) {
            ForEach(Array((browser.offers + browser.searches).enumerated()), id: \.element.id) { index, offer in
                Button {
                    Feel.tick()
                    browser.take(offer)
                } label: {
                    HStack(spacing: 10) {
                        if offer.search {
                            Image(systemName: "magnifyingglass")
                                .font(.scaled(13))
                                .foregroundStyle(Palette.muted)
                        }
                        Text(offer.key)
                            .font(.scaled(15, weight: index == 0 ? .medium : .regular))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if !offer.title.isEmpty {
                            Text(offer.title)
                                .font(.scaled(14))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if offer.tab != nil {
                            // Already open: taking it goes to that tab.
                            Label("Switch to tab", systemImage: "square.on.square")
                                .labelStyle(.titleAndIcon)
                                .font(.scaled(12.5))
                                .foregroundStyle(Palette.muted)
                                .fixedSize()
                        } else {
                            // Into the field, not gone to: to go on typing
                            // from it, as in Safari.
                            Button {
                                Feel.tick()
                                fill(offer.search ? offer.key + " " : Address.pretty(offer.url))
                            } label: {
                                Image(systemName: "arrow.up.left")
                                    .font(.scaled(14, weight: .medium))
                                    .foregroundStyle(Palette.muted)
                                    .frame(width: 40, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Fill In")
                        }
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, offer.tab != nil ? 14 : 2)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(index == 0 ? Palette.wash : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
    }

    private var field: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if browser.typed.isEmpty {
                    Text(browser.active?.isPrivate == true ? LocalizedStringKey("Private: search or enter an address") : LocalizedStringKey("Search or enter an address"))
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                // What it guessed, after what you typed, in the selection's
                // grey: Go takes it, another letter replaces it.
                if let ending = browser.ending {
                    (Text(browser.typed).foregroundStyle(.clear)
                        + Text(ending).foregroundStyle(Palette.ink.opacity(0.4)))
                        .lineLimit(1)
                }
                TextField("", text: $browser.typed)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { browser.submit() }
            }
            .font(.scaled(16))

            if !browser.typed.isEmpty {
                Button {
                    browser.typed = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.scaled(16))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .frame(height: 52)
        .background {
            ZStack {
                if blank { Breath(radius: 18) }
                Glass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.red.opacity(refused ? 0.35 : 0), lineWidth: 1)
                    )
                    .matchedGeometryEffect(id: "pill", in: space, isSource: browser.editing)
            }
        }
        .modifier(Shake(travel: shake))
        .animation(Motion.quick, value: browser.typed.isEmpty)
    }
}

/// A new tab's few suggestions before anything is typed: the bookmarks at
/// the top of the list, then the sites visited most. Nothing if there are
/// none yet: no sponsored tiles, no news.
struct Start: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var bookmarks = Bookmarks.shared
    @State private var icons: [String: UIImage] = [:]

    /// The top of the bookmarks, folders as well as sites, in their order.
    /// Each keeps its own place: two on one site are two tiles, not one
    /// tile and a hole.
    private var marks: [Bookmark] {
        var seen = Set<String>()
        return bookmarks.roots.filter { mark in
            if mark.isFolder { return true }
            guard let raw = mark.url, URL(string: raw) != nil else { return false }
            return seen.insert(raw).inserted
        }
        .prefix(8)
        .map { $0 }
    }

    private var favourites: [Suggestion] {
        marks.compactMap { mark in
            guard let raw = mark.url, let url = URL(string: raw) else { return nil }
            return Suggestion(key: raw, title: mark.title, url: url)
        }
    }

    private var often: [Suggestion] {
        let known = Set(favourites.map { Address.host($0.url) })
        return browser.history.top(12)
            .filter { !known.contains(Address.host($0.url)) }
            .prefix(8)
            .map { Suggestion(key: $0.key, title: "", url: $0.url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !marks.isEmpty { bookmarksGroup }
            if !often.isEmpty { group("Often visited", often, removable: true) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: Favicons.came)) { _ in load() }
    }

    private var bookmarksGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmarks")
                .font(.scaled(13, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(marks) { mark in
                    if let raw = mark.url, let url = URL(string: raw) {
                        tile(Suggestion(key: raw, title: mark.title, url: url), bookmark: mark.id)
                    } else {
                        Button {
                            Feel.tick()
                            browser.bookmarkFolder = mark.id
                            browser.showingBookmarks = true
                        } label: {
                            label(title: mark.title) {
                                Image(systemName: "folder")
                                    .font(.scaled(20))
                                    .foregroundStyle(Palette.ink)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func label<Icon: View>(title: String, still: Bool = false, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 6) {
            icon()
                .frame(width: 58, height: 58)
                .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: !still, else: Palette.wash)
            Text(title)
                .font(.scaled(11.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// A site on New tab. Held: kept or let go (a bookmark taken away, a
    /// frequent site bookmarked or dropped). The tile stays where it is
    /// under the finger: its glass doesn't answer the press, the menu does.
    private func tile(_ site: Suggestion, bookmark: Bookmark.ID? = nil, removable: Bool = false) -> some View {
        Button {
            Feel.tick()
            browser.take(site)
        } label: {
            label(title: site.title.isEmpty ? Address.host(site.url) : site.title, still: true) {
                Mark(icon: icons[Favicons.key(site.url) ?? ""], letter: String(Address.host(site.url).prefix(1)).uppercased(), size: 30)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Built as the menu opens, before it takes the keyboard away.
            let _ = Keyboard.hold()
            if let bookmark {
                Button(role: .destructive) {
                    withAnimation(Motion.quick) { bookmarks.remove(bookmark) }
                } label: {
                    Label("Remove from Bookmarks", systemImage: "minus.circle")
                }
            }
            if removable {
                if !bookmarks.contains(site.url) {
                    Button {
                        Feel.tick()
                        withAnimation(Motion.quick) { bookmarks.add(site.url, title: "") }
                        browser.say(String(localized: "Added to Bookmarks"))
                    } label: {
                        Label("Add to Bookmarks", systemImage: "book")
                    }
                }
                Button(role: .destructive) {
                    withAnimation(Motion.quick) {
                        browser.history.remove(site: site.key)
                        browser.objectWillChange.send()
                    }
                } label: {
                    Label("Remove from Often Visited", systemImage: "minus.circle")
                }
            }
        }
    }

    private func group(_ title: LocalizedStringKey, _ sites: [Suggestion], removable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.scaled(13, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(sites) { site in tile(site, removable: removable) }
            }
        }
    }

    private func load() {
        for site in favourites + often {
            guard let key = Favicons.key(site.url) else { continue }
            if let icon = Favicons.shared.cached(site.url) {
                icons[key] = icon
            } else {
                Favicons.shared.prefetch(site.url)
            }
        }
    }
}
