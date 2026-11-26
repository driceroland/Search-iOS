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
    /// Which safe area edges the page runs under: not the sides beside a
    /// Duo's rail, which keeps its own band.
    var edges: Edge.Set = .all
    @Environment(\.colorScheme) private var scheme

    /// What sits behind the clock: the page's theme-color, else its own
    /// background; nothing while a blank tab or an error page shows.
    private var behindClock: UIColor? {
        guard !covered, !tab.isBlank, tab.failure == nil else { return nil }
        // Beside a Duo's rail the clock sits on the rail, not on the page.
        return edges == .all ? tab.behindClock : tab.railColour
    }

    private var statusKey: String {
        "\(behindClock.map { "\($0)" } ?? "none")|\(scheme == .dark)"
    }

    var body: some View {
        ZStack(alignment: .top) {
            WebStage(page: tab.isBlank ? nil : tab.web)
                .background(Palette.ground)
                .ignoresSafeArea(edges: edges)
            Band(tint: tab.isBlank || tab.failure != nil ? nil : tab.behindClock, height: top)
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
    var edges: Edge.Set = .all

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
        .ignoresSafeArea(edges: edges)

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
        // As in Safari: the colour of what's at the top of the page, carried
        // up behind the clock, so the page's bar reads as running to the
        // edge; the clock's text turns light or dark to read on it.
        (tint.map { Color(uiColor: $0) } ?? Color.clear)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .animation(.easeOut(duration: 0.2), value: tint)
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
        // A page in element full screen is WebKit's, in a window of its own,
        // until WebKit hands it back here: taken back now, it left that
        // window black.
        if let current, Self.fullscreen(current) { return }
        if let current, current.superview !== self, window != nil {
            addSubview(current)
        }
        current?.frame = bounds
    }

    private static func fullscreen(_ view: UIView) -> Bool {
        guard let web = view as? WKWebView else { return false }
        return web.fullscreenState != .notInFullscreen || VideoCover.shared.holds(web)
    }

    func show(_ page: UIView?) {
        // Not "is it the same view" but "is it here": a web view can have only
        // one superview, and another stage asking for it takes it away.
        if let page, page.superview === self {
            current = page
            return
        }
        if page == nil, current == nil { return }
        if let page, Self.fullscreen(page) {
            current = page
            return
        }

        current?.removeFromSuperview()
        current = page
        guard let page else { return }
        page.removeFromSuperview()
        page.frame = bounds
        addSubview(page)
        setNeedsLayout()
    }
}

/// A site's own video player over the whole screen where WebKit won't put
/// it there itself (SitePlayer pins it over the page): the page goes into
/// a window of its own, the way WebKit's own full screen takes it, with no
/// clock, no pill and no home bar, and the phone free to turn. Back to its
/// stage, untouched, when the player leaves full screen.
@MainActor
final class VideoCover {
    static let shared = VideoCover()

    private var window: UIWindow?
    private weak var web: WKWebView?
    private weak var home: UIView?
    private var insets = UIEdgeInsets.zero

    func holds(_ view: UIView) -> Bool { window != nil && view === web }

    func enter(_ web: WKWebView, wide: Bool) {
        guard window == nil, let scene = web.window?.windowScene else { return }
        let controller = CoverController()
        controller.close = { [weak self, weak web] in
            web?.evaluateJavaScript(SitePlayer.exit)
            self?.exit()
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = controller
        self.window = window
        self.web = web
        home = web.superview
        // Nothing of the app's covers it now.
        insets = web.scrollView.contentInset
        if #available(iOS 26.0, *) { web.obscuredContentInsets = .zero }
        web.scrollView.contentInset = .zero
        web.setMinimumViewportInset(.zero, maximumViewportInset: .zero)
        controller.hold(web)
        window.makeKeyAndVisible()
        Shortcuts.turning = true
        // A wide video turns the screen on its side, as the iPhone's own
        // player does; turned back by hand, it stays turned back.
        if wide, UIDevice.current.userInterfaceIdiom == .phone, !Shortcuts.onPad {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
    }

    func exit() {
        guard let window else { return }
        let web = self.web
        self.window = nil
        self.web = nil
        web?.removeFromSuperview()
        window.isHidden = true
        if let web { web.scrollView.contentInset = insets }
        // The stage takes its page back as it lays itself out.
        home?.setNeedsLayout()
        home?.layoutIfNeeded()
        Shortcuts.turning = false
        Shortcuts.browser?.cover()
    }
}

/// The cover's one screen: the page, black around it, and a close button
/// that steps aside until the screen is touched.
final class CoverController: UIViewController, UIGestureRecognizerDelegate {
    var close: (() -> Void)?
    private let button = UIButton(type: .system)
    private var fade: DispatchWorkItem?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
    }

    func hold(_ page: UIView) {
        loadViewIfNeeded()
        page.frame = view.bounds
        page.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(page, at: 0)

        var look = UIButton.Configuration.filled()
        look.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        look.baseBackgroundColor = UIColor(white: 0.15, alpha: 0.7)
        look.baseForegroundColor = .white
        look.cornerStyle = .capsule
        button.configuration = look
        button.accessibilityLabel = String(localized: "Exit Full Screen")
        button.addAction(UIAction { [weak self] _ in self?.close?() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])

        let touch = UITapGestureRecognizer(target: self, action: #selector(touched))
        touch.cancelsTouchesInView = false
        touch.delegate = self
        view.addGestureRecognizer(touch)
        show()
    }

    @objc private func touched() { show() }

    private func show() {
        UIView.animate(withDuration: 0.2) { self.button.alpha = 1 }
        fade?.cancel()
        let later = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.4) { self?.button.alpha = 0 }
        }
        fade = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: later)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}

/// What a page's player says about full screen (SitePlayer).
final class PlayerRelay: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let full = body["full"] as? Bool else { return }
        let web = message.webView
        MainActor.assumeIsolated {
            if full, let web, message.frameInfo.isMainFrame {
                VideoCover.shared.enter(web, wide: body["wide"] as? Bool ?? false)
            } else if !full, let web, VideoCover.shared.holds(web) {
                VideoCover.shared.exit()
            }
        }
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
        // Light: the page under the pill is still the page, readable and
        // tappable, only softened toward the edge.
        (0.03, 0.0), (0.06, 0.35), (0.11, 0.6), (0.18, 0.85),
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
    /// Where the page starts across: past the Duo's rail when it is on the
    /// left.
    var x0: CGFloat = 0
    let target: CGRect
    /// Whose page it is: its name comes down under it, to where it sits
    /// under the card.
    var tab: Tab?
    /// Large cards wear their name over them, left-aligned.
    var nameAbove = false

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
        .offset(x: x0 + (target.minX - x0) * p, y: target.minY * p)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if let tab {
                // At the card's own width from the start, so its words are
                // cut once and never again: re-cut on every frame as the
                // width changed, they jumped sideways while going down.
                if nameAbove {
                    CardName(tab: tab, live: true)
                        .frame(width: target.width, height: 30, alignment: .leading)
                        .offset(x: x0 + (target.minX - x0) * p, y: target.minY * p - 30)
                        .opacity(Double(max(0, min(1, (p - 0.15) / 0.6))))
                } else {
                CardName(tab: tab, live: true)
                    .frame(width: target.width)
                    .offset(x: x0 + (target.minX - x0) * p + (screen.width * scale - target.width) / 2,
                            y: target.minY * p + height * scale + 7)
                    .opacity(Double(max(0, min(1, (p - 0.15) / 0.6))))
                }
            }
        }
        // Only `progress` moves: left to animate on their own, the size,
        // scale and place slid from the last card's to the new one's.
        .transaction { $0.animation = nil }
    }
}
