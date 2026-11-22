import SwiftUI
import Combine

// Handoff: the page on screen, offered to the same person's Mac, and the page
// on their Mac taken up here. Not sync: nothing is stored or sent anywhere;
// Apple's Handoff passes one address between two devices signed in to the
// same Apple Account, nearby, and only when the person picks it up.
//
// On unless it's turned off in Settings. A private tab is never offered.

enum Handoff {
    /// The kind of activity both Searches offer and take up. With no Search
    /// on the other side, the address opens in that device's own browser.
    static let browsing = "com.officecommun.search.browsing"

    /// What can be offered: an ordinary web page, nothing private.
    static func offers(_ url: URL?, private: Bool) -> URL? {
        guard !`private`, let url,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return nil }
        return url
    }

    /// An activity from the other device: Search's own, or a web page from
    /// another browser. Only web addresses are taken.
    static func address(in activity: NSUserActivity) -> URL? {
        guard let url = activity.webpageURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else { return nil }
        return url
    }
}

/// Offers the active tab's page while Handoff is on, following the tab
/// itself (a new page, a new title) as well as which tab is active.
@MainActor
final class Offering {
    private var activity: NSUserActivity?
    private var bag = Set<AnyCancellable>()

    init(_ browser: Browser, prefs: Prefs) {
        browser.$activeID
            // The id as it is being set: the published value arrives before
            // the property changes, so the tab is looked up by it.
            .map { [weak browser] id -> AnyPublisher<(URL?, String), Never> in
                guard let tab = browser?.tabs.first(where: { $0.id == id }) else { return Just((nil, "")).eraseToAnyPublisher() }
                // The values as they arrive, not read back from the tab: a
                // published property tells before it changes.
                let hidden = tab.isPrivate
                return tab.$address.combineLatest(tab.$title)
                    .map { address, title in (Handoff.offers(address, private: hidden), title) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .combineLatest(prefs.$handoff)
            .receive(on: RunLoop.main)
            .sink { [weak self] page, on in
                self?.offer(on ? page.0 : nil, title: page.1)
            }
            .store(in: &bag)
    }

    private func offer(_ url: URL?, title: String) {
        guard let url else {
            activity?.invalidate()
            activity = nil
            return
        }
        let activity = self.activity ?? NSUserActivity(activityType: Handoff.browsing)
        activity.webpageURL = url
        activity.title = title.isEmpty ? url.host() : title
        activity.isEligibleForHandoff = true
        // Handed to the other device and nowhere else.
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        activity.isEligibleForPublicIndexing = false
        activity.needsSave = true
        if self.activity == nil {
            self.activity = activity
            activity.becomeCurrent()
        }
    }
}
