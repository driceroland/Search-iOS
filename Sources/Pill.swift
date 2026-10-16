import SwiftUI

/// The one thing on a page: where you are, and how many pages are open.
///
/// At the bottom because that is where a thumb is. Every way in starts here:
/// tap to type, drag sideways to walk the tabs, drag up for all of them, hold
/// for the page's own menu. While the page scrolls it folds down to the site's
/// name, following the page rather than a timer, and a tap opens it again.
struct Pill: View {
    @ObservedObject var tab: Tab
    @ObservedObject var chrome: Chrome
    let count: Int
    /// Shown instead of this page's site while a walk is far enough to land
    /// somewhere else.
    var heading: String?
    let space: Namespace.ID

    var type: () -> Void
    var tabs: () -> Void
    var hold: () -> Void
    var walk: (CGFloat) -> Void
    var walked: (CGFloat, CGFloat) -> Void
    var lift: (CGFloat) -> Void
    var lifted: (CGFloat, CGFloat) -> Void

    private enum Axis { case none, walk, lift, ignored }
    @State private var axis: Axis = .none

    var body: some View {
        let f = chrome.fold
        HStack(spacing: 8 * (1 - f)) {
            address(f)
            counter(f)
        }
        .padding(.horizontal, 16 + 70 * f)
        .padding(.bottom, 8 - 8 * f)
        .contentShape(Rectangle())
        .gesture(Pan(action: pan))
        .gesture(Hold { if chrome.fold < 0.5 { Feel.nudge(); hold() } })
    }

    private func address(_ f: CGFloat) -> some View {
        HStack(spacing: 7) {
            if heading == nil, !tab.isBlank {
                if tab.loading {
                    Ring()
                } else {
                    Mark(icon: tab.icon, letter: tab.letter, size: 15)
                }
            }
            Text(heading ?? tab.short)
                .font(.system(size: 15.5))
                .foregroundStyle(tab.isBlank && heading == nil ? Palette.muted : Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .id(heading ?? tab.short)
                .transition(.opacity)
        }
        .scaleEffect(1 - 0.2 * f)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.pill - (Metrics.pill - Metrics.pillFolded) * f)
        .background {
            Glass(shape: Capsule(), shadow: 1 - f)
                .overlay(alignment: .bottom) {
                    // The loading line lives in the pill, along its foot,
                    // where the eye already is.
                    Loading(tab: tab).clipShape(Capsule())
                }
                .matchedGeometryEffect(id: "pill", in: space)
        }
        .contentShape(Capsule())
        .gesture(Tap {
            if chrome.fold > 0.5 {
                chrome.unfold(animated: true)
            } else {
                type()
            }
        })
        .animation(Motion.quick, value: heading)
    }

    private func counter(_ f: CGFloat) -> some View {
        Text("\(count)")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.ink)
            .contentTransition(.numericText())
            .frame(width: Metrics.pill * (1 - f), height: Metrics.pill)
            .background(Glass(shape: Circle(), shadow: 1))
            .scaleEffect(1 - 0.5 * f)
            .opacity(1 - f * 1.6)
            .frame(width: Metrics.pill * (1 - f))
            .contentShape(Circle())
            .gesture(Tap { tabs() })
            .allowsHitTesting(f < 0.5)
            .animation(Motion.quick, value: count)
    }

    private func pan(_ recognizer: UIPanGestureRecognizer) {
        let moved = recognizer.translation(in: nil)
        let speed = recognizer.velocity(in: nil)
        switch recognizer.state {
        case .began:
            axis = .none
            if chrome.fold > 0 { chrome.unfold(animated: true) }
        case .changed:
            // One gesture, one direction: whichever the finger set off in.
            // Decided on the first real movement — a pan can begin at zero.
            if axis == .none, max(abs(moved.x), abs(moved.y)) > 3 {
                axis = abs(moved.x) > abs(moved.y) ? .walk : (moved.y < 0 ? .lift : .ignored)
            }
            switch axis {
            case .walk: walk(moved.x)
            case .lift: lift(moved.y)
            case .none, .ignored: break
            }
        case .ended, .cancelled, .failed:
            switch axis {
            case .walk: walked(moved.x, speed.x)
            case .lift: lifted(moved.y, speed.y)
            case .none, .ignored: break
            }
            axis = .none
        default:
            break
        }
    }
}

/// The pill's surface: the ground, a little see-through over a blur of the
/// page, so the page reads as running on under it and the address still reads
/// in the light and in the dark.
struct Glass<S: InsettableShape>: View {
    let shape: S
    var shadow: CGFloat = 1

    var body: some View {
        shape
            .fill(.regularMaterial)
            .overlay(shape.fill(Palette.ground.opacity(0.72)))
            .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.08 * shadow), radius: 20, y: 6)
    }
}

/// How far the page has come, as a hairline along the pill's foot.
private struct Loading: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Palette.ink.opacity(0.55))
                .frame(width: geo.size.width * tab.progress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .animation(.easeOut(duration: 0.22), value: tab.progress)
        }
        .opacity(tab.loading ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: tab.loading)
        .allowsHitTesting(false)
    }
}

/// The page's own menu, out of the held pill.
struct Held: View {
    @ObservedObject var tab: Tab
    var pinned: Bool
    var done: () -> Void
    var pin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                arrow("chevron.left", enabled: tab.canGoBack) { tab.back() }
                arrow("chevron.right", enabled: tab.canGoForward) { tab.forward() }
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            item("arrow.clockwise", "Reload") { tab.reload() }
            line
            item(pinned ? "pin.slash" : "pin", pinned ? "Unpin" : "Pin", action: pin)
        }
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 30, y: 10)
        .padding(.horizontal, 16)
    }

    private var line: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.leading, 54)
    }

    private func arrow(_ name: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            action()
            done()
        } label: {
            Image(systemName: name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Palette.ink : Palette.faint)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func item(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Feel.tick()
            action()
            done()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .frame(width: 22)
                Text(title).font(.system(size: 16))
                Spacer()
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 18)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressed())
    }
}

/// A row that greys while a finger is on it, the way the Mac's rows do under
/// the pointer.
struct Pressed: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.hover : Color.clear)
    }
}
