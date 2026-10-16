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
        // No band laid over it: the picture has the page's own top, and a
        // band of fixed height would end up on the page's content as the
        // picture shrinks.
        Holder(view: view)
            .background(Palette.ground)
            .ignoresSafeArea()
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

/// A blur that grows toward the bottom edge, from nothing to its strongest at
/// the very edge, with no tint of its own: the page shows through, only
/// softer. UIKit has no public variable blur, so it is built from a few
/// plain blurs of rising strength, each held part-way through its animation
/// (the radius is what changes along the way; at these fractions the
/// material's tint stays out of it) and each masked to a band that overlaps
/// the next. With Reduce Transparency on, nothing: the page as it is.
struct Fade: UIViewRepresentable {
    func makeUIView(context: Context) -> FadeView { FadeView() }
    func updateUIView(_ view: FadeView, context: Context) {}
}

final class FadeView: UIView {
    /// How far along each layer's blur is held, and where its band starts
    /// (0 the top of the fade, 1 the bottom edge).
    private static let steps: [(strength: CGFloat, from: CGFloat)] = [
        (0.05, 0.0), (0.1, 0.3), (0.18, 0.55), (0.3, 0.8),
    ]

    private var layers: [(view: UIVisualEffectView, mask: Gradient)] = []
    private var animators: [UIViewPropertyAnimator] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for step in Self.steps {
            let view = UIVisualEffectView(effect: nil)
            // A mask view, not a mask layer: a visual effect view drops its
            // blur under a layer mask.
            let mask = Gradient()
            let gradient = mask.layer as! CAGradientLayer
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
            // Each band fades in over the step above it, so no edge shows.
            let start = max(0, step.from - 0.25)
            gradient.locations = [NSNumber(value: Double(start)), NSNumber(value: Double(min(1, step.from + 0.15)))]
            view.mask = mask
            addSubview(view)
            layers.append((view, mask))
        }
        hold()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(hold), name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        // An animator held part-way loses its place when the app comes back.
        center.addObserver(self, selector: #selector(hold), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func hold() {
        animators.forEach { $0.stopAnimation(true) }
        animators = []
        let solid = UIAccessibility.isReduceTransparencyEnabled
        for (index, layer) in layers.enumerated() {
            layer.view.effect = nil
            layer.view.isHidden = solid
            guard !solid else { continue }
            let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) {
                layer.view.effect = UIBlurEffect(style: .regular)
            }
            animator.pausesOnCompletion = true
            animator.fractionComplete = Self.steps[index].strength
            animators.append(animator)
        }
    }

    /// Held blurs set up before the view is in a window don't take: they are
    /// set up again once it is.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { hold() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            layer.view.frame = bounds
            layer.mask.frame = layer.view.bounds
        }
        CATransaction.commit()
    }

    deinit {
        animators.forEach { $0.stopAnimation(true) }
    }

    final class Gradient: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
    }
}
