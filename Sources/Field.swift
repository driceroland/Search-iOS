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
    @State private var selection: TextSelection?
    /// The text the selection was made in: its indices mean nothing in any
    /// other string, even one as long (another script, other letters).
    @State private var selectedIn = ""

    private var blank: Bool { browser.active?.isBlank ?? true }

    /// The selection, only while it still falls inside what's typed. The text
    /// can be replaced under it (a new tab, a suggestion taken); handing the
    /// field a range past the end of the new text stops the app.
    private var fitting: Binding<TextSelection?> {
        Binding(
            get: {
                guard let selection else { return nil }
                let text = browser.typed
                switch selection.indices {
                case .selection(let range):
                    if text == selectedIn { return selection }
                    // Text changed under it: kept only if both ends still
                    // fall on a letter of this text, never between.
                    guard range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex,
                          range.lowerBound.samePosition(in: text) != nil,
                          range.upperBound.samePosition(in: text) != nil
                    else { return nil }
                    return selection
                default:
                    return nil
                }
            },
            set: { selection = $0; selectedIn = browser.typed }
        )
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
            guard raised else {
                // Put away: the selection was over that text, not the next.
                selection = nil
                return
            }
            // Selected once the field has the caret: a selection set before
            // it does is dropped by the focus change.
            DispatchQueue.main.async {
                let text = browser.typed
                if !text.isEmpty {
                    selection = TextSelection(range: text.startIndex..<text.endIndex)
                    selectedIn = text
                }
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
                        }
                    }
                    .padding(.horizontal, 14)
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
                TextField("", text: $browser.typed, selection: fitting)
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

    private var favourites: [Suggestion] {
        bookmarks.roots.compactMap { mark in
            guard let raw = mark.url, let url = URL(string: raw) else { return nil }
            return Suggestion(key: Address.host(url), title: mark.title, url: url)
        }
        .prefix(8)
        .map { $0 }
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
            if !favourites.isEmpty { group("Bookmarks", favourites) }
            if !often.isEmpty { group("Often visited", often, removable: true) }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: Favicons.came)) { _ in load() }
    }

    private func group(_ title: LocalizedStringKey, _ sites: [Suggestion], removable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.scaled(13, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(sites) { site in
                    Button {
                        Feel.tick()
                        browser.take(site)
                    } label: {
                        VStack(spacing: 6) {
                            Mark(icon: icons[Favicons.key(site.url) ?? ""], letter: String(Address.host(site.url).prefix(1)).uppercased(), size: 30)
                                .frame(width: 58, height: 58)
                                .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true, else: Palette.wash)
                            Text(site.title.isEmpty ? Address.host(site.url) : site.title)
                                .font(.scaled(11.5))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu(removable ? ContextMenu {
                        Button(role: .destructive) {
                            withAnimation(Motion.quick) {
                                browser.history.remove(site: site.key)
                                browser.objectWillChange.send()
                            }
                        } label: {
                            Label("Remove from Often Visited", systemImage: "minus.circle")
                        }
                    } : nil)
                }
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
