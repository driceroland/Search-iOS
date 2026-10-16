import Foundation

// Where you have been, ranked by how often and how lately — the same rule as
// the Mac, because it is the rule that makes three letters enough.

struct Suggestion: Identifiable, Equatable {
    let key: String
    let title: String
    let url: URL
    var id: String { key }
}

private struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
}

@MainActor
final class History: ObservableObject {
    private var visits: [String: Visit] = [:]
    private var saving = false

    init() { load() }

    func record(_ url: URL, title: String) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        let key = Address.pretty(url).lowercased()
        guard !key.isEmpty else { return }

        // Reading a deep page is also a visit to the site: nobody types a
        // domain meaning to land halfway down it.
        if let host = url.host(), key.contains("/") {
            let root = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host).lowercased()
            var home = visits[root] ?? Visit(
                url: "https://" + root + "/", key: root, title: "", count: 0, last: Date()
            )
            home.count += 1
            home.last = Date()
            visits[root] = home
        }

        if var seen = visits[key] {
            seen.count += 1
            seen.last = Date()
            if !title.isEmpty { seen.title = title }
            visits[key] = seen
        } else {
            visits[key] = Visit(
                url: url.absoluteString, key: key, title: title, count: 1, last: Date()
            )
        }
        save()
    }

    func suggestions(for typed: String, limit: Int = 3) -> [Suggestion] {
        let needle = strip(typed)
        // An empty field proposes nothing.
        guard !needle.isEmpty else { return [] }

        let now = Date()
        return visits.values
            .compactMap { visit -> (Suggestion, Double)? in
                guard let rank = rank(visit.key, against: needle),
                      let url = URL(string: visit.url)
                else { return nil }
                let front = visit.key.contains("/") ? 0.0 : 1.5
                return (
                    Suggestion(key: visit.key, title: visit.title, url: url),
                    rank + frecency(visit, now: now) + front
                )
            }
            .sorted { $0.1 == $1.1 ? $0.0.key.count < $1.0.key.count : $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    func completion(for typed: String, among options: [Suggestion]) -> String? {
        let lower = typed.lowercased()
        guard lower.count >= 2,
              let hit = options.first(where: { $0.key.hasPrefix(lower) })
        else { return nil }
        let rest = String(hit.key.dropFirst(lower.count))
        return rest.isEmpty ? nil : rest
    }

    func forget() {
        visits = [:]
        save()
    }

    private func rank(_ key: String, against needle: String) -> Double? {
        if key.hasPrefix(needle) { return 6 }
        let host = key.split(separator: "/").first.map(String.init) ?? key
        if let dot = host.range(of: "."), host[dot.upperBound...].hasPrefix(needle) { return 3 }
        if needle.count >= 2, host.contains(needle) { return 2 }
        return nil
    }

    private func frecency(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    private static var file: URL { Store.file("history.json") }

    private func load() {
        guard let data = try? Data(contentsOf: History.file),
              let list = try? JSONDecoder().decode([Visit].self, from: data)
        else { return }
        visits = Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
    }

    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            saving = false
            let now = Date()
            let list = self.visits.values
                .sorted { self.frecency($0, now: now) > self.frecency($1, now: now) }
                .prefix(1_000)
                .map { $0 }
            let file = History.file
            DispatchQueue.global(qos: .utility).async {
                guard let data = try? JSONEncoder().encode(list) else { return }
                try? data.write(to: file, options: .atomic)
            }
        }
    }
}
