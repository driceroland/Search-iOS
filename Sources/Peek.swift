import SwiftUI
import WebKit

/// A link held: the page it goes to, live, in a card over the one you're on,
/// the page under it softened. Scroll it to see more; tap it to open it as a
/// tab, scrolled where you left it; or pick from the menu under it. A tap
/// anywhere else puts it away.
struct PeekView: View {
    @ObservedObject var browser: Browser
    let peek: Browser.Peek
    @ObservedObject private var tab: Tab

    init(browser: Browser, peek: Browser.Peek) {
        self.browser = browser
        self.peek = peek
        self.tab = peek.tab
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 28, 520)
            let height = max(220, (geo.size.height - geo.safeAreaInsets.top - 250) * 0.92)
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { browser.dropPeek() }
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        if tab.loading {
                            Ring(size: 11)
                        } else {
                            Mark(icon: tab.icon, letter: tab.letter, size: 15)
                        }
                        Text(tab.title.isEmpty ? Address.host(peek.url) : tab.title)
                            .font(.scaled(13.5, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)

                    // Its page only while it's still a peek: kept as a tab, the
                    // page goes to the tab's own stage and this one lets go.
                    PeekStage(page: browser.peek?.id == peek.id ? tab.web : nil) { browser.keepPeek(behind: false) }
                        .frame(width: width, height: height)
                        .background(Palette.ground)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(Palette.faint.opacity(0.3), lineWidth: 0.5)
                        }
                        .shadow(color: .black.opacity(0.2), radius: 22, y: 8)

                    menu
                        .frame(width: min(width, 290))
                }
                .frame(width: width)
                .padding(.top, 10)
                .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var menu: some View {
        VStack(spacing: 0) {
            row("Open in New Tab", "plus.square.on.square") { browser.keepPeek(behind: false) }
            Divider().opacity(0.5)
            row("Open Behind", "square.on.square") { browser.keepPeek(behind: true) }
            Divider().opacity(0.5)
            row("Copy Link", "link") {
                UIPasteboard.general.url = peek.url
                browser.dropPeek()
            }
            Divider().opacity(0.5)
            row("Share…", "square.and.arrow.up") {
                let url = peek.url
                browser.dropPeek()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Present.share([url]) }
            }
        }
        .background(Glass(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
    }

    private func row(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.scaled(15))
                    .foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: symbol)
                    .font(.scaled(15))
                    .foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The peeked page's own view, scrolled by the finger; a tap on it opens it.
/// The tap is caught on the page itself (WebKit's own taps would win over
/// one further out), and its links never answer it: a peek's links are
/// stopped before they go anywhere.
private struct PeekStage: UIViewRepresentable {
    let page: UIView?
    let tapped: () -> Void

    func makeUIView(context: Context) -> Holder { Holder() }

    func updateUIView(_ view: Holder, context: Context) {
        // Never taken back once let go: the tab's stage has it now.
        guard let page else { return }
        view.hold(page)
        if let tap = page.gestureRecognizers?.compactMap({ $0 as? PeekTap }).first {
            tap.tapped = tapped
        } else {
            page.addGestureRecognizer(PeekTap(tapped: tapped))
        }
    }

    /// Holds the page while it's a peek; unlike the tabs' stage it never
    /// takes it back from wherever it went next.
    final class Holder: UIView {
        private weak var page: UIView?

        func hold(_ next: UIView) {
            page = next
            if next.superview !== self {
                next.removeFromSuperview()
                addSubview(next)
            }
            next.frame = bounds
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let page, page.superview === self { page.frame = bounds }
        }
    }
}

/// A tap on a peeked page. Taken off it when the peek ends.
final class PeekTap: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    var tapped: () -> Void

    init(tapped: @escaping () -> Void) {
        self.tapped = tapped
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delegate = self
        addTarget(self, action: #selector(fire))
    }

    @objc private func fire() { if state == .ended { tapped() } }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    static func remove(from view: UIView) {
        for tap in view.gestureRecognizers ?? [] where tap is PeekTap { view.removeGestureRecognizer(tap) }
    }
}
