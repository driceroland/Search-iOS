import SwiftUI
import WebKit

// The few things a person can change, kept in the app's own defaults. Each
// one says what it does in Settings; nothing here is on that the Mac has off.

enum Look: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Same as iPhone"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// How long a tab may be left alone before it closes by itself.
enum AutoClose: String, CaseIterable, Identifiable {
    case never, day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .day: return "After a day"
        case .week: return "After a week"
        case .month: return "After a month"
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

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private let store = Store.settings

    /// Light, dark, or whatever the iPhone is: the Mac's default.
    @Published var look: Look {
        didSet { store.set(look.rawValue, forKey: "look") }
    }

    @Published var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }

    /// A search address of one's own, with %s where the words go.
    @Published var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }

    /// The ad blocker, on as on the Mac.
    @Published var shield: Bool {
        didSet { Shield.shared.enabled = shield }
    }

    /// Offer the page on screen to one's own Mac, and take up the Mac's.
    /// Off until turned on.
    @Published var handoff: Bool {
        didSet { store.set(handoff, forKey: "handoff") }
    }

    /// Tabs not looked at for a while close by themselves. Off until chosen.
    @Published var autoClose: AutoClose {
        didSet { store.set(autoClose.rawValue, forKey: "tabs.autoclose") }
    }

    /// Private tabs ask for Face ID when Search comes back. Off until on.
    @Published var lockPrivate: Bool {
        didSet { store.set(lockPrivate, forKey: "private.lock") }
    }

    /// The engine's own suggestions while typing. Off until on: it sends
    /// what is typed to the engine before Go.
    @Published var engineSuggestions: Bool {
        didSet { store.set(engineSuggestions, forKey: "search.suggest") }
    }

    var searchTemplate: String { engine.template(custom: customEngine) }

    private init() {
        look = store.string(forKey: "look").flatMap(Look.init) ?? .system
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? Engine.standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        shield = Shield.shared.enabled
        handoff = store.bool(forKey: "handoff")
        autoClose = store.string(forKey: "tabs.autoclose").flatMap(AutoClose.init) ?? .never
        lockPrivate = store.bool(forKey: "private.lock")
        engineSuggestions = store.bool(forKey: "search.suggest")
    }
}
