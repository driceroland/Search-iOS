import SwiftUI
import WebKit

// The few things a person can change, kept in the app's own defaults. Each
// one says what it does in Settings. What most people want is on from the
// start (sync, Handoff, suggestions, locked private tabs); the rest waits.

enum Look: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Same as iPhone")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Put on every window, so the app and every sheet over it follow it at
    /// once, back to the iPhone's own included. (SwiftUI's preferred scheme
    /// doesn't let go of a sheet when it goes back to "none".)
    @MainActor func apply() {
        let style: UIUserInterfaceStyle = switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

/// How long a tab may be left alone before it closes by itself.
enum AutoClose: String, CaseIterable, Identifiable {
    case never, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return String(localized: "Never")
        case .day: return String(localized: "After a day")
        case .week: return String(localized: "After a week")
        case .month: return String(localized: "After a month")
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

/// Which player a video goes full screen in: the iPhone's own (AVPlayer),
/// the site's own player, or the site's own on the sites chosen for it.
enum VideoPlayer: String, CaseIterable, Identifiable {
    case native, website, chosen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .native: return String(localized: "iPhone player")
        case .website: return String(localized: "Website's player")
        case .chosen: return String(localized: "Website's player on chosen sites")
        }
    }
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private let store = Store.settings

    /// Light, dark, or whatever the iPhone is: the Mac's default.
    @Published var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            Sync.shared.put("settings", shared)
        }
    }

    @Published var engine: Engine {
        didSet {
            store.set(engine.rawValue, forKey: "search.engine")
            Sync.shared.put("settings", shared)
        }
    }

    /// A search address of one's own, with %s where the words go.
    @Published var customEngine: String {
        didSet {
            store.set(customEngine, forKey: "search.custom")
            Sync.shared.put("settings", shared)
        }
    }

    /// The Mac's custom engine suggestions address, kept to be sent back
    /// untouched (see SharedSettings.suggest).
    var customSuggest: String? {
        get { store.string(forKey: "search.custom.suggest") }
        set { store.set(newValue, forKey: "search.custom.suggest") }
    }

    /// The ad blocker, on as on the Mac.
    @Published var shield: Bool {
        didSet { Shield.shared.enabled = shield }
    }

    /// Offer the page on screen to one's own Mac, and take up the Mac's.
    /// On unless turned off: it's Apple's own, between one's own devices.
    @Published var handoff: Bool {
        didSet { store.set(handoff, forKey: "handoff") }
    }

    /// Tabs not looked at for a while close by themselves. Off until chosen.
    @Published var autoClose: AutoClose {
        didSet { store.set(autoClose.rawValue, forKey: "tabs.autoclose") }
    }

    /// Private tabs ask for Face ID when Search comes back. On, as in Safari.
    @Published var lockPrivate: Bool {
        didSet { store.set(lockPrivate, forKey: "private.lock") }
    }

    /// The engine's own suggestions while typing. On, as in Safari: it sends
    /// what is typed to the engine before Go, never from a private tab.
    @Published var engineSuggestions: Bool {
        didSet { store.set(engineSuggestions, forKey: "search.suggest") }
    }

    /// Tabs, pins, bookmarks and these settings through one's own iCloud.
    /// On unless turned off: what people ask for, and nothing leaves their
    /// own iCloud, end to end encrypted.
    @Published var sync: Bool {
        didSet {
            store.set(sync, forKey: "sync")
            sync ? Sync.shared.start() : Sync.shared.stop()
        }
    }

    /// Every tab as a card with a picture of its page (on), or as one line
    /// each, the Mac's way (off).
    @Published var tabCards: Bool {
        didSet { store.set(tabCards, forKey: "tabs.cards") }
    }

    /// With cards on: one big card at a time, swiped across like the
    /// iPhone's own app switcher (on), or the grid, two by two (off, the
    /// default).
    @Published var tabDeck: Bool {
        didSet { store.set(tabDeck, forKey: "tabs.deck") }
    }

    /// On a screen with room for it (an open Duo, an iPad): the Mac's
    /// sidebar, with the pins and the tabs. On unless hidden from
    /// its own button, brought back from the pill held or Settings.
    @Published var sidebar: Bool {
        didSet { store.set(sidebar, forKey: "sidebar") }
    }

    /// The player videos go full screen in. The iPhone's own until chosen.
    @Published var videoPlayer: VideoPlayer {
        didSet { store.set(videoPlayer.rawValue, forKey: "video.player") }
    }

    /// Which of the Mac's spaces' pins the iPhone shows; nil for the first.
    @Published var syncSpace: String? {
        didSet { store.set(syncSpace, forKey: "sync.space") }
    }

    /// The welcome has been seen.
    @Published var welcomed: Bool {
        didSet { store.set(welcomed, forKey: "welcomed") }
    }

    var searchTemplate: String { engine.template(custom: customEngine) }

    private init() {
        look = store.string(forKey: "look").flatMap(Look.init) ?? .system
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? Engine.standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        shield = Shield.shared.enabled
        handoff = store.object(forKey: "handoff") as? Bool ?? true
        autoClose = store.string(forKey: "tabs.autoclose").flatMap(AutoClose.init) ?? .never
        lockPrivate = store.object(forKey: "private.lock") as? Bool ?? true
        engineSuggestions = store.object(forKey: "search.suggest") as? Bool ?? true
        welcomed = store.bool(forKey: "welcomed")
        sync = store.object(forKey: "sync") as? Bool ?? true
        syncSpace = store.string(forKey: "sync.space")
        tabCards = store.object(forKey: "tabs.cards") as? Bool ?? true
        tabDeck = store.bool(forKey: "tabs.deck")
        sidebar = store.object(forKey: "sidebar") as? Bool ?? true
        videoPlayer = store.string(forKey: "video.player").flatMap(VideoPlayer.init) ?? .native
    }

    /// The site's own player for videos on this page's site.
    func sitePlayer(_ url: URL?) -> Bool {
        switch videoPlayer {
        case .native: return false
        case .website: return true
        case .chosen: return Sites.shared.prefs(url).sitePlayer == true
        }
    }
}
