import SwiftUI

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

/// An almost-closed ring, turning. Turned by Core Animation: a SwiftUI
/// animation that repeats forever redraws on the main thread every frame
/// (the Mac measured it at 18 % of a core for the field's breath).
struct Ring: UIViewRepresentable {
    var size: CGFloat = 12

    func makeUIView(context: Context) -> RingView { RingView(size: size) }
    func updateUIView(_ view: RingView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RingView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

final class RingView: UIView {
    private let ring = CAShapeLayer()
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        ring.fillColor = nil
        ring.lineWidth = 1.6
        ring.lineCap = .round
        ring.strokeEnd = 0.78
        layer.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.8, dy: 0.8)).cgPath
        ring.strokeColor = UIColor(Palette.muted).resolvedColor(with: traitCollection)
            .withAlphaComponent(0.7).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, ring.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = Double.pi * 2
        turn.duration = 0.85
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: "turn")
    }
}

/// The Mac's slow breath under the field on an empty tab: a soft shadow that
/// swells and settles, 2.6 s each way. Core Animation, for the same reason
/// as the ring.
struct Breath: UIViewRepresentable {
    var radius: CGFloat = 18

    func makeUIView(context: Context) -> BreathView { BreathView(radius: radius) }
    func updateUIView(_ view: BreathView, context: Context) {}
}

final class BreathView: UIView {
    private let glow = CALayer()
    private let radius: CGFloat

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        glow.shadowRadius = 26
        glow.shadowOffset = .zero
        glow.shadowOpacity = 0.07
        layer.addSublayer(glow)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glow.frame = bounds
        glow.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: radius).cgPath
        glow.shadowColor = UIColor(Palette.ink).resolvedColor(with: traitCollection).cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, glow.animation(forKey: "breath") == nil,
              !UIAccessibility.isReduceMotionEnabled
        else { return }
        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.fromValue = 0.97
        swell.toValue = 1.03
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.65
        fade.toValue = 1
        let breath = CAAnimationGroup()
        breath.animations = [swell, fade]
        breath.duration = 2.6
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.isRemovedOnCompletion = false
        glow.add(breath, forKey: "breath")
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

// MARK: - gestures

// UIKit's recognizers, for what SwiftUI's gestures can't say: a pan that knows
// its speed and its axis, a tap that gives way to it, and a hold that gives way
// to both.

struct Pan: UIGestureRecognizerRepresentable {
    let action: (UIPanGestureRecognizer) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        action(recognizer)
    }
}

struct Tap: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        UITapGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
}

struct Hold: UIGestureRecognizerRepresentable {
    let action: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer()
        hold.minimumPressDuration = 0.35
        return hold
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        if recognizer.state == .began { action() }
    }
}
