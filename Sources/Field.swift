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

    private var blank: Bool { browser.active?.isBlank ?? true }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if !browser.offers.isEmpty {
                offers
                    .transition(.scale(0.98, anchor: .bottom).combined(with: .opacity))
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
        .onAppear {
            typing = true
            // Selected once the field has the caret: a selection set before
            // it does is dropped by the focus change.
            DispatchQueue.main.async {
                let text = browser.typed
                if !text.isEmpty { selection = TextSelection(range: text.startIndex..<text.endIndex) }
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
    }

    private var offers: some View {
        VStack(spacing: 2) {
            ForEach(Array(browser.offers.enumerated()), id: \.element.id) { index, offer in
                Button {
                    Feel.tick()
                    browser.take(offer)
                } label: {
                    HStack(spacing: 10) {
                        Text(offer.key)
                            .font(.system(size: 15, weight: index == 0 ? .medium : .regular))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        if !offer.title.isEmpty {
                            Text(offer.title)
                                .font(.system(size: 14))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
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
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 20, y: 6)
    }

    private var field: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                if browser.typed.isEmpty {
                    Text(browser.active?.isPrivate == true ? "Private: search or enter an address" : "Search or enter an address")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                // What it guessed, after what you typed, in the selection's
                // grey: Go takes it, another letter replaces it.
                if let ending = browser.ending {
                    (Text(browser.typed).foregroundStyle(.clear)
                        + Text(ending).foregroundStyle(Palette.ink.opacity(0.4)))
                        .lineLimit(1)
                }
                TextField("", text: $browser.typed, selection: $selection)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($typing)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { browser.submit() }
            }
            .font(.system(size: 16))

            if !browser.typed.isEmpty {
                Button {
                    browser.typed = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Palette.ground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                refused ? Color.red.opacity(0.35) : Palette.hairline,
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
                    .matchedGeometryEffect(id: "pill", in: space)
            }
        }
        .modifier(Shake(travel: shake))
        .animation(Motion.quick, value: browser.typed.isEmpty)
    }
}
