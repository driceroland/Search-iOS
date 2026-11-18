import SwiftUI

// The first launch: three screens on what can't be seen, the gestures, and
// then never again. Each says one thing, with the pill drawn doing it.

struct Welcome: View {
    var done: () -> Void
    @State private var page = 0

    private struct Step: Identifiable {
        let id: Int
        let symbol: String
        let title: LocalizedStringKey
        let words: LocalizedStringKey
    }

    private let steps = [
        Step(id: 0, symbol: "capsule", title: "One pill",
             words: "Tap it to search or type an address. Hold it for the page's menu: back, share, find, text size, pin."),
        Step(id: 1, symbol: "arrow.left.and.right", title: "Slide it",
             words: "Sideways to go from tab to tab, past the last for a new one. Up to see every tab."),
        Step(id: 2, symbol: "hand.draw", title: "Your tabs",
             words: "In the list, swipe a tab right to pin it, left to close it. Hold it for more, or to move it."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(steps) { step in
                    VStack(spacing: 22) {
                        Spacer()
                        Image(systemName: step.symbol)
                            .font(.scaled(44, weight: .light))
                            .foregroundStyle(Palette.ink)
                            .frame(width: 120, height: 120)
                            .glass(Circle(), else: Palette.wash)
                        Text(step.title)
                            .font(.scaled(26, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text(step.words)
                            .font(.scaled(16))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                        Spacer()
                        Spacer()
                    }
                    .tag(step.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                Feel.tick()
                if page < steps.count - 1 {
                    withAnimation(Motion.glide) { page += 1 }
                } else {
                    done()
                }
            } label: {
                Text(page < steps.count - 1 ? LocalizedStringKey("Next") : LocalizedStringKey("Start browsing"))
                    .font(.scaled(16, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .glass(Capsule(), interactive: true, else: Palette.wash)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Palette.ground.ignoresSafeArea())
    }
}
