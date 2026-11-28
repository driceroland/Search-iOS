import Foundation
import WebKit

// Stronger ad blocking: the lists wBlock starts people on, the ones uBlock
// Origin itself uses and EasyList's, on top of Shield's own short list. Off
// until someone turns it on in Settings, because it is the one thing in Search
// that goes out for something nobody asked a page for: the lists, once a week,
// from where their authors publish them. Nothing about the person goes with
// the request; it is the same download for everyone.
//
// They are read with Filters.swift and compiled by WebKit like Shield's list,
// so they cost nothing per page either. What they can't say as content rules
// (scriptlets, redirects, parameters taken out of addresses) is left out.

@MainActor
final class Lists: ObservableObject {
    static let shared = Lists()

    /// Where the lists come from: uBlock Origin's own and EasyList's, as
    /// uBlock serves them, Peter Lowe's hosts, and wBlock's own hosts list —
    /// what wBlock turns on to begin with, less the two lists that only take
    /// tracking parameters out of addresses, which a content rule can't do.
    static let sources: [(name: String, url: URL)] = [
        ("ublock-filters", "https://ublockorigin.github.io/uAssetsCDN/filters/filters.min.txt"),
        ("ublock-privacy", "https://ublockorigin.github.io/uAssetsCDN/filters/privacy.min.txt"),
        ("ublock-badware", "https://ublockorigin.github.io/uAssetsCDN/filters/badware.min.txt"),
        ("ublock-quick-fixes", "https://ublockorigin.github.io/uAssetsCDN/filters/quick-fixes.min.txt"),
        ("ublock-unbreak", "https://ublockorigin.github.io/uAssetsCDN/filters/unbreak.min.txt"),
        ("easylist", "https://ublockorigin.github.io/uAssetsCDN/thirdparties/easylist.txt"),
        ("easyprivacy", "https://ublockorigin.github.io/uAssetsCDN/thirdparties/easyprivacy.txt"),
        ("peter-lowe", "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext"),
        ("wblock-hosts", "https://raw.githubusercontent.com/0xCUB3/wBlock/main/filters/ad-tracking-hosts.txt"),
    ].map { ($0.0, URL(string: $0.1)!) }

    /// How old the lists may get before they are fetched again.
    static let week: TimeInterval = 7 * 24 * 3600

    private static let prefix = "office-lists-"
    private static let folder = Store.file("Lists")

    /// Asked for in Settings. Off until then.
    @Published var enabled = Store.settings.bool(forKey: "shield.lists") {
        didSet {
            guard enabled != oldValue else { return }
            Store.settings.set(enabled, forKey: "shield.lists")
            if enabled { refresh() } else { forget() }
        }
    }

    /// Fetching, reading or compiling, right now.
    @Published private(set) var working = false
    /// What went wrong the last time, said plainly. The lists from before,
    /// if there are any, are still in use.
    @Published private(set) var problem: String?
    /// When the lists in use were made, and how many rules they came to.
    @Published private(set) var updated = Store.settings.object(forKey: "shield.lists.updated") as? Date
    @Published private(set) var rules = Store.settings.integer(forKey: "shield.lists.rules")

    /// Bumped by every refresh and by turning off, so a refresh that
    /// finishes after either knows its result is no longer wanted.
    private var generation = 0

    /// At launch: the lists compiled last time, straight from WebKit's
    /// store, and a refresh if they are a week old or missing.
    func start() {
        guard enabled else { return }
        let names = Store.settings.stringArray(forKey: "shield.lists.names") ?? []
        guard !names.isEmpty, let store = WKContentRuleListStore.default() else {
            refresh()
            return
        }
        let mine = generation
        Task {
            var found: [WKContentRuleList] = []
            for name in names {
                guard let list = await Self.lookUp(name, in: store) else { break }
                found.append(list)
            }
            guard mine == generation, enabled else { return }
            if found.count == names.count { Shield.shared.use(found) }
            let stale = updated.map { Date().timeIntervalSince($0) > Self.week } ?? true
            if found.count != names.count || stale { refresh() }
        }
    }

    /// Fetch, read and compile the lists again; the ones in use stay until
    /// the new ones are ready.
    func refresh() {
        guard enabled else { return }
        generation += 1
        let mine = generation
        working = true
        problem = nil
        Task {
            let texts = await Self.download()
            guard mine == generation else { return }
            guard !texts.isEmpty else {
                finish(problem: String(localized: "Couldn't download the lists. Check your connection and try again."))
                return
            }
            // Read off the main thread; the rules themselves are let go as
            // soon as they are written out, before WebKit starts compiling.
            let (parts, count) = await Task.detached(priority: .utility) {
                Self.encode(texts)
            }.value
            guard mine == generation, let store = WKContentRuleListStore.default() else { return }
            let stamp = Int(Date().timeIntervalSince1970)
            var names: [String] = []
            var compiled: [WKContentRuleList] = []
            // One at a time: WebKit's compiler is hungry, two at once more so.
            for (index, json) in parts.enumerated() {
                let name = "\(Self.prefix)\(stamp)-\(index)"
                do {
                    compiled.append(try await Self.compile(json, as: name, in: store))
                    names.append(name)
                } catch {
                    names.forEach { store.removeContentRuleList(forIdentifier: $0) { _ in } }
                    guard mine == generation else { return }
                    finish(problem: String(localized: "Couldn't prepare the lists: \(error.localizedDescription)"))
                    return
                }
            }
            guard mine == generation, enabled else {
                names.forEach { store.removeContentRuleList(forIdentifier: $0) { _ in } }
                return
            }
            Shield.shared.use(compiled)
            await Self.removeAll(in: store, except: Set(names))
            let now = Date()
            Store.settings.set(names, forKey: "shield.lists.names")
            Store.settings.set(now, forKey: "shield.lists.updated")
            Store.settings.set(count, forKey: "shield.lists.rules")
            updated = now
            rules = count
            finish(problem: nil)
        }
    }

    private func finish(problem: String?) {
        working = false
        self.problem = problem
    }

    /// Turned off: the lists leave every tab, WebKit's store and the disk.
    private func forget() {
        generation += 1
        working = false
        problem = nil
        Shield.shared.use([])
        if let store = WKContentRuleListStore.default() {
            Task { await Self.removeAll(in: store, except: []) }
        }
        try? FileManager.default.removeItem(at: Self.folder)
        for key in ["shield.lists.names", "shield.lists.updated", "shield.lists.rules"] {
            Store.settings.removeObject(forKey: key)
        }
        updated = nil
        rules = 0
    }

    // MARK: - work

    /// Every list, fresh where it could be fetched and the copy from last
    /// time where it couldn't. A session of its own that keeps nothing:
    /// no cookies, no cache, nothing to tie one week's fetch to the next.
    nonisolated private static func download() async -> [String] {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return await withTaskGroup(of: (Int, String?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let saved = folder.appendingPathComponent(source.name + ".txt")
                    if let (data, response) = try? await session.data(from: source.url),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let text = String(data: data, encoding: .utf8),
                       !text.isEmpty, !text.hasPrefix("<") {
                        try? data.write(to: saved, options: .atomic)
                        return (index, text)
                    }
                    return (index, try? String(contentsOf: saved, encoding: .utf8))
                }
            }
            var texts = [String?](repeating: nil, count: sources.count)
            for await (index, text) in group { texts[index] = text }
            return texts.compactMap { $0 }
        }
    }

    /// The lists read into rules, cut to WebKit's size and written out as
    /// the JSON WebKit compiles, with the number of rules.
    nonisolated private static func encode(_ texts: [String]) -> ([String], Int) {
        // Foundation's leftovers are let go at each step, not at the end.
        let converted = autoreleasepool { Filters.convert(texts) }
        // Two lists rather than one of WebKit's largest: compiling one of
        // 70,000 rules takes half the memory of one of 150,000, and an
        // older iPhone would rather not find room for the bigger one.
        let parts = Filters.lists(converted, limit: 70_000).compactMap { rules -> String? in
            autoreleasepool {
                guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
                return String(data: data, encoding: .utf8)
            }
        }
        return (parts, converted.count)
    }

    private static func compile(_ json: String, as name: String, in store: WKContentRuleListStore) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { done in
            store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json) { list, error in
                if let list { done.resume(returning: list) } else {
                    done.resume(throwing: error ?? CocoaError(.featureUnsupported))
                }
            }
        }
    }

    private static func lookUp(_ name: String, in store: WKContentRuleListStore) async -> WKContentRuleList? {
        await withCheckedContinuation { done in
            store.lookUpContentRuleList(forIdentifier: name) { list, _ in done.resume(returning: list) }
        }
    }

    /// Lists of ours WebKit still keeps, other than the ones in use.
    private static func removeAll(in store: WKContentRuleListStore, except keep: Set<String>) async {
        let names = await withCheckedContinuation { done in
            store.getAvailableContentRuleListIdentifiers { done.resume(returning: $0 ?? []) }
        }
        for name in names where name.hasPrefix(prefix) && !keep.contains(name) {
            store.removeContentRuleList(forIdentifier: name) { _ in }
        }
    }
}
