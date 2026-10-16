#if DEBUG
import SwiftUI

// Still pictures of the proposal, drawn from the Mac's numbers, for the
// decision before the build. Launched with SEARCH_MOCK=1…5; never in a
// release. The pages are drawn, not loaded, so the pictures are the same
// every time they're taken.

enum Mock {
    /// `-SEARCH_MOCK 3` as a launch argument, or SEARCH_MOCK=3 in the
    /// environment.
    static var screen: Int? {
        let asked = UserDefaults.standard.integer(forKey: "SEARCH_MOCK")
        if asked > 0 { return asked }
        return ProcessInfo.processInfo.environment["SEARCH_MOCK"].flatMap(Int.init)
    }
}

private enum Tone {
    static func ground(_ dark: Bool) -> Color { Color(white: dark ? 0.11 : 1) }
    static func ink(_ dark: Bool) -> Color { Color(white: dark ? 0.93 : 0.09) }
    static func muted(_ dark: Bool) -> Color { Color(white: dark ? 0.58 : 0.55) }
    static func faint(_ dark: Bool) -> Color { Color(white: dark ? 0.32 : 0.83) }
    static func hairline(_ dark: Bool) -> Color { Color(white: dark ? 0.20 : 0.91) }
    static func wash(_ dark: Bool) -> Color { Color(white: dark ? 0.175 : 0.937) }
    static func pinLive(_ dark: Bool) -> Color { Color(white: dark ? 0.21 : 0.90) }
}

struct MockScreen: View {
    let number: Int

    var body: some View {
        switch number {
        case 2: FieldMock()
        case 3: TabsMock()
        case 4: SwipeMock()
        case 5: ActionsMock()
        default: PageMock()
        }
    }
}

// MARK: - a page, drawn

private struct Article: View {
    var dark = false
    var site = "THE VERGE"
    var title = "The quiet browser that gets out of the way"
    var hue: Double = 0.58

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(site)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Tone.muted(dark))
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Tone.ink(dark))
                .fixedSize(horizontal: false, vertical: true)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.35, brightness: dark ? 0.45 : 0.85),
                            Color(hue: hue + 0.08, saturation: 0.45, brightness: dark ? 0.30 : 0.65),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(height: 210)
            ForEach(0..<7, id: \.self) { line in
                Text(Self.prose[line % Self.prose.count])
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(Tone.ink(dark).opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 76)
        // The page is longer than the screen, as pages are: drawn over the
        // ground so it never pushes anything else about.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    var body: some View {
        Tone.ground(dark)
            .overlay(alignment: .top) { content }
            .clipped()
    }

    static let prose = [
        "There is no toolbar. The page runs edge to edge, and the one thing you need, where you are, sits where your thumb already is.",
        "Everything else is a gesture away: flick the address to walk your tabs, lift it to see them all, hold it for the rest.",
        "Ads and trackers are stopped before they load, so pages arrive lighter and sooner, and nothing follows you between them.",
    ]
}

// MARK: - the bar

/// The one control on a page: where you are, and how many pages are open.
private struct Pill: View {
    var dark = false
    var text = "theverge.com"
    var count = 5
    var loading = false
    var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                if loading {
                    Circle()
                        .trim(from: 0, to: 0.78)
                        .stroke(Tone.muted(dark), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(40))
                }
                Text(text)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Tone.ink(dark))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Tone.ground(dark), in: Capsule())
            .overlay(Capsule().strokeBorder(Tone.hairline(dark), lineWidth: 1))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.06), radius: 24, y: 8)
            .offset(x: offset)

            Text("\(count)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tone.ink(dark))
                .frame(width: 48, height: 48)
                .background(Tone.ground(dark), in: Circle())
                .overlay(Circle().strokeBorder(Tone.hairline(dark), lineWidth: 1))
                .shadow(color: .black.opacity(dark ? 0.35 : 0.06), radius: 24, y: 8)
        }
        .padding(.horizontal, 16)
    }
}

private struct Note: View {
    let text: String
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Tone.ground(dark))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Tone.ink(dark).opacity(0.92), in: Capsule())
    }
}

// MARK: - 1. a page

private struct PageMock: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            Article()
            Pill(loading: false)
                .padding(.bottom, 8)
        }
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - 2. the field

private struct FieldMock: View {
    private let offers: [(String, String)] = [
        ("theverge.com", "The Verge"),
        ("theverge.com/tech", "Tech — The Verge"),
        ("thesaurus.com", "Thesaurus.com"),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Article()
                .overlay(Tone.ground(false).opacity(0.74))
                .ignoresSafeArea()

            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    ForEach(Array(offers.enumerated()), id: \.offset) { index, offer in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Tone.faint(false))
                                .frame(width: 16, height: 16)
                            Text(offer.0)
                                .font(.system(size: 15, weight: index == 0 ? .medium : .regular))
                                .foregroundStyle(Tone.ink(false))
                            Text(offer.1)
                                .font(.system(size: 14))
                                .foregroundStyle(Tone.muted(false))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(index == 0 ? Tone.wash(false) : .clear)
                        )
                    }
                }
                .padding(6)
                .background(Tone.ground(false), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Tone.hairline(false), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.07), radius: 20, y: 6)

                HStack(spacing: 0) {
                    Text("the")
                        .foregroundStyle(Tone.ink(false))
                    Text("verge.com")
                        .foregroundStyle(Tone.ink(false))
                        .background(Color.accentColor.opacity(0.18))
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: 20)
                        .padding(.leading, 1)
                    Spacer()
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Tone.faint(false))
                }
                .font(.system(size: 16))
                .padding(.horizontal, 20)
                .frame(height: 52)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Tone.ink(false).opacity(0.07))
                            .blur(radius: 26)
                            .scaleEffect(1.02)
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Tone.ground(false))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Tone.hairline(false), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 24, y: 8)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .safeAreaInset(edge: .bottom, spacing: 0) { Keys() }
        }
    }
}

/// Where the keyboard goes. A mockup can't raise the real one.
private struct Keys: View {
    var body: some View {
        VStack(spacing: 11) {
            ForEach([10, 9, 7], id: \.self) { count in
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white)
                            .frame(height: 42)
                            .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
                    }
                }
                .padding(.horizontal, count == 10 ? 0 : CGFloat(10 - count) * 9)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.68)).frame(width: 90, height: 42)
                RoundedRectangle(cornerRadius: 5).fill(Color.white).frame(height: 42)
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor).frame(width: 90, height: 42)
                    .overlay(Text("go").font(.system(size: 16)).foregroundStyle(.white))
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 44)
        .background(Color(white: 0.82).ignoresSafeArea())
    }
}

// MARK: - 3. every tab

private struct TabsMock: View {
    private let rows: [(String, String)] = [
        ("The quiet browser that gets out of the way", "theverge.com"),
        ("Hacker News", "news.ycombinator.com"),
        ("Typography — Wikipedia", "en.wikipedia.org"),
        ("Pull requests · driceroland/Search", "github.com"),
        ("Office Commun", "officecommun.com"),
    ]
    private let pins = ["G", "X", "F", "N", "Y"]

    var body: some View {
        ZStack(alignment: .bottom) {
            Article()
                .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                .scaleEffect(0.92, anchor: .top)
                .offset(y: 54)
                .overlay(Color.black.opacity(0.18).ignoresSafeArea())
                .background(Color.black.ignoresSafeArea())
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Tone.faint(false))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                // Pins: at most 4 to a row, fuller rows first, as on the Mac.
                VStack(spacing: 6) {
                    pinRow(Array(pins.prefix(3)), live: 0)
                    pinRow(Array(pins.suffix(2)), live: nil)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Tone.faint(false))
                                .frame(width: 18, height: 18)
                            Text(row.0)
                                .font(.system(size: 15))
                                .foregroundStyle(index == 0 ? Tone.ink(false) : Tone.muted(false))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(row.1)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Tone.faint(false))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(index == 0 ? Tone.wash(false) : .clear)
                        )
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 18)
                        Text("New tab").font(.system(size: 15))
                        Spacer()
                    }
                    .foregroundStyle(Tone.muted(false))
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                }
                .padding(.horizontal, 8)

                HStack {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(Tone.muted(false))
                        .frame(width: 44, height: 44)
                    Spacer()
                    Text("Private")
                        .font(.system(size: 14))
                        .foregroundStyle(Tone.muted(false))
                        .padding(.horizontal, 14)
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 30, topTrailingRadius: 30, style: .continuous)
                    .fill(Tone.ground(false))
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private func pinRow(_ letters: [String], live: Int?) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                Text(letter)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(index == live ? Tone.ink(false) : Tone.muted(false))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(index == live ? Tone.pinLive(false) : Tone.wash(false).opacity(0.55))
                    )
            }
        }
    }
}

// MARK: - 4. walking the tabs

/// Halfway through a flick: the page follows the finger, the next one comes
/// in behind it, and letting go either finishes or springs back.
private struct SwipeMock: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                HStack(spacing: 14) {
                    Article()
                        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                    Article(
                        site: "HACKER NEWS",
                        title: "Show HN: a browser with nothing in the way",
                        hue: 0.07
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                }
                .frame(width: w * 2 + 14)
                .scaleEffect(0.96)
                .offset(x: -w * 0.42)
                .frame(width: w, alignment: .leading)
                .ignoresSafeArea()

                VStack(spacing: 14) {
                    Note(text: "Let go to open Hacker News")
                    Pill(text: "news.ycombinator.com", count: 5, offset: -18)
                }
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - 5. hold the address

private struct ActionsMock: View {
    private let dark = true
    private let items: [(String, String)] = [
        ("arrow.clockwise", "Reload"),
        ("square.and.arrow.up", "Share"),
        ("text.magnifyingglass", "Find on page"),
        ("doc.plaintext", "Reader"),
        ("shield", "Allow ads on this site"),
        ("pin", "Pin"),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            Article(dark: dark)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(["chevron.left", "chevron.right"], id: \.self) { name in
                            Image(systemName: name)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(name == "chevron.left" ? Tone.ink(dark) : Tone.faint(dark))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                        }
                    }
                    Rectangle().fill(Tone.hairline(dark)).frame(height: 1)
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 14) {
                            Image(systemName: item.0)
                                .font(.system(size: 16))
                                .frame(width: 22)
                            Text(item.1).font(.system(size: 16))
                            Spacer()
                        }
                        .foregroundStyle(Tone.ink(dark))
                        .padding(.horizontal, 18)
                        .frame(height: 50)
                        if index < items.count - 1 {
                            Rectangle().fill(Tone.hairline(dark)).frame(height: 1).padding(.leading, 54)
                        }
                    }
                }
                .background(Tone.ground(dark), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Tone.hairline(dark), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
                .padding(.horizontal, 16)

                Pill(dark: dark)
                    .scaleEffect(0.97)
            }
            .padding(.bottom, 8)
        }
        .preferredColorScheme(.dark)
    }
}
#endif
