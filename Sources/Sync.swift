import SwiftUI
import CloudKit

// Sync: the same open tabs, pins, bookmarks and a few settings on the
// iPhone and the Mac, through the person's own iCloud. Off until turned on.
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
        Task { await self.join() }
    }

    /// Off: this device's tabs leave the others, and nothing more goes up.
    func stop() {
        guard let engine else { return }
        let key = "device.\(meta.device)"
        meta.values[key] = nil
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(Sync.record(key))])
        Task {
            try? await engine.sendChanges()
            self.engine = nil
            self.others = [:]
            self.meta.joined = false
            self.save()
        }
    }

    /// Everything Search keeps in iCloud, gone, for every device.
    func erase() {
        let engine = self.engine ?? CKSyncEngine(CKSyncEngine.Configuration(
            database: CKContainer(identifier: Sync.containerID).privateCloudDatabase,
            stateSerialization: meta.state, delegate: self
        ))
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Sync.zoneID)])
        Task {
            try? await engine.sendChanges()
            self.engine = nil
            self.meta = Meta(device: self.meta.device)
            self.others = [:]
            self.spaces = []
            self.save()
        }
    }

    /// Back in front: anything new from the other devices.
    func refresh() {
        guard let engine else { return }
        Task { try? await engine.fetchChanges() }
    }

    /// The first fetch, then what is here goes up.
    private func join() async {
        guard let engine else { return }
        do {
            try await engine.fetchChanges()
            problem = nil
        } catch {
            problem = Sync.say(error)
        }
        meta.joined = true
        save()
        browser.map(publish)
    }

    // MARK: what changes here

    /// Everything this device has, offered: only what differs goes up.
    func publish(_ browser: Browser) {
        guard meta.joined else { return }
        put("device.\(meta.device)", browser.deviceTabs)
        put("pins.\(pinSpace)", browser.pinDefs)
        put("bookmarks", Bookmarks.shared.roots)
        put("settings", Prefs.shared.shared)
    }

    func put<T: Encodable>(_ key: String, _ value: T) {
        guard let engine, meta.joined, let data = try? Sync.encoder.encode(value) else { return }
        guard meta.values[key] != data else { return }
        meta.values[key] = data
        meta.at[key] = Date()
        save()
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(Sync.record(key))])
    }

    /// The space whose pins this iPhone shows.
    var pinSpace: UUID {
        Prefs.shared.syncSpace.flatMap(UUID.init(uuidString:)) ?? Sync.firstSpace
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
        if let ours = meta.at[key], ours > at, meta.values[key] != nil {
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
            canonical(defs)
            guard key == "pins.\(pinSpace)" else { save(); return }
            if first, let browser {
                // Joining: these pins and the ones already here, together.
                for mine in browser.pinDefs where !defs.contains(where: { $0.id == mine.id || $0.home == mine.home }) {
                    defs.append(mine)
                }
                meta.at[key] = .distantPast
            }
            browser?.adopt(pins: defs)
        } else if key == "bookmarks" {
            guard var roots = try? decoder.decode([Bookmark].self, from: data) else { return }
            canonical(roots)
            if first {
                roots = Bookmarks.union(roots, Bookmarks.shared.roots)
                meta.at[key] = .distantPast
            }
            Bookmarks.shared.adopt(roots)
        } else if key == "spaces" {
            spaces = (try? decoder.decode([SpaceInfo].self, from: data)) ?? []
            if spaces.count > 0, !spaces.contains(where: { $0.id == pinSpace }) {
                Prefs.shared.syncSpace = nil
            }
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
                problem = Sync.say(failure.error)
            }
        }
        save()
    }

    fileprivate func account(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            problem = nil
            Task { await join() }
        case .signOut, .switchAccounts:
            // Another person's iCloud, or none: nothing of the last one stays.
            meta = Meta(device: meta.device)
            others = [:]
            spaces = []
            problem = "Signed out of iCloud"
            save()
        @unknown default:
            break
        }
    }

    fileprivate func state(_ update: CKSyncEngine.State.Serialization) {
        meta.state = update
        save()
    }

    fileprivate func zoneGone() {
        meta = Meta(device: meta.device)
        others = [:]
        spaces = []
        save()
        engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Sync.zoneID))])
        Task { await join() }
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
        case .notAuthenticated: return "Sign in to iCloud in the iPhone's Settings to sync."
        case .quotaExceeded: return "Your iCloud is full."
        case .networkFailure, .networkUnavailable: return "Offline. Sync carries on when you're back."
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
        changed()
    }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Bookmarks.flat(roots).contains { $0.url == url.absoluteString }
    }

    /// From iCloud: kept here; it goes back up only if it differs from
    /// what came (a first join's union).
    func adopt(_ fresh: [Bookmark]) {
        guard fresh != roots else { return }
        roots = fresh
        write()
        Sync.shared.put("bookmarks", roots)
    }

    private func changed() {
        write()
        Sync.shared.put("bookmarks", roots)
    }

    private func write() {
        let list = roots
        let file = Bookmarks.file
        DispatchQueue.global(qos: .utility).async {
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
        SharedSettings(engine: engine.rawValue, custom: customEngine, look: look.rawValue)
    }

    func adopt(_ settings: SharedSettings) {
        if let raw = settings.engine, let engine = Engine(rawValue: raw), engine != self.engine { self.engine = engine }
        if let custom = settings.custom, custom != customEngine { customEngine = custom }
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
        sync.others.sorted { $0.value.at > $1.value.at }.filter { !$0.value.tabs.isEmpty }
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
                        Text(device.platform == "macos" ? "On your Mac" : "On your \(device.name)")
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
        .preferredColorScheme(Prefs.shared.look.scheme)
    }
}

/// The bookmarks: folders open, sites open in a tab, the page in front can
/// be added, and a swipe takes one away.
struct BookmarksView: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var store = Bookmarks.shared
    @Environment(\.dismiss) private var done

    var body: some View {
        NavigationStack {
            Folder(browser: browser, nodes: store.roots, done: { done() })
                .navigationTitle("Bookmarks")
                .navigationBarTitleDisplayMode(.inline)
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
        .preferredColorScheme(Prefs.shared.look.scheme)
    }

    private struct Folder: View {
        @ObservedObject var browser: Browser
        let nodes: [Bookmark]
        let done: () -> Void

        var body: some View {
            List {
                if nodes.isEmpty {
                    Text("No bookmarks yet. Add the page you're on, or turn on sync to bring your Mac's.")
                        .foregroundStyle(Palette.muted)
                }
                ForEach(nodes) { node in
                    if node.isFolder {
                        NavigationLink {
                            Folder(browser: browser, nodes: node.children ?? [], done: done)
                                .navigationTitle(node.title)
                        } label: {
                            Label(node.title, systemImage: "folder")
                        }
                    } else {
                        Button {
                            Feel.tick()
                            if let url = node.url.flatMap(URL.init(string:)) { browser.open(url) }
                            done()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title).font(.scaled(15)).foregroundStyle(Palette.ink).lineLimit(1)
                                if let url = node.url.flatMap(URL.init(string:)) {
                                    Text(Address.host(url)).font(.scaled(12.5)).foregroundStyle(Palette.muted)
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
