import SwiftUI

// The same palette as the Mac. Two apps that share a look should share the
// numbers that make it, not approximate each other.
enum Palette {
    static let ground = Color(white: 1)
    static let ink = Color(red: 0.09, green: 0.09, blue: 0.09)
    static let muted = Color(red: 0.55, green: 0.55, blue: 0.55)
    static let faint = Color(red: 0.83, green: 0.83, blue: 0.83)
    static let hairline = Color(red: 0.91, green: 0.91, blue: 0.91)
    static let wash = Color(red: 0.937, green: 0.937, blue: 0.937)
    static let hover = Color(red: 0.965, green: 0.965, blue: 0.965)
}

enum Motion {
    static let glide = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.14)
}
