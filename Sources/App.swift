import SwiftUI

// A page, and a bar at the bottom. Everything else is summoned and put away.

@main
struct SearchApp: App {
    @StateObject private var browser = Browser()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let number = Mock.screen {
                MockScreen(number: number)
            } else {
                ContentView(browser: browser)
                    .preferredColorScheme(.light)
            }
            #else
            ContentView(browser: browser)
                .preferredColorScheme(.light)
            #endif
        }
    }
}

struct ContentView: View {
    @ObservedObject var browser: Browser

    @Namespace private var space

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                if let tab = browser.active {
                    Page(tab: tab)
                } else {
                    Palette.ground
                }
                Bar(browser: browser)
            }

            if browser.showingTabs {
                Rows(browser: browser, space: space)
            }

            if browser.editing {
                Field(browser: browser)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: browser.editing)
    }
}
