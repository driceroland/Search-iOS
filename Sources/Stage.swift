import SwiftUI
import WebKit

/// The one place a page is allowed to be. Tabs hand their web view over when
/// they become the live one and get it back untouched — no reload, no lost
/// scroll position.
///
/// The page runs under the status bar and under the pill; a band the page's
/// own colour sits behind the clock so the time stays readable.
struct Page: View {
    @ObservedObject var tab: Tab
    /// The status bar's height: the page ignores the safe area, so it is told.
    var top: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            WebStage(page: tab.isBlank ? nil : tab.web)
                .background(Palette.ground)
                .ignoresSafeArea()
            Band(tint: tab.tint, height: top)
        }
        .overlay {
            if tab.waking {
                Card(tab: tab, top: top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: tab.waking)
    }
}

/// What a page looked like when it was last on screen: for walking past it,
/// and for a tab that hasn't been shown since launch.
struct Card: View {
    var tab: Tab?
    var top: CGFloat

    var body: some View {
        ZStack {
            Palette.ground
            if let image = tab?.snapshot {
                // Laid over the ground, not beside it: a picture never gets
                // to decide how big the card is.
                Color.clear.overlay(alignment: .top) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Text(tab?.label ?? "New tab")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 40)
            }
        }
        .clipped()
        .ignoresSafeArea()
        .overlay(alignment: .top) { Band(tint: tab?.tint, height: top) }
    }
}

/// The strip behind the status bar.
struct Band: View {
    var tint: UIColor?
    var height: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        colour
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
    }

    /// The page's colour when the clock can be read on it, the ground when it
    /// can't: the status bar's text follows the app's appearance, not the page.
    private var colour: Color {
        guard let tint else { return Palette.ground }
        var white: CGFloat = 0, alpha: CGFloat = 0
        let resolved = tint.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        guard resolved.getWhite(&white, alpha: &alpha), alpha > 0.9 else { return Palette.ground }
        let readable = scheme == .dark ? white < 0.4 : white > 0.6
        return readable ? Color(uiColor: resolved) : Palette.ground
    }
}

struct WebStage: UIViewRepresentable {
    let page: UIView?

    func makeUIView(context: Context) -> StageView { StageView() }

    func updateUIView(_ view: StageView, context: Context) {
        view.show(page)
    }
}

final class StageView: UIView {
    private weak var current: UIView?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let current, current.superview !== self, window != nil {
            addSubview(current)
        }
        current?.frame = bounds
    }

    func show(_ page: UIView?) {
        // Not "is it the same view" but "is it here": a web view can have only
        // one superview, and another stage asking for it takes it away.
        if let page, page.superview === self {
            current = page
            return
        }
        if page == nil, current == nil { return }

        current?.removeFromSuperview()
        current = page
        guard let page else { return }
        page.removeFromSuperview()
        page.frame = bounds
        addSubview(page)
        setNeedsLayout()
    }
}
