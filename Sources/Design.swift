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

/// The Mac's three curves, and the one way a gesture hands its speed to them.
enum Motion {
    /// Things that move between two places.
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
    /// Things that arrive or leave.
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.86)
    /// Fades.
    static let quick = Animation.easeOut(duration: 0.14)

    /// A glide that starts at the finger's speed. `velocity` in points per
    /// second, `distance` what is left to travel: SwiftUI wants the speed as
    /// a share of the distance.
    static func thrown(velocity: CGFloat, distance: CGFloat) -> Animation {
        guard abs(distance) > 0.5 else { return glide }
        let share = max(-12, min(12, velocity / distance))
        return .interpolatingSpring(
            Spring(response: 0.34, dampingRatio: 0.86), initialVelocity: share
        )
    }

    /// Where a flick would come to rest: the iOS rule, decelerating at the
    /// scroll view's normal rate.
    static func project(_ velocity: CGFloat) -> CGFloat {
        let rate: CGFloat = 0.998
        return velocity / 1000 * rate / (1 - rate)
    }
}

enum Metrics {
    /// The pill at rest, and folded while a page scrolls.
    static let pill: CGFloat = 48
    static let pillFolded: CGFloat = 30
    /// Room left at the foot of a page so its end can scroll clear of the pill.
    static let pillRoom: CGFloat = 64
    /// Between two pages while they're being walked.
    static let gap: CGFloat = 12
}
