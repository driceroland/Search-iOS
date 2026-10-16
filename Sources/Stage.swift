import SwiftUI
import WebKit

/// The one place a page is allowed to be. Tabs hand their web view over when
/// they become the live one and get it back untouched — no reload, no lost
/// scroll position.
struct Page: View {
    @ObservedObject var tab: Tab

    var body: some View {
        WebStage(page: tab.isBlank ? nil : tab.web)
            .overlay(alignment: .top) { Progress(tab: tab) }
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

/// The loading line: one hairline across the top, and gone.
private struct Progress: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(Palette.ink.opacity(0.7))
                .frame(width: geo.size.width * tab.progress)
                .animation(.easeOut(duration: 0.22), value: tab.progress)
        }
        .frame(height: 2)
        .opacity(tab.loading ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: tab.loading)
        .allowsHitTesting(false)
    }
}
