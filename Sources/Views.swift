import SwiftUI

/// The bar at the bottom: where you are, and the way to everything else.
///
/// At the bottom because that is where a thumb is, and swipeable because that
/// is what a thumb does. The address is shown short — nobody needs to read a
/// scheme, and the room is better spent on the part that says which site.
struct Bar: View {
    @ObservedObject var browser: Browser

    @State private var slide: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Button { browser.edit() } label: {
                HStack(spacing: 8) {
                    if browser.active?.loading == true { Ring() }
                    Text(browser.active?.short ?? "Search or enter an address")
                        .font(.system(size: 15))
                        .foregroundStyle(
                            browser.active?.isBlank == false ? Palette.ink : Palette.muted
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Palette.ground, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                .offset(x: slide)
            }
            .buttonStyle(.plain)
            // Flick the address sideways to walk the row, the way you would
            // flick anything else on a phone.
            .highPriorityGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        slide = value.translation.width / 3
                    }
                    .onEnded { value in
                        let far = value.translation.width
                        withAnimation(Motion.settle) { slide = 0 }
                        guard abs(far) > 55 else { return }
                        Feel.tick()
                        browser.step(far < 0 ? 1 : -1)
                    }
            )

            Button { browser.openTabs() } label: {
                Text("\(browser.tabs.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44)
                    .background(Palette.ground, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .background(Palette.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.hairline).frame(height: 0.5)
        }
        .animation(Motion.quick, value: browser.tabs.count)
    }
}

/// A tap you can feel. The difference between an interface that responds and
/// one that answers.
enum Feel {
    static func tick() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func nudge() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func refuse() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// An almost-closed ring, turning.
struct Ring: View {
    var size: CGFloat = 12
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.78)
            .stroke(Palette.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// Wrong address, said without a dialog: the field shivers and stops.
struct Shake: GeometryEffect {
    var travel: CGFloat

    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let decay = 1 - travel
        return ProjectionTransform(
            CGAffineTransform(translationX: sin(travel * .pi * 6) * 7 * decay, y: 0)
        )
    }
}

/// The address field, over the page, with what it thinks you mean under it.
///
/// The same pill as the Mac, with the same slow breath under it — on an empty
/// tab it is the only thing on screen, and a thing that never moves reads as a
/// picture of an app rather than an app.
struct Field: View {
    @ObservedObject var browser: Browser

    @FocusState private var typing: Bool
    @State private var shake: CGFloat = 0
    @State private var refused = false
    @State private var breathing = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            if !browser.offers.isEmpty {
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
                                        .foregroundStyle(Palette.faint)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    // The first row is the one Return would
                                    // take, so it is the one that looks taken.
                                    .fill(index == 0 ? Palette.wash : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .padding(8)
                .background(Palette.ground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.07), radius: 22, y: 8)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            HStack(spacing: 10) {
                ZStack(alignment: .leading) {
                    if browser.typed.isEmpty {
                        Text("Search or enter an address")
                            .foregroundStyle(Palette.ink.opacity(0.3))
                    }
                    TextField("", text: $browser.typed)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                        .focused($typing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { browser.submit() }
                }
                .font(.system(size: 16))

                Button("Cancel") { browser.dismiss() }
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Palette.ink.opacity(0.05))
                        .blur(radius: 24)
                        .scaleEffect(breathing ? 1.03 : 0.97)
                        .opacity(breathing ? 1 : 0.6)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Palette.ground)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        refused ? Color.red.opacity(0.35) : Palette.hairline,
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.08), radius: 20, y: 6)
            .modifier(Shake(travel: shake))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .background(
            Color.black.opacity(0.10)
                .ignoresSafeArea()
                .onTapGesture { browser.dismiss() }
        )
        .onAppear {
            typing = true
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                breathing = true
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
}

/// Every open page — the Mac's strip, stood on its end.
///
/// Not a wall of screenshots. The Mac never shows one, and a phone showing six
/// blurred thumbnails tells you less than six titles do. Same pills, same
/// hairlines, same grey behind the one you are on, and the grey slides from the
/// row you left to the row you picked rather than blinking between them.
struct Rows: View {
    @ObservedObject var browser: Browser
    let space: Namespace.ID

    @State private var risen = false

    private var pinned: [Tab] { browser.tabs.filter { $0.pin != nil } }
    private var loose: [Tab] { browser.tabs.filter { $0.pin == nil } }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(risen ? 0.10 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Palette.faint)
                    .frame(width: 34, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 14)

                if !pinned.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(pinned) { tab in
                            Letter(
                                tab: tab,
                                live: tab.id == browser.activeID,
                                space: space,
                                open: { pick(tab) },
                                unpin: {
                                    Feel.nudge()
                                    withAnimation(Motion.settle) { browser.pin(tab) }
                                }
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(loose) { tab in
                            Row(
                                tab: tab,
                                live: tab.id == browser.activeID,
                                space: space,
                                open: { pick(tab) },
                                close: {
                                    Feel.tick()
                                    withAnimation(Motion.settle) { browser.close(tab) }
                                },
                                pin: {
                                    Feel.nudge()
                                    withAnimation(Motion.settle) { browser.pin(tab) }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
                // Hugs what it holds. A panel that always reserves room for
                // ten tabs looks broken when it is showing one.
                .frame(maxHeight: min(CGFloat(loose.count) * 44 + 6, 330))

                Divider().overlay(Palette.hairline).padding(.vertical, 10)

                HStack {
                    Button {
                        Feel.tick()
                        browser.newTab()
                    } label: {
                        Text("New page")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.ink)
                    }
                    Spacer()
                    Button("Done") { close() }
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 24, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 24,
                    style: .continuous
                )
                .fill(Palette.ground)
                .ignoresSafeArea(edges: .bottom)
            )
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.hairline).frame(height: 0.5)
            }
            .shadow(color: .black.opacity(0.10), radius: 30, y: -6)
            .offset(y: risen ? 0 : 500)
        }
        .onAppear {
            withAnimation(Motion.glide) { risen = true }
        }
    }

    private func pick(_ tab: Tab) {
        Feel.tick()
        withAnimation(Motion.glide) { risen = false }
        browser.select(tab)
    }

    private func close() {
        withAnimation(Motion.glide) { risen = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            browser.showingTabs = false
        }
    }

    /// A pinned tab: a square, one letter, and its place at the head.
    private struct Letter: View {
        @ObservedObject var tab: Tab
        let live: Bool
        let space: Namespace.ID
        let open: () -> Void
        let unpin: () -> Void

        var body: some View {
            Text(tab.pin ?? "")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(live ? Palette.ink : Palette.muted)
                .frame(width: 40, height: 40)
                .background {
                    if live {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.wash)
                            .matchedGeometryEffect(id: "live", in: space)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.wash.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .onLongPressGesture(perform: unpin)
        }
    }

    /// One line, the way the Mac's tabs are one line: what it is, then where
    /// it came from, and the grey behind the one you are on.
    private struct Row: View {
        @ObservedObject var tab: Tab
        let live: Bool
        let space: Namespace.ID
        let open: () -> Void
        let close: () -> Void
        let pin: () -> Void

        var body: some View {
            HStack(spacing: 10) {
                if tab.loading { Ring(size: 11) }

                Text(tab.label)
                    .font(.system(size: 14.5))
                    .foregroundStyle(live ? Palette.ink : Palette.muted)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // The domain keeps its room: it is the shorter of the two and
                // the one that tells you which of three tabs on the same site
                // you are looking at.
                if let url = tab.address {
                    Text(Address.pretty(url))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                }

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 7)
            .background {
                if live {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.wash)
                        .matchedGeometryEffect(id: "live", in: space)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .onLongPressGesture(perform: pin)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}
