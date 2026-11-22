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
    /// Something of the app's is over the top of the page (the sheet, the
    /// field): the clock goes back to the app's own colour.
    var covered = false
    @Environment(\.colorScheme) private var scheme

    /// What sits behind the clock: the page's theme-color, else its own
    /// background; nothing while a blank tab or an error page shows.
    private var behindClock: UIColor? {
        guard !covered, !tab.isBlank, tab.failure == nil else { return nil }
        // The page's own background, as Safari samples it; its theme-color
        // only when it has none.
        return tab.ground ?? tab.tint
    }

    private var statusKey: String {
        "\(behindClock.map { "\($0)" } ?? "none")|\(scheme == .dark)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            WebStage(page: tab.isBlank ? nil : tab.web)
                .background(Palette.ground)
                .ignoresSafeArea()
            Band(tint: tab.tint, height: top)
        }
        .overlay {
            if let failure = tab.failure { Failed(tab: tab, failure: failure) }
        }
        .overlay(alignment: .top) {
            // Pull to refresh, said: an arrow that turns as the page is
            // pulled, and stands when letting go will reload.
            if tab.pull > 0 {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .rotationEffect(.degrees(Double(tab.pull) * 270))
                    .frame(width: 36, height: 36)
                    .glass(Circle(), else: Palette.wash)
                    .opacity(Double(min(1, tab.pull * 1.5)))
                    .scaleEffect(tab.pull >= 1 ? 1.1 : 0.8 + 0.2 * tab.pull)
                    .padding(.top, top + 10)
                    .animation(Motion.quick, value: tab.pull >= 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if tab.waking {
                Card(tab: tab, top: top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: tab.waking)
        .onChange(of: statusKey, initial: true) { _, _ in
            StatusBar.follow(behindClock, scheme: scheme == .dark ? .dark : .light)
        }
        .onDisappear { StatusBar.follow(nil, scheme: scheme == .dark ? .dark : .light) }
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
                // to decide how big the card is. The picture is the whole
                // screen, so filling it scales it evenly and crops nothing.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Text(tab?.label ?? String(localized: "New tab"))
                    .font(.scaled(15))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 40)
            }
        }
        .clipped()
        .ignoresSafeArea()

    }
}

/// Behind the status bar: the page's own colour, so the page reads as
/// running up to the top edge. Where the clock wouldn't read on it (a white
/// page in dark mode, a black one in light), a soft fade of the app's ground
/// under the clock instead of a hard band.
struct Band: View {
    var tint: UIColor?
    var height: CGFloat

    var body: some View {
        // As in Safari: nothing of the app's behind the clock. The page shows
        // there itself (at the top, its own background above its content);
        // the clock's text turns light or dark to read on it (StatusBar).
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .allowsHitTesting(false)
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

/// The page as it was the instant it started to move, exactly as it was on
/// screen: its picture, and the band behind the clock over it, at the size
/// they had, so the two shrink and slide as one thing and nothing appears or
/// goes when the motion ends.
struct Still: View {
    let image: UIImage?
    var tint: UIColor?
    var top: CGFloat
    /// How much of the band still shows: none once the page has shrunk
    /// away from the clock, where it has nothing left to do.
    var band: CGFloat = 1

    var body: some View {
        ZStack(alignment: .top) {
            Palette.ground
            if let image {
                // The screen's own width, the picture's own proportions,
                // from the top: never filled into a frame of another shape,
                // which scaled it up and cropped it.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            // The band the live page has behind the clock, part of the card:
            // it shrinks and slides with the page and is there when the live
            // page takes over again, so nothing pops in at the end.
            // The fade the live page has under the clock, only while the
            // card still sits where the page does.
            if band > 0.01 {
                Band(tint: tint, height: top)
                    .opacity(Double(band))
            }
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

/// Where a page couldn't be opened: what happened, and Try Again.
struct Failed: View {
    @ObservedObject var tab: Tab
    let failure: Tab.Failure

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.scaled(26, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text("Can't open this page")
                    .font(.scaled(19, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(failure.reason)
                    .font(.scaled(15))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                Text(Address.pretty(failure.url))
                    .font(.scaled(13))
                    .foregroundStyle(Palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    Feel.tick()
                    tab.failure = nil
                    tab.go(to: failure.url)
                } label: {
                    Text("Try Again")
                        .font(.scaled(15, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .glass(Capsule(), interactive: true, else: Palette.wash)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 40)
        }
    }
}

/// The page between full screen and its card: as wide as the screen and
/// cut from the top to the card's shape, then scaled and moved onto the
/// card, its corners rounding as it goes. At 0 it is the page; at 1 it is
/// the card's picture, to the point.
struct Zoom: View, Animatable {
    let image: UIImage?
    var tint: UIColor?
    var top: CGFloat
    /// Animated as one number, so every part of it (size, crop, corners,
    /// place) moves together on the same curve, never apart.
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    let screen: CGSize
    let target: CGRect

    var body: some View {
        let p = max(0, min(1, progress))
        let end = target.width / max(1, screen.width)
        let scale = 1 + (end - 1) * p
        // The card's height, at the screen's width.
        let cut = target.height / max(0.01, end)
        let height = screen.height + (cut - screen.height) * p
        let radius = (18 * p) / max(0.01, scale)
        ZStack(alignment: .top) {
            Palette.ground
            if let image, image.size.width > 0 {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: screen.width, height: screen.width * image.size.height / image.size.width)
            }
            if p < 0.25 {
                Band(tint: tint, height: top).opacity(Double(1 - p * 4))
            }
        }
        .frame(width: screen.width, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(0.14 * Double(p)), radius: 12 / max(0.01, scale), y: 4 / max(0.01, scale))
        .scaleEffect(scale, anchor: .topLeading)
        .offset(x: target.minX * p, y: target.minY * p)
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        // Only `progress` moves: left to animate on their own, the size,
        // scale and place slid from the last card's to the new one's.
        .transaction { $0.animation = nil }
    }
}
