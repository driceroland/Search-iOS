import Foundation

// Filter lists, in the syntax uBlock Origin, AdGuard and Adblock Plus share,
// turned into WebKit content rules for Lists.swift. Only what a content rule
// can say: a request blocked, an exception to that, an element hidden. The
// rest — scriptlets, redirects to a stand-in script, parameters taken out of
// an address, procedural selectors — needs code running in the page, and is
// left out rather than turned into something close to it that breaks a site.
//
// Written from the syntax as the lists' own documentation describes it
// (https://help.adblockplus.org/hc/en-us/articles/360062733293,
// https://github.com/gorhill/uBlock/wiki/Static-filter-syntax) and WebKit's
// (https://developer.apple.com/documentation/safariservices/creating-a-content-blocker);
// no code is taken from another converter.

enum Filters {
    typealias Rule = [String: Any]

    struct Converted {
        /// Requests to block, in the order they came.
        var blocks: [Rule] = []
        /// Whole sites blocked (`$document`): after the rule that lets a page
        /// someone opened through, which would undo them.
        var pages: [Rule] = []
        /// Elements to hide.
        var hiding: [Rule] = []
        /// Requests to let through after all, and sites left alone. A rule
        /// list's exceptions only reach the rules before them in the same
        /// list, so every list made from this ends with all of them.
        var exceptions: [Rule] = []

        var count: Int { blocks.count + pages.count + hiding.count + exceptions.count }
    }

    /// WebKit's resource types for a request that isn't a page: what a rule
    /// with no type of its own is narrowed to, so a filter like `-ad-` never
    /// stops a page someone opened.
    static let subresources = ["image", "style-sheet", "script", "font", "raw", "media", "svg-document"]

    /// Selectors per hiding rule: a few hundred, the way WebKit is happiest,
    /// without one bad selector costing the rest more than a batch.
    static let batch = 100

    static func convert(_ texts: [String]) -> Converted {
        var reader = Reader()
        for text in texts {
            for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
                reader.read(line.trimmingCharacters(in: .whitespaces))
            }
        }
        return reader.finish()
    }

    /// A list cut into pieces WebKit will compile: each at most `limit`
    /// rules, blocks first, then the rule that keeps a page someone opened
    /// from being blocked (a filter with no type reaches frames, and WebKit
    /// can't say "a frame" without "a page" too), whole sites blocked, then
    /// hiding, then every exception again.
    static func lists(_ converted: Converted, limit: Int = 150_000) -> [[Rule]] {
        let allowPage: Rule = [
            "trigger": ["url-filter": ".*", "resource-type": ["document"], "load-context": ["top-frame"]],
            "action": ["type": "ignore-previous-rules"],
        ]
        let room = limit - converted.exceptions.count - converted.pages.count - 1
        guard room > 0 else { return [] }
        var lists: [[Rule]] = []
        var current: [Rule] = []
        var blocks = converted.blocks[...]
        var hiding = converted.hiding[...]
        while !blocks.isEmpty || !hiding.isEmpty {
            let take = min(room, blocks.count)
            current += blocks.prefix(take)
            blocks = blocks.dropFirst(take)
            current.append(allowPage)
            current += converted.pages
            let rest = min(room - take, hiding.count)
            current += hiding.prefix(rest)
            hiding = hiding.dropFirst(rest)
            current += converted.exceptions
            lists.append(current)
            current = []
        }
        return lists
    }

    // MARK: - reading

    private struct Reader {
        var blocks: [Rule] = []
        var pages: [Rule] = []
        var exceptions: [Rule] = []
        var seen = Set<String>()
        /// Generic hiding: selector → the sites it is excepted on.
        var generic: [String: Set<String>] = [:]
        var genericOrder: [String] = []
        /// Generic hiding switched off whole: `@@||site^$generichide`.
        var noGeneric = Set<String>()
        /// Site hiding: the sites, joined → their selectors.
        var specific: [String: (sites: [String], selectors: [String])] = [:]
        var specificOrder: [String] = []
        var specificSeen = Set<String>()
        /// `site#@#selector`: selector → sites. An empty set is everywhere.
        var unhidden: [String: Set<String>] = [:]

        mutating func read(_ line: String) {
            guard let first = line.utf8.first, first != UInt8(ascii: "!"), first != UInt8(ascii: "[") else { return }
            let marked = line.utf8.contains(UInt8(ascii: "#"))
            if marked, Filters.unsupportedMarkers.contains(where: line.contains) { return }
            let hosts = first == UInt8(ascii: "0") || first == UInt8(ascii: "1") || first == UInt8(ascii: ":")
            if hosts, let host = Filters.hostsLine(line) {
                network("||\(host)^")
            } else if !marked {
                network(line)
            } else if let range = line.range(of: "#@#") {
                unhide(sites: line[..<range.lowerBound], selector: line[range.upperBound...])
            } else if let range = line.range(of: "##") {
                hide(sites: line[..<range.lowerBound], selector: line[range.upperBound...])
            } else if !line.hasPrefix("#") {
                network(line)
            }
        }

        // MARK: hiding

        mutating func hide(sites: Substring, selector raw: Substring) {
            let selector = raw.trimmingCharacters(in: .whitespaces)
            guard Filters.plainSelector(selector),
                  let (on, off) = Filters.sites(sites, separator: ",")
            else { return }
            if on.isEmpty {
                // Sites a generic rule is turned off on (`~site##x`) are
                // excepted like `site#@#x`.
                if generic[selector] == nil {
                    generic[selector] = []
                    genericOrder.append(selector)
                }
                generic[selector]?.formUnion(off)
            } else {
                let key = on.joined(separator: ",")
                guard specificSeen.insert(key + "##" + selector).inserted else { return }
                if specific[key] == nil {
                    specific[key] = (on, [])
                    specificOrder.append(key)
                }
                specific[key]?.selectors.append(selector)
            }
        }

        mutating func unhide(sites: Substring, selector raw: Substring) {
            let selector = raw.trimmingCharacters(in: .whitespaces)
            guard let (on, _) = Filters.sites(sites, separator: ",") else { return }
            if on.isEmpty {
                unhidden[selector] = []
            } else if unhidden[selector]?.isEmpty != true {
                // Not already shown everywhere.
                unhidden[selector, default: []].formUnion(on)
            }
        }

        // MARK: requests

        mutating func network(_ line: String) {
            var text = Substring(line)
            let exception = text.hasPrefix("@@")
            if exception { text = text.dropFirst(2) }

            var pattern = text
            var options: [Substring] = []
            if let dollar = text.lastIndex(of: "$"),
               !(text.hasPrefix("/") && text[dollar...].contains("/")) {
                pattern = text[..<dollar]
                options = text[text.index(after: dollar)...].split(separator: ",")
            }

            var load: String?
            var on: [String] = []
            var off: [String] = []
            var types = Set<String>()
            var notTypes = Set<String>()
            var frame = false
            var page = false
            var caseSensitive = false
            var hidingOff = false
            var broadened = false

            for option in options {
                let parts = option.split(separator: "=", maxSplits: 1)
                let name = parts[0].lowercased()
                let value = parts.count > 1 ? parts[1] : ""
                switch name {
                case "third-party", "3p", "~first-party", "~1p", "strict3p":
                    load = "third-party"
                case "~third-party", "~3p", "first-party", "1p", "strict1p":
                    load = "first-party"
                case "domain", "from":
                    guard let parsed = Filters.sites(value, separator: "|") else { return }
                    on = parsed.on
                    off = parsed.off
                case "match-case":
                    caseSensitive = true
                case "important", "all":
                    break
                case "subdocument", "frame":
                    frame = true
                case "document", "doc":
                    page = true
                case "elemhide", "ehide", "generichide", "ghide":
                    hidingOff = true
                default:
                    if let type = Filters.types[name] {
                        types.insert(type)
                        if Filters.broadened.contains(name) { broadened = true }
                    } else if name.hasPrefix("~"), let type = Filters.types[String(name.dropFirst())] {
                        notTypes.insert(type)
                    } else if name == "~subdocument" || name == "~frame" || name == "~document" {
                        break
                    } else {
                        // popup, redirect, removeparam, csp, badfilter and
                        // the rest: nothing a content rule can do, or
                        // something it would do wrongly.
                        return
                    }
                }
            }

            if hidingOff {
                // A site generic hiding breaks: kept off it.
                if exception, let host = Filters.host(of: pattern) { noGeneric.insert(host) }
                return
            }

            if page && exception {
                // `@@||site^$document`: the whole site left alone.
                guard let host = Filters.host(of: pattern) else { return }
                add(["url-filter": ".*", "if-domain": ["*" + host]], exception: true)
                return
            }

            guard let filter = Filters.urlFilter(pattern) else { return }
            if broadened && filter == ".*" && on.isEmpty && !exception { return }
            var trigger: [String: Any] = ["url-filter": filter]
            if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
            if let load { trigger["load-type"] = [load] }
            // A trigger takes sites it applies on or sites it doesn't, not
            // both; with both, the rule is left out rather than widened.
            if !on.isEmpty && !off.isEmpty { return }
            if !on.isEmpty { trigger["if-domain"] = on.map { "*" + $0 } }
            if !off.isEmpty { trigger["unless-domain"] = off.map { "*" + $0 } }

            if page {
                trigger["resource-type"] = ["document"]
                trigger["load-context"] = ["top-frame"]
                add(trigger, exception: false, page: true)
                return
            }
            var resources = types
            if frame { resources.insert("document") }
            if types.isEmpty && !frame {
                resources = Set(Filters.subresources).subtracting(notTypes)
                // A filter with no type reaches frames too, where ads come
                // in; a page someone opened is let through again by the rule
                // after the blocks (see `lists`). Not for an exception: as a
                // page, it would undo the site's hiding as well.
                if notTypes.isEmpty && !exception { resources.insert("document") }
            }
            guard !resources.isEmpty else { return }
            trigger["resource-type"] = resources.sorted()
            add(trigger, exception: exception)
        }

        mutating func add(_ trigger: [String: Any], exception: Bool, page: Bool = false) {
            let key = (exception ? "@" : page ? "!" : "") + Filters.key(trigger)
            guard seen.insert(key).inserted else { return }
            let rule: Rule = [
                "trigger": trigger,
                "action": ["type": exception ? "ignore-previous-rules" : "block"],
            ]
            if exception { exceptions.append(rule) } else if page { pages.append(rule) } else { blocks.append(rule) }
        }

        // MARK: finishing

        func finish() -> Converted {
            var hiding: [Rule] = []

            // Generic selectors, grouped by the sites they're excepted on.
            var groups: [String: (off: [String], selectors: [String])] = [:]
            var groupOrder: [String] = []
            let everywhereOff = noGeneric.sorted()
            for selector in genericOrder {
                if let everywhere = unhidden[selector], everywhere.isEmpty { continue }
                // Most have none: only those that do pay for the sort.
                let own = (generic[selector] ?? []).union(unhidden[selector] ?? [])
                let off = own.isEmpty ? [] : own.subtracting(noGeneric).sorted()
                let key = off.joined(separator: ",")
                if groups[key] == nil {
                    groups[key] = (off, [])
                    groupOrder.append(key)
                }
                groups[key]?.selectors.append(selector)
            }
            for key in groupOrder {
                guard let group = groups[key] else { continue }
                for chunk in stride(from: 0, to: group.selectors.count, by: Filters.batch) {
                    let selectors = group.selectors[chunk..<min(chunk + Filters.batch, group.selectors.count)]
                    var trigger: [String: Any] = ["url-filter": ".*"]
                    let off = group.off + everywhereOff
                    if !off.isEmpty { trigger["unless-domain"] = off.map { "*" + $0 } }
                    hiding.append([
                        "trigger": trigger,
                        "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")],
                    ])
                }
            }

            for key in specificOrder {
                guard let entry = specific[key] else { continue }
                let selectors = entry.selectors.filter { selector in
                    guard let off = unhidden[selector] else { return true }
                    return !off.isEmpty && !entry.sites.allSatisfy(off.contains)
                }
                for chunk in stride(from: 0, to: selectors.count, by: Filters.batch) {
                    let part = selectors[chunk..<min(chunk + Filters.batch, selectors.count)]
                    hiding.append([
                        "trigger": ["url-filter": ".*", "if-domain": entry.sites.map { "*" + $0 }],
                        "action": ["type": "css-display-none", "selector": part.joined(separator: ", ")],
                    ])
                }
            }

            return Converted(blocks: blocks, pages: pages, hiding: hiding, exceptions: exceptions)
        }
    }

    // MARK: - pieces

    /// Cosmetic syntaxes that aren't plain hiding: scriptlets, CSS injected,
    /// HTML filtered, procedural.
    static let unsupportedMarkers = ["#?#", "#@?#", "#$#", "#@$#", "#%#", "#@%#", "#$?#", "#@$?#", "##+js", "#@#+js", "##^", "#@#^"]

    /// uBO's and AdGuard's own pseudo-classes: in a selector, WebKit would
    /// throw the whole batch away.
    static let procedural = [
        ":has-text(", ":upward(", ":xpath(", ":matches-css", ":min-text-length(", ":watch-attr(",
        ":matches-path(", ":others(", ":-abp-", ":matches-attr(", ":matches-prop(", ":matches-media(",
        ":remove(", ":style(", ":remove-attr(", ":remove-class(", ":contains(", ":nth-ancestor(",
        ":if(", ":if-not(", ":spath(", ":shadow(", "!important", "{",
    ]

    static func plainSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII) else { return false }
        return !procedural.contains(where: selector.contains)
    }

    /// `a.com,~b.a.com` or `a.com|~b.a.com`: the sites on and off, lowercased,
    /// or nil when a site it applies on can't be written as WebKit's (a
    /// wildcard TLD, a regular expression, a name outside ASCII) — a rule
    /// meant for a few sites mustn't become one for every site.
    static func sites(_ text: Substring, separator: Character) -> (on: [String], off: [String])? {
        var on: [String] = []
        var off: [String] = []
        for part in text.split(separator: separator) {
            let entry = part.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = entry.hasPrefix("~")
            let site = negated ? String(entry.dropFirst()) : entry
            let usable = !site.isEmpty && site.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
            if negated {
                if usable { off.append(site) }
            } else if usable {
                on.append(site)
            } else {
                return nil
            }
        }
        return (on, off)
    }

    /// `0.0.0.0 ads.example` or `127.0.0.1 ads.example`: a hosts file's line.
    static func hostsLine(_ line: String) -> String? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, ["0.0.0.0", "127.0.0.1", "::", "::1"].contains(String(parts[0])) else { return nil }
        let host = parts[1].lowercased()
        guard host != "localhost", host != "0.0.0.0", host.contains("."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return host
    }

    /// The host of `||host^`, and only of that.
    static func host(of pattern: Substring) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") { host = host.dropLast() }
        let name = host.lowercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        return name
    }

    static let types: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "css": "style-sheet",
        "font": "font", "media": "media", "object": "media",
        "xmlhttprequest": "raw", "xhr": "raw", "websocket": "raw", "other": "raw",
        // WebKit's own: a beacon, an <a ping>. Not `raw`, which is every
        // fetch as well: EasyPrivacy's `*$ping,third-party` as `raw` stops
        // every site's own requests to its API.
        "ping": "ping", "beacon": "ping",
    ]

    /// Types WebKit can only say more broadly, as `raw`: a rule of theirs
    /// for every address everywhere would block every request a page makes.
    static let broadened: Set<String> = ["websocket", "other"]

    /// A filter's address pattern as WebKit's url-filter, a small regular
    /// expression language: no alternation, no counted repeats, no shorthand
    /// classes. Nil for what it can't say.
    static func urlFilter(_ pattern: Substring) -> String? {
        guard pattern.allSatisfy(\.isASCII) else { return nil }

        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/") {
            let body = String(pattern.dropFirst().dropLast())
            let unsupported = ["|", "{", "}", "\\d", "\\D", "\\w", "\\W", "\\s", "\\S", "\\b", "\\B", "(?", "\\u", "\\x"]
            if unsupported.contains(where: body.contains) { return nil }
            // `^` only at the start, outside a class; `$` only at the end.
            let classless = body.replacingOccurrences(of: "[^", with: "[")
            if classless.dropFirst().contains("^") { return nil }
            let unescaped = body.replacingOccurrences(of: "\\$", with: "")
            if unescaped.dropLast().contains("$") { return nil }
            return body
        }

        var text = pattern
        var start = ""
        if text.hasPrefix("||") {
            // The host itself or any subdomain of it.
            start = "^[^:]+:(//)?([^/]+\\.)?"
            text = text.dropFirst(2)
        } else if text.hasPrefix("|") {
            start = "^"
            text = text.dropFirst()
        }
        var end = ""
        if text.hasSuffix("|") {
            end = "$"
            text = text.dropLast()
        }
        if text.contains("|") { return nil }

        var out = start
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let last = text.index(after: index) == text.endIndex
            switch character {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                // A separator: anything but a letter, a digit or `_-.%`, or
                // the end of the address.
                out += "[^a-zA-Z0-9_.%-]"
                // Always followed by something: WebKit writes an address with a slash after its host. A `^` at the very end of one is rare, and the optional group it would take makes a list compile six times slower.
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$":
                out += "\\" + String(character)
            default:
                out.append(character)
            }
            index = text.index(after: index)
        }
        out += end
        if out.isEmpty || out == ".*" { return ".*" }
        // A filter that would match nearly everything is a list's mistake.
        if out.count < 3 && start.isEmpty { return nil }
        return out
    }

    /// The same trigger, written the same way every time, to drop repeats.
    static func key(_ trigger: [String: Any]) -> String {
        trigger.keys.sorted().map { key in
            let value = trigger[key]
            if let list = value as? [String] { return key + "=" + list.joined(separator: "|") }
            return key + "=" + String(describing: value ?? "")
        }.joined(separator: ";")
    }
}
