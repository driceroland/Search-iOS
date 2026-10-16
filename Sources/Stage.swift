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

/// The page as it was the instant it started to move: a snapshot view of the
/// web view, which shrinks and slides without asking the page to lay itself
/// out again.
struct Still: View {
    let view: UIView?
    var tint: UIColor?
    var top: CGFloat

    var body: some View {
        Holder(view: view)
            .background(Palette.ground)
            .ignoresSafeArea()
            .overlay(alignment: .top) { Band(tint: tint, height: top) }
    }

    private struct Holder: UIViewRepresentable {
        let view: UIView?

        func makeUIView(context: Context) -> UIView {
            let holder = UIView()
            holder.clipsToBounds = true
            return holder
        }

        func updateUIView(_ holder: UIView, context: Context) {
            guard let view, view.superview !== holder else { return }
            holder.subviews.forEach { $0.removeFromSuperview() }
            view.frame = holder.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            holder.addSubview(view)
        }
    }
}

/// A blur that grows toward the bottom edge: two layers of material, each
/// masked by a gradient, the lighter one reaching higher. With Reduce
/// Transparency on, the ground instead, fading in the same way.
struct Fade: UIViewRepresentable {
    func makeUIView(context: Context) -> FadeView { FadeView() }
    func updateUIView(_ view: FadeView, context: Context) {}
}

final class FadeView: UIView {
    private let soft = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let firm = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let plain = UIView()
    private let softMask = CAGradientLayer()
    private let firmMask = CAGradientLayer()
    private let plainMask = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for layer in [softMask, firmMask, plainMask] {
            layer.startPoint = CGPoint(x: 0.5, y: 0)
            layer.endPoint = CGPoint(x: 0.5, y: 1)
        }
        softMask.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor]
        softMask.locations = [0, 0.45, 1]
        firmMask.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.8).cgColor]
        firmMask.locations = [0.35, 1]
        plainMask.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.92).cgColor]
        plainMask.locations = [0, 0.7]
        soft.layer.mask = softMask
        firm.layer.mask = firmMask
        plain.layer.mask = plainMask
        [soft, firm, plain].forEach(addSubview)
        update()
        NotificationCenter.default.addObserver(
            self, selector: #selector(update),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func update() {
        let solid = UIAccessibility.isReduceTransparencyEnabled
        soft.isHidden = solid
        firm.isHidden = solid
        plain.isHidden = !solid
        plain.backgroundColor = UIColor(Palette.ground)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [soft, firm, plain] { view.frame = bounds }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        softMask.frame = bounds
        firmMask.frame = bounds
        plainMask.frame = bounds
        CATransaction.commit()
    }
}
