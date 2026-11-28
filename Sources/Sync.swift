import SwiftUI
import CloudKit

// Sync: the same open tabs, pins, bookmarks and a few settings on the
// iPhone and the Mac, through the person's own iCloud. On unless turned off.
//
// One private CloudKit zone, "Search", in the person's iCloud: no server of
// ours, nothing we can read. Every record is one kind, "Item", named by what
// it holds (see SYNC.md), and what it holds is JSON in an encrypted field,
// end to end. The same shapes as the Mac's own files, so both apps read
// each other without translating.
//
// Each thing is the newest version of it, whole: the latest change wins.
// The first time a device joins, its pins and bookmarks are added to what
// is already there rather than written over it.

// MARK: - the shapes, the Mac's

/// A pin, as the Mac keeps it (Pins.swift there).
struct PinDef: Codable, Equatable {
    var id: UUID
    var letter: String
    var home: String
    var title: String
    var name: String?
}

/// A bookmark or a folder, as the Mac keeps it (Bookmarks.swift there).
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { url == nil }
}

/// A space, as much of it as the iPhone needs.
struct SpaceInfo: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var icon: String?
}

/// One device's open tabs, private ones never.
struct DeviceTabs: Codable, Equatable {
    struct Page: Codable, Equatable, Hashable {
        var url: String
        var title: String
    }

    var name: String
    var platform: String
    var at: Date
    var tabs: [Page]
}

/// The settings both apps share.
struct SharedSettings: Codable, Equatable {
    var engine: String?
    var custom: String?
    /// A custom engine's suggestions address, set on the Mac. The iPhone
    /// doesn't use it yet, but carries it back, or writing the settings
    /// from here would wipe it there.
    var suggest: String?
    var look: String?
}

// MARK: - the engine

@MainActor
final class Sync: NSObject, ObservableObject {
    static let shared = Sync()

    static let containerID = "iCloud.com.officecommun.search"
    static let zoneID = CKRecordZone.ID(zoneName: "Search", ownerName: CKCurrentUserDefaultName)
    /// The Mac's first space, whose pins are the ones there were before spaces.
    static let firstSpace = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The other devices' open tabs, by device.
    @Published private(set) var others: [String: DeviceTabs] = [:]
    /// The Mac's spaces, to choose whose pins the iPhone shows.
    @Published private(set) var spaces: [SpaceInfo] = []
    /// What went wrong, said plainly, or nil.
    @Published private(set) var problem: String?

    weak var browser: Browser?

    private var engine: CKSyncEngine?

    /// What is kept between launches: the engine's place, each record's
    /// server fields, when each thing last changed, and its last JSON.
    private struct Meta: Codable {
        var state: CKSyncEngine.State.Serialization?
        var fields: [String: Data] = [:]
        var at: [String: Date] = [:]
        var values: [String: Data] = [:]
        var device = UUID().uuidString
        /// The first full fetch is done: from then on, local changes go up.
        var joined = false
    }
    private var meta = Meta()

    private static var file: URL { Store.file("sync.json") }

    var deviceID: String { meta.device }
    var isOn: Bool { engine != nil }

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: Sync.file),
           let saved = try? JSONDecoder().decode(Meta.self, from: data) {
            meta = saved
        }
        for (key, data) in meta.values where key.hasPrefix("device.") && key != "device.\(meta.device)" {
            if let tabs = try? JSONDecoder().decode(DeviceTabs.self, from: data) { others[String(key.dropFirst(7))] = tabs }
        }
        if let data = meta.values["spaces"], let list = try? JSONDecoder().decode([SpaceInfo].self, from: data) {
            spaces = list
        }
    }

    // MARK: on and off

    func start() {
        guard engine == nil else { return }
        let database = CKContainer(identifier: Sync.containerID).privateCloudDatabase
        var config = CKSyncEngine.Configuration(database: database, stateSerialization: meta.state, delegate: self)
        config.automaticallySync = true
        let engine = CKSyncEngine(config)
        self.engine = engine
        if meta.state == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Sync.zoneID))])
        }
        UIApplication.shared.registerForRemoteNotifications()
        Task.detached { await self.join() }
    }

    /// Off: this device's tabs leave the others, and nothing more goes up.
    func stop() {
        guard let engine else { return }
        let key = "device.\(meta.device)"
        meta.values[key] = nil
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(Sync.record(key))])
        Task.detached {
            try? await engine.sendChanges()
            await MainActor.run {
                self.engine = nil
                self.others = [:]
                self.meta.joined = false
                self.save()
            }
        }
    }

    /// Everything Search keeps in iCloud, gone, for every device.
    func erase() {
        let engine = self.engine ?? CKSyncEngine(CKSyncEngine.Configuration(
            database: CKContainer(identifier: Sync.containerID).privateCloudDatabase,
            stateSerialization: meta.state, delegate: self
        ))
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Sync.zoneID)])
        Task.detached {
            try? await engine.sendChanges()
            await MainActor.run {
                self.engine = nil
                self.meta = Meta(device: self.meta.device)
                self.others = [:]
                self.spaces = []
                self.save()
            }
        }
    }

    /// Back in front: anything new from the other devices.
    func refresh() {
        guard let engine else { return }
        if !meta.joined {
            Task.detached { await self.join() }
            return
        }
        Task.detached { try? await engine.fetchChanges() }
    }

    /// The first fetch, then what is here goes up.
    private func join() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            problem = nil
        } catch {
            // Not joined until a first fetch has gone through: nothing here
            // goes up over what may be there. Tried again on the next refresh.
            problem = Sync.say(error)
            return
        }
        meta.joined = true
        save()
        browser.map(publish)
    }

    // MARK: what changes here

    /// Everything this device has, offered: only what differs goes up.
    func publish(_ browser: Browser) {
        guard meta.joined else { return }
        // The tabs, not the moment: a device whose tabs haven't changed
        // doesn't write again.
        let tabs = browser.deviceTabs
        let key = "device.\(meta.device)"
        let last = meta.values[key].flatMap { try? JSONDecoder().decode(DeviceTabs.self, from: $0) }
        if last?.tabs != tabs.tabs || last?.name != tabs.name { put(key, tabs) }
        if Prefs.shared.syncPins { putPins(browser.pinDefs) }
        // Never an empty list over one that isn't, unless they were taken
        // away here by hand: an iPhone that hadn't yet heard the Mac's
        // bookmarks once sent its empty list up, stamped newer, and it
        // emptied the Mac's (18 Nov).
        if !Bookmarks.shared.roots.isEmpty || Bookmarks.shared.emptiedByHand {
            putBookmarks(Bookmarks.shared.roots)
        }
        put("settings", Prefs.shared.shared)
    }

    func put<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? Sync.encoder.encode(value) else { return }
        putData(key, data)
    }

    /// The bookmarks: one record while they fit, in parts past the budget
    /// (SYNC.md, "Big bookmark lists"). Nothing goes when the tree is what
    /// the parts kept here already say, however they were cut; parts above
    /// the last are deleted when the tree got shorter.
    func putBookmarks(_ roots: [Bookmark]) {
        guard let engine, meta.joined, let mine = try? Sync.encoder.encode(roots),
              let whole = Sync.normal(mine) else { return }
        let kept = Sync.bookmarksParts(in: meta.values)
        if let last = Sync.joinBookmarks(kept.map(\.data)), Sync.normal(last) == whole { return }
        let parts = Sync.splitBookmarks(whole)
        for (n, data) in parts.enumerated() { putData(Sync.bookmarksKey(n + 1), data) }
        for (key, _) in kept where (Sync.bookmarksPart(key) ?? 0) > parts.count {
            meta.values[key] = nil
            meta.at[key] = nil
            meta.fields[key] = nil
            engine.state.add(pendingRecordZoneChanges: [.deleteRecord(Sync.record(key))])
        }
        save()
    }

    /// Pins go up over the last version read, so what the Mac keeps in a
    /// pin that the iPhone doesn't know (its own fields) rides along.
    private func putPins(_ defs: [PinDef]) {
        let key = "pins.\(pinSpace)"
        let last = meta.values[key]
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let merged: [[String: Any]] = defs.map { def in
            var entry = last.first { ($0["id"] as? String)?.uppercased() == def.id.uuidString } ?? [:]
            entry["id"] = def.id.uuidString
            entry["letter"] = def.letter
            entry["home"] = def.home
            // The title it was pinned with stays; a page's title changes
            // as it loads and isn't the pin's.
            if entry["title"] == nil { entry["title"] = def.title }
            entry["name"] = def.name
            return entry
        }
        guard !NSArray(array: merged).isEqual(to: last),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: .sortedKeys)
        else { return }
        putData(key, data)
    }

    private func putData(_ key: String, _ data: Data) {
        guard let engine, meta.joined, meta.values[key] != data else { return }
        meta.values[key] = data
        meta.at[key] = Date()
        save()
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(Sync.record(key))])
    }

    /// The space whose pins this iPhone shows.
    /// The one chosen if the Mac still has it; else the Mac's first space.
    /// The fixed first-space id only before the Mac's spaces are known: a
    /// Mac whose Personal spaces don't include it (spaces made by an
    /// import) left the iPhone looking for pins that never came, with no
    /// picker to get out when there was one space (27 Nov).
    var pinSpace: UUID {
        Sync.pinSpace(chosen: Prefs.shared.syncSpace.flatMap(UUID.init(uuidString:)), spaces: spaces.map(\.id))
    }

    static func pinSpace(chosen: UUID?, spaces: [UUID]) -> UUID {
        if let chosen, spaces.isEmpty || spaces.contains(chosen) { return chosen }
        return spaces.first ?? firstSpace
    }

    /// Pins from the Mac on or off. Off, the Mac's go from here (they stay
    /// on the Mac); on, the chosen space's come back.
    func syncPins(_ on: Bool) {
        Prefs.shared.syncPins = on
        if on { choose(space: pinSpace) } else { browser?.adopt(pins: []) }
    }

    func choose(space: UUID) {
        Prefs.shared.syncSpace = space.uuidString
        // Its pins, as they are in iCloud, in place of these.
        if let data = meta.values["pins.\(space)"], let defs = try? JSONDecoder().decode([PinDef].self, from: data) {
            browser?.adopt(pins: defs)
        } else {
            browser?.adopt(pins: [])
        }
    }

    // MARK: what comes in

    private func apply(_ record: CKRecord) {
        let key = record.recordID.recordName
        meta.fields[key] = Sync.fields(of: record)
        guard let data = record.encryptedValues["data"] as? Data else { return }
        let at = record["at"] as? Date ?? record.modificationDate ?? .distantPast
        // An empty list of ours never wins over bookmarks that came: what
        // came is kept.
        let oursEmpty = Sync.bookmarksPart(key) != nil && Bookmarks.shared.roots.isEmpty && !Bookmarks.shared.emptiedByHand
        if let ours = meta.at[key], ours > at, meta.values[key] != nil, !oursEmpty {
            // Ours is newer: it goes up again over this one.
            engine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            return
        }
        let first = !meta.joined
        meta.at[key] = at
        meta.values[key] = data
        let decoder = JSONDecoder()

        // Kept as this app writes it, so the same thing never reads as a
        // change and goes back up.
        func canonical<T: Codable>(_ value: T) {
            if let data = try? Sync.encoder.encode(value) { meta.values[key] = data }
        }

        if key.hasPrefix("device.") {
            let id = String(key.dropFirst(7))
            if id != meta.device, let tabs = try? decoder.decode(DeviceTabs.self, from: data) {
                others[id] = tabs
            }
        } else if key.hasPrefix("pins.") {
            guard var defs = try? decoder.decode([PinDef].self, from: data) else { return }
            // Kept as it came, every field, for putPins.
            guard key == "pins.\(pinSpace)", Prefs.shared.syncPins else { save(); return }
            if first, let browser {
                // Joining: these pins and the ones already here, together.
                for mine in browser.pinDefs where !defs.contains(where: { $0.id == mine.id || $0.home == mine.home }) {
                    defs.append(mine)
                }
                meta.at[key] = .distantPast
            }
            browser?.adopt(pins: defs)
        } else if Sync.bookmarksPart(key) != nil {
            // Every part kept, as the one tree (SYNC.md, "Big bookmark lists").
            guard let whole = Sync.joinBookmarks(Sync.bookmarksParts(in: meta.values).map(\.data)),
                  var roots = try? decoder.decode([Bookmark].self, from: whole) else { save(); return }
            if first {
                roots = Bookmarks.union(roots, Bookmarks.shared.roots)
                meta.at[key] = .distantPast
            }
            Bookmarks.shared.adopt(roots)
        } else if key == "spaces" {
            let shown = pinSpace
            spaces = (try? decoder.decode([SpaceInfo].self, from: data)) ?? []
            if let chosen = Prefs.shared.syncSpace.flatMap(UUID.init(uuidString:)),
               !spaces.isEmpty, !spaces.contains(where: { $0.id == chosen }) {
                Prefs.shared.syncSpace = nil
            }
            // Another space now: its pins, from what already came.
            if pinSpace != shown, Prefs.shared.syncPins { choose(space: pinSpace) }
        } else if key == "settings" {
            if let settings = try? decoder.decode(SharedSettings.self, from: data) {
                canonical(settings)
                Prefs.shared.adopt(settings)
            }
        }
        save()
    }

    private func removed(_ key: String) {
        meta.values[key] = nil
        meta.at[key] = nil
        meta.fields[key] = nil
        if key.hasPrefix("device.") { others[String(key.dropFirst(7))] = nil }
        if key == "spaces" { spaces = [] }
        // A later part gone: the tree is what the others say.
        if let part = Sync.bookmarksPart(key), part > 1,
           let whole = Sync.joinBookmarks(Sync.bookmarksParts(in: meta.values).map(\.data)),
           let roots = try? JSONDecoder().decode([Bookmark].self, from: whole) {
            Bookmarks.shared.adopt(roots)
        }
        save()
    }

    /// The record that goes up for a key, on the server's last fields so it
    /// isn't taken for a stranger.
    fileprivate func record(for id: CKRecord.ID) -> CKRecord? {
        let key = id.recordName
        guard let data = meta.values[key] else { return nil }
        let record = meta.fields[key].flatMap(Sync.record(fields:)) ?? CKRecord(recordType: "Item", recordID: id)
        record.encryptedValues["data"] = data
        record["at"] = meta.at[key] ?? Date()
        return record
    }

    fileprivate func sent(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        for saved in changes.savedRecords {
            meta.fields[saved.recordID.recordName] = Sync.fields(of: saved)
        }
        var failed = false
        for failure in changes.failedRecordSaves {
            let id = failure.record.recordID
            let key = id.recordName
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else's version is there: the newer one stays.
                if let theirs = failure.error.serverRecord {
                    meta.fields[key] = Sync.fields(of: theirs)
                    let at = theirs["at"] as? Date ?? .distantPast
                    if let ours = meta.at[key], ours > at {
                        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
                    } else {
                        meta.at[key] = nil
                        apply(theirs)
                    }
                }
            case .zoneNotFound:
                engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Sync.zoneID))])
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .unknownItem:
                meta.fields[key] = nil
                engine?.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                break // the engine tries again by itself
            default:
                // Nothing that fails is quiet: which record, and why.
                problem = Sync.upload(key, failed: failure.error)
                failed = true
            }
        }
        if failed {
            uploadFailed = true
        } else if uploadFailed, !changes.savedRecords.isEmpty {
            problem = nil
            uploadFailed = false
        }
        save()
    }

    private var uploadFailed = false

    /// What a record is, for the line when it can't go up.
    static func what(_ key: String) -> String {
        if key.hasPrefix("device.") { return String(localized: "open tabs") }
        if key.hasPrefix("pins.") { return String(localized: "pins") }
        if bookmarksPart(key) != nil { return String(localized: "bookmarks") }
        return key == "settings" ? String(localized: "settings") : String(localized: "something")
    }

    static func upload(_ key: String, failed error: CKError) -> String {
        let why = say(error)
        return String(localized: "Couldn't send \(what(key)): \(why)")
    }

    fileprivate func account(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            problem = nil
            Task.detached { await self.join() }
        case .signOut, .switchAccounts:
            // Another person's iCloud, or none: nothing of the last one stays.
            meta = Meta(device: meta.device)
            others = [:]
            spaces = []
            problem = String(localized: "Signed out of iCloud")
            save()
        @unknown default:
            break
        }
    }

    fileprivate func state(_ update: CKSyncEngine.State.Serialization) {
        meta.state = update
        save()
    }

    /// Search's data was deleted from iCloud, here or on another device:
    /// sync turns off rather than putting it all back. What is on this
    /// device stays.
    fileprivate func zoneGone() {
        meta = Meta(device: meta.device)
        others = [:]
        spaces = []
        save()
        engine = nil
        if Prefs.shared.sync { Prefs.shared.sync = false }
        problem = String(localized: "Sync was turned off: Search's data was deleted from iCloud.")
    }

    // MARK: kept on disk

    private var saving = false

    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saving = false
            let file = Sync.file
            guard let data = try? JSONEncoder().encode(self.meta) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: helpers

    // MARK: bookmarks in parts (SYNC.md, "Big bookmark lists")

    /// What one record's data may hold before the bookmarks go in several:
    /// CloudKit refuses a record over about 1 MB.
    static let recordBudget = 700_000

    static func bookmarksKey(_ part: Int) -> String { part <= 1 ? "bookmarks" : "bookmarks.\(part)" }

    /// Which part a record name is, or nil when it isn't one.
    static func bookmarksPart(_ key: String) -> Int? {
        if key == "bookmarks" { return 1 }
        guard key.hasPrefix("bookmarks."), let part = Int(key.dropFirst("bookmarks.".count)), part >= 2 else { return nil }
        return part
    }

    /// The bookmark parts kept, in order.
    static func bookmarksParts(in values: [String: Data]) -> [(key: String, data: Data)] {
        values.compactMap { key, data in bookmarksPart(key).map { ($0, key, data) } }
            .sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    private static func dump(_ object: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// The same JSON written the one way the parts are measured in.
    static func normal(_ data: Data) -> Data? {
        (try? JSONSerialization.jsonObject(with: data)).flatMap(dump)
    }

    /// Cut in reading order, each part filled to the budget; a folder that
    /// goes on in the next part is there again, same id and title, with the
    /// rest of its children. One part, exactly as before, while it fits.
    static func splitBookmarks(_ whole: Data, budget: Int = recordBudget) -> [Data] {
        guard whole.count > budget, let list = try? JSONSerialization.jsonObject(with: whole) as? [[String: Any]] else { return [whole] }
        func size(_ object: Any) -> Int { dump(object)?.count ?? 0 }
        var parts: [[[String: Any]]] = [[]]
        var used = 0
        func open(_ path: [[String: Any]]) -> Int {
            var level = parts[parts.count - 1]
            var depth = 0
            for shell in path {
                guard let last = level.last, last["id"] as? String == shell["id"] as? String,
                      let kids = last["children"] as? [[String: Any]] else { break }
                level = kids
                depth += 1
            }
            return depth
        }
        func insert(_ leaf: [String: Any], _ path: ArraySlice<[String: Any]>, into list: inout [[String: Any]]) {
            guard let shell = path.first else { list.append(leaf); return }
            if list.last?["id"] as? String == shell["id"] as? String, list.last?["children"] != nil {
                var last = list.removeLast()
                var kids = last["children"] as? [[String: Any]] ?? []
                last["children"] = nil
                insert(leaf, path.dropFirst(), into: &kids)
                last["children"] = kids
                list.append(last)
            } else {
                var made = shell
                var kids: [[String: Any]] = []
                insert(leaf, path.dropFirst(), into: &kids)
                made["children"] = kids
                list.append(made)
            }
        }
        func place(_ leaf: [String: Any], through path: [[String: Any]]) {
            let shells = { (from: Int) in path[from...].reduce(0) { $0 + size($1) + 16 } }
            var cost = size(leaf) + 1 + shells(open(path))
            if used + cost > budget, used > 0 {
                parts.append([])
                used = 0
                cost = size(leaf) + 1 + shells(0)
            }
            insert(leaf, path[...], into: &parts[parts.count - 1])
            used += cost
        }
        func walk(_ nodes: [[String: Any]], through path: [[String: Any]]) {
            for node in nodes {
                if let kids = node["children"] as? [[String: Any]], !kids.isEmpty {
                    var shell = node
                    shell["children"] = nil
                    walk(kids, through: path + [shell])
                } else {
                    place(node, through: path)
                }
            }
        }
        walk(list, through: [])
        let out = parts.compactMap { dump($0) }
        return out.count == parts.count ? out : [whole]
    }

    /// The parts, back as the one list they were cut from: a folder that
    /// goes on in the next part is one folder again.
    static func joinBookmarks(_ parts: [Data]) -> Data? {
        guard parts.count > 1 else { return parts.first }
        func merge(_ into: inout [[String: Any]], _ more: [[String: Any]]) {
            for node in more {
                if let id = node["id"] as? String, let kids = node["children"] as? [[String: Any]],
                   let at = into.lastIndex(where: { $0["id"] as? String == id && $0["children"] != nil }) {
                    var host = into[at]
                    var have = host["children"] as? [[String: Any]] ?? []
                    host["children"] = nil
                    merge(&have, kids)
                    host["children"] = have
                    into[at] = host
                } else {
                    into.append(node)
                }
            }
        }
        var whole: [[String: Any]] = []
        for part in parts {
            guard let list = try? JSONSerialization.jsonObject(with: part) as? [[String: Any]] else { return nil }
            merge(&whole, list)
        }
        return dump(whole)
    }

    static func record(_ key: String) -> CKRecord.ID { CKRecord.ID(recordName: key, zoneID: zoneID) }

    fileprivate static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func fields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: fields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func say(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .notAuthenticated: return String(localized: "Sign in to iCloud in the iPhone's Settings to sync.")
        case .quotaExceeded: return String(localized: "Your iCloud is full.")
        case .limitExceeded: return String(localized: "Too big for iCloud to take in one piece.")
        case .networkFailure, .networkUnavailable: return String(localized: "Offline. Sync carries on when you're back.")
        default: return error.localizedDescription
        }
    }
}

extension Sync: CKSyncEngineDelegate {
    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            await MainActor.run { self.state(update.stateSerialization) }
        case .accountChange(let change):
            await MainActor.run { self.account(change) }
        case .fetchedDatabaseChanges(let changes):
            let gone = changes.deletions.contains { $0.zoneID == Sync.zoneID }
            if gone { await MainActor.run { self.zoneGone() } }
        case .fetchedRecordZoneChanges(let changes):
            await MainActor.run {
                for modification in changes.modifications { self.apply(modification.record) }
                for deletion in changes.deletions { self.removed(deletion.recordID.recordName) }
            }
        case .sentRecordZoneChanges(let changes):
            await MainActor.run { self.sent(changes) }
        default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.record(for: id) }
        }
    }
}

// MARK: - bookmarks

/// The Mac's bookmarks, here: folders and sites, kept in a small file and,
/// with sync on, the same on every device.
@MainActor
final class Bookmarks: ObservableObject {
    static let shared = Bookmarks()

    @Published private(set) var roots: [Bookmark] = []

    private static var file: URL { Store.file("bookmarks.json") }

    private init() {
        if let data = try? Data(contentsOf: Bookmarks.file),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            roots = saved
        }
    }

    func add(_ url: URL, title: String) {
        roots.append(Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString))
        changed()
    }

    func remove(_ id: Bookmark.ID) {
        roots = Bookmarks.removing(id, from: roots)
        if roots.isEmpty { emptiedByHand = true }
        changed()
    }

    /// The last bookmark was taken away here, on purpose: an empty list may
    /// go up then, and only then.
    private(set) var emptiedByHand = false

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Bookmarks.flat(roots).contains { $0.url == url.absoluteString }
    }

    /// From iCloud: kept here; it goes back up only if it differs from
    /// what came (a first join's union).
    func adopt(_ fresh: [Bookmark]) {
        guard fresh != roots else { return }
        // Anything that would go: a copy first, kept beside the file, so a
        // list emptied elsewhere can always be had back.
        let losing = Set(Bookmarks.flat(roots).map(\.id)).subtracting(Bookmarks.flat(fresh).map(\.id))
        if !losing.isEmpty, let data = try? JSONEncoder().encode(roots) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? data.write(to: Store.file("bookmarks.before-\(stamp).json"), options: .atomic)
        }
        roots = fresh
        if !fresh.isEmpty { emptiedByHand = false }
        write()
        Sync.shared.putBookmarks(roots)
    }

    private func changed() {
        write()
        Sync.shared.putBookmarks(roots)
    }

    /// One after the other, never two at once landing in the wrong order.
    private static let writing = DispatchQueue(label: "bookmarks.write", qos: .utility)

    private func write() {
        let list = roots
        let file = Bookmarks.file
        Bookmarks.writing.async {
            guard let data = try? JSONEncoder().encode(list) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    static func flat(_ nodes: [Bookmark]) -> [Bookmark] {
        nodes.flatMap { node in [node] + flat(node.children ?? []) }
    }

    private static func removing(_ id: Bookmark.ID, from nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            guard node.id != id else { return nil }
            var node = node
            if let children = node.children { node.children = removing(id, from: children) }
            return node
        }
    }

    /// Two sets of bookmarks, together: theirs first, then each of ours
    /// that isn't already there by id or by address.
    static func union(_ theirs: [Bookmark], _ ours: [Bookmark]) -> [Bookmark] {
        let known = flat(theirs)
        let ids = Set(known.map(\.id))
        let urls = Set(known.compactMap(\.url))
        return theirs + ours.filter { !ids.contains($0.id) && ($0.url.map { !urls.contains($0) } ?? true) }
    }
}

// MARK: - the browser's side

extension Browser {
    /// This device's open tabs, as the others see them.
    var deviceTabs: DeviceTabs {
        DeviceTabs(
            name: UIDevice.current.model,
            platform: "ios",
            at: Date(),
            tabs: tabs.compactMap { tab in
                guard !tab.isPrivate, tab.pin == nil, let url = tab.address, url.scheme?.hasPrefix("http") == true
                else { return nil }
                return DeviceTabs.Page(url: url.absoluteString, title: tab.title)
            }
        )
    }

    /// The pins here, as the Mac keeps them.
    var pinDefs: [PinDef] {
        tabs.compactMap { tab in
            guard let letter = tab.pin else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            let home = tab.pinHome ?? tab.address
            return PinDef(id: tab.pinID!, letter: letter, home: home?.absoluteString ?? "", title: tab.title, name: tab.pinName)
        }
    }

    /// Pins from iCloud: the same ones, in the same order, here.
    func adopt(pins defs: [PinDef]) {
        objectWillChange.send()
        var kept: [Tab] = []
        var pinned = tabs.filter { $0.pin != nil }
        for def in defs {
            let home = URL(string: def.home)
            if let index = pinned.firstIndex(where: { $0.pinID == def.id })
                ?? pinned.firstIndex(where: { $0.pinID == nil && ($0.pinHome ?? $0.address) == home }) {
                let tab = pinned.remove(at: index)
                tab.pinID = def.id
                tab.pin = def.letter
                tab.pinName = def.name
                tab.pinHome = home
                kept.append(tab)
            } else if let home {
                let tab = Tab()
                bring(tab)
                tab.pin = def.letter
                tab.pinID = def.id
                tab.pinName = def.name
                tab.pinHome = home
                tab.restore(home, title: def.title)
                tab.icon = Favicons.shared.cached(home)
                if tab.icon == nil { Favicons.shared.prefetch(home) }
                kept.append(tab)
            }
        }
        // Pins gone elsewhere: their tabs stay, unpinned.
        for tab in pinned { tab.pin = nil; tab.pinID = nil; tab.pinHome = nil; tab.pinName = nil }
        let loose = tabs.filter { $0.pin == nil && !kept.contains($0) }
        let next = kept + loose
        if next.map(\.id) != tabs.map(\.id) || !pinned.isEmpty {
            setTabs(next)
        }
        remember()
    }
}

extension Prefs {
    var shared: SharedSettings {
        SharedSettings(engine: engine.rawValue, custom: customEngine, suggest: customSuggest, look: look.rawValue)
    }

    func adopt(_ settings: SharedSettings) {
        if let raw = settings.engine, let engine = Engine(rawValue: raw), engine != self.engine { self.engine = engine }
        if let custom = settings.custom, custom != customEngine { customEngine = custom }
        if let suggest = settings.suggest { customSuggest = suggest }
        if let raw = settings.look, let look = Look(rawValue: raw), look != self.look { self.look = look }
    }
}

// MARK: - what shows

/// The other devices' open tabs: one tap opens one here.
struct OtherTabs: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var sync = Sync.shared
    @Environment(\.dismiss) private var done

    private var devices: [(String, DeviceTabs)] {
        // Every device that has synced, even with nothing open: hidden, a
        // Mac whose tabs are all in another profile (only Personal syncs)
        // looked the same as a Mac that never synced (26 Nov).
        sync.others.sorted { $0.value.at > $1.value.at }
    }

    var body: some View {
        NavigationStack {
            List {
                if devices.isEmpty {
                    Text("Nothing open on your other devices, or they haven't synced yet.")
                        .foregroundStyle(Palette.muted)
                }
                ForEach(devices, id: \.0) { _, device in
                    Section {
                        if device.tabs.isEmpty {
                            Text(device.platform == "macos"
                                ? String(localized: "No open tabs. On a Mac, only the Personal profile's tabs come here.")
                                : String(localized: "No open tabs."))
                                .font(.scaled(14))
                                .foregroundStyle(Palette.muted)
                        }
                        ForEach(device.tabs, id: \.self) { page in
                            Button {
                                Feel.tick()
                                if let url = URL(string: page.url) { browser.open(url) }
                                done()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.title.isEmpty ? page.url : page.title)
                                        .font(.scaled(15))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                    Text(URL(string: page.url).map { Address.host($0) } ?? page.url)
                                        .font(.scaled(12.5))
                                        .foregroundStyle(Palette.muted)
                                        .lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text(device.name.isEmpty ? (device.platform == "macos" ? String(localized: "On your Mac") : String(localized: "On another device")) : String(localized: "On \(device.name)"))
                    } footer: {
                        Text(device.at.formatted(.relative(presentation: .named)))
                    }
                }
            }
            .navigationTitle("Other devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { done() } }
            }
            .refreshable { sync.refresh() }
        }
        .tint(Palette.ink)
    }
}

/// The bookmarks: folders open, sites open in a tab, the page in front can
/// be added, and a swipe takes one away.
struct BookmarksView: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var store = Bookmarks.shared
    @Environment(\.dismiss) private var done

    /// Opened from a folder on New tab: that folder, Bookmarks behind it.
    @State private var path: [Bookmark.ID]

    init(browser: Browser) {
        self.browser = browser
        _path = State(initialValue: browser.bookmarkFolder.map { [$0] } ?? [])
        browser.bookmarkFolder = nil
    }

    var body: some View {
        NavigationStack(path: $path) {
            Folder(browser: browser, nodes: store.roots, done: { done() })
                .navigationTitle("Bookmarks")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: Bookmark.ID.self) { id in
                    let node = Bookmarks.flat(store.roots).first { $0.id == id }
                    Folder(browser: browser, nodes: node?.children ?? [], done: { done() })
                        .navigationTitle(node?.title ?? "")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { done() } }
                    if let tab = browser.active, let url = tab.address, !tab.isPrivate, !store.contains(url) {
                        ToolbarItem(placement: .bottomBar) {
                            Button {
                                Feel.tick()
                                store.add(url, title: tab.title)
                            } label: {
                                Label("Add this page", systemImage: "plus")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
        }
        .tint(Palette.ink)
    }

    private struct Folder: View {
        @ObservedObject var browser: Browser
        let nodes: [Bookmark]
        let done: () -> Void

        var body: some View {
            List {
                if nodes.isEmpty {
                    Text(Prefs.shared.sync
                         ? "No bookmarks yet. Add the page you're on; the ones you keep in Search on your Mac show here too."
                         : "No bookmarks yet. Add the page you're on, or turn on sync to bring your Mac's.")
                        .foregroundStyle(Palette.muted)
                }
                ForEach(nodes) { node in
                    if node.isFolder {
                        NavigationLink(value: node.id) {
                            // Its name where the sites' names are.
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.scaled(17))
                                    .frame(width: 24, height: 24)
                                Text(node.title).font(.scaled(15)).lineLimit(1)
                            }
                        }
                    } else {
                        Button {
                            Feel.tick()
                            if let url = node.url.flatMap(URL.init(string:)) { browser.open(url) }
                            done()
                        } label: {
                            HStack(spacing: 12) {
                                SiteIcon(url: node.url.flatMap(URL.init(string:)), size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(node.title).font(.scaled(15)).foregroundStyle(Palette.ink).lineLimit(1)
                                    if let url = node.url.flatMap(URL.init(string:)) {
                                        Text(Address.host(url)).font(.scaled(12.5)).foregroundStyle(Palette.muted)
                                    }
                                }
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { Bookmarks.shared.remove(nodes[index].id) }
                }
            }
        }
    }
}


/// A site's own small icon, the one its tab wears: the letter until it is
/// there. Fetched once and kept (Favicons), then drawn at once.
struct SiteIcon: View {
    let url: URL?
    var size: CGFloat = 24
    @State private var icon: UIImage?

    var body: some View {
        Mark(icon: icon, letter: String((url.map { Address.host($0) } ?? "").prefix(1)).uppercased(), size: size)
            .onAppear(perform: load)
            .onReceive(NotificationCenter.default.publisher(for: Favicons.came)) { _ in load() }
    }

    private func load() {
        guard let url else { return }
        if let found = Favicons.shared.cached(url) {
            if icon == nil { icon = found }
        } else {
            Favicons.shared.prefetch(url)
        }
    }
}
