import SwiftUI

// The same palette as the Mac. Two apps that share a look should share the
// numbers that make it, not approximate each other. Each one is a white level
// for light and for dark, as on the Mac (Design.swift there).
enum Palette {
    static let ground = tone(1, 0.11)
    static let ink = tone(0.09, 0.93)
    static let muted = tone(0.55, 0.58)
    static let faint = tone(0.83, 0.32)
    static let hairline = tone(0.91, 0.20)
    static let wash = tone(0.937, 0.175)
    static let pinLive = tone(0.90, 0.21)
    static let hover = tone(0.965, 0.15)
    /// What shows between and behind pages.
    static let backdrop = tone(0.86, 0.04)

    static func tone(_ light: CGFloat, _ dark: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? dark : light, alpha: 1)
        })
    }
}

/// The curves everything moves on. Two sets: the Mac's own (the default),
/// with a little bounce, and a smoother set chosen in Settings that moves the
/// way Safari does: iOS's own springs, critically damped, so things come to
/// rest without overshooting and wobbling back.
enum Motion {
    /// Settings' Smoother animations. Read straight from the defaults, so it
    /// can be asked from anywhere, on any thread.
    static var smooth: Bool { Store.settings.bool(forKey: Prefs.smoothKey) }

    /// The classic curve, or the smooth one when that's chosen.
    static func pick(_ classic: Animation, smooth new: Animation) -> Animation {
        smooth ? new : classic
    }

    /// Things that move between two places.
    static var glide: Animation {
        pick(.spring(response: 0.34, dampingFraction: 0.82), smooth: .spring(duration: 0.42, bounce: 0))
    }
    /// Things that arrive or leave.
    static var settle: Animation {
        pick(.spring(response: 0.30, dampingFraction: 0.86), smooth: .spring(duration: 0.38, bounce: 0))
    }
    /// Things that make room for each other, with a little give: cards
    /// closing up the gap one left.
    static var bouncy: Animation {
        pick(.spring(response: 0.38, dampingFraction: 0.74), smooth: .spring(duration: 0.40, bounce: 0.08))
    }
    /// A thing picked up under the finger, or set back down (smooth set).
    static let grab = Animation.spring(duration: 0.28, bounce: 0)
    /// Something thrown off the screen, fast, and gone (smooth set).
    static let toss = Animation.spring(duration: 0.26, bounce: 0)
    /// The page shrinking to its card and growing back, without a bounce:
    /// Safari's tab overview takes a little longer than the Mac's.
    static var lift: Spring {
        smooth ? Spring(duration: 0.46, bounce: 0) : Spring(response: 0.38, dampingRatio: 1)
    }
    /// Fades.
    static var quick: Animation {
        pick(.easeOut(duration: 0.14), smooth: .easeInOut(duration: 0.2))
    }

    /// A glide that starts at the finger's speed. `velocity` in points per
    /// second, `distance` what is left to travel: SwiftUI wants the speed as
    /// a share of the distance.
    static func thrown(velocity: CGFloat, distance: CGFloat) -> Animation {
        guard abs(distance) > 0.5 else { return glide }
        let share = max(-12, min(12, velocity / distance))
        let spring = smooth ? Spring(duration: 0.42, bounce: 0) : Spring(response: 0.34, dampingRatio: 0.86)
        return .interpolatingSpring(spring, initialVelocity: share)
    }

    /// Where a flick would come to rest: the iOS rule, decelerating at the
    /// scroll view's normal rate.
    static func project(_ velocity: CGFloat) -> CGFloat {
        let rate: CGFloat = 0.998
        return velocity / 1000 * rate / (1 - rate)
    }
}

/// The column beside the camera on a screen that has one at its side (the
/// iPhone Duo's outer screen, and its inner one held sideways): the buttons
/// live there, by the hand, and the page runs the whole width under it.
struct Rail: Equatable {
    var width: CGFloat = 0
    /// The column is on the left (the screen turned the other way).
    var leading = false

    var on: Bool { width > 40 }

    static func of(_ insets: EdgeInsets) -> Rail {
        if insets.trailing > 40 { return Rail(width: insets.trailing) }
        if insets.leading > 40 { return Rail(width: insets.leading, leading: true) }
        return Rail()
    }

    /// Where a round button sits across the column.
    var inset: CGFloat { (width - Metrics.pill) / 2 }
    var edge: Edge.Set { leading ? .leading : .trailing }
    var alignment: Alignment { leading ? .bottomLeading : .bottomTrailing }
    /// Outward, toward the column's edge.
    var out: CGFloat { leading ? -1 : 1 }
}

enum Metrics {
    /// The pill at rest, and folded while a page scrolls.
    static let pill: CGFloat = 48
    static let pillFolded: CGFloat = 30
    /// Room left at the foot of a page so its end can scroll clear of the pill.
    static let pillRoom: CGFloat = 64
    /// How much of the screen's foot the pill holds, the home bar included:
    /// what pages are told is covered, and how tall the blur under the pill
    /// is. One number for both, and it doesn't change when the pill folds, so
    /// a page's fixed button never moves while the page scrolls and never
    /// sits under the pill or the blur.
    static func foot(_ safeBottom: CGFloat) -> CGFloat { safeBottom + 8 + pill + 14 }
    /// The same, with the bar folded to Safari's small capsule.
    static func footFolded(_ safeBottom: CGFloat) -> CGFloat { safeBottom + pillFolded + 6 }

    /// Between two pages while they're being walked.
    static let gap: CGFloat = 12
}
