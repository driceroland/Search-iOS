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

    var searchTemplate: String { engine.template(custom: customEngine) }

    private init() {
        look = store.string(forKey: "look").flatMap(Look.init) ?? .system
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? Engine.standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        shield = Shield.shared.enabled
    }
}
