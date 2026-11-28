import SwiftUI
import WebKit

/// Settings: a short list, in the system's own form, the way the Mac's is a
/// short window. Reached from the gear at the foot of the sheet of tabs.
struct Settings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.dismiss) private var done

    @State private var askingData = false
    @State private var askingHistory = false
    @State private var askingErase = false
    @ObservedObject private var sync = Sync.shared
    @ObservedObject private var lists = Lists.shared

    var body: some View {
        NavigationStack {
            Form {
                DefaultBrowserSection()

                Section {
                    Picker("Search with", selection: $prefs.engine) {
                        ForEach(Engine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    if prefs.engine == .custom {
                        TextField("https://example.com/search?q=%s", text: $prefs.customEngine)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.scaled(15))
                            .foregroundStyle(Engine.accepts(prefs.customEngine) || prefs.customEngine.isEmpty ? Palette.ink : .red)
                    }
                    Toggle("Search suggestions", isOn: $prefs.engineSuggestions).tint(.green)
                } footer: {
                    if prefs.engineSuggestions {
                        Text("What you type is sent to \(prefs.engine.name(custom: prefs.customEngine)) as you type, so it can suggest searches. Never from private tabs.")
                    } else {
                        Text("Words typed in the field go to this search when they aren't an address. Nothing you type is sent anywhere until you press Go.")
                    }
                }

                Section {
                    Toggle("Bookmarks", isOn: $prefs.startBookmarks).tint(.green)
                    Toggle("Often visited", isOn: $prefs.startOften).tint(.green)
                } header: {
                    Text("On New tab")
                } footer: {
                    Text("The sites shown above the field on a new tab. Off, a new tab is the field alone.")
                }

                Section {
                    Picker("Close tabs", selection: $prefs.autoClose) {
                        ForEach(AutoClose.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Lock private tabs", isOn: $prefs.lockPrivate).tint(.green)
                } footer: {
                    Text("Tabs you haven't looked at for that long close by themselves; pinned tabs never do. Locked private tabs ask for Face ID when you come back to Search.")
                }

                Section {
                    Toggle("Block ads and trackers", isOn: $prefs.shield).tint(.green)
                        .onChange(of: prefs.shield) { _, _ in
                            Shield.shared.apply(to: browser.tabs.map { $0.web.configuration.userContentController })
                        }
                    if prefs.shield {
                        Toggle("Stronger ad blocking", isOn: $lists.enabled).tint(.green)
                        if lists.enabled {
                            ListsStatus(lists: lists)
                        }
                    }
                } footer: {
                    if prefs.shield, lists.enabled {
                        Text("uBlock Origin's lists, EasyList, EasyPrivacy, Peter Lowe's list and wBlock's, downloaded from ublockorigin.github.io, pgl.yoyo.org and raw.githubusercontent.com, and again each week. Nothing about you is sent. If a site breaks, hold the address and allow ads on that site alone.")
                    } else {
                        Text("Third-party ad networks and trackers are stopped before they load. If a site breaks, hold the address and allow ads on that site alone.")
                    }
                }

                Section {
                    Toggle("Sync with iCloud", isOn: $prefs.sync).tint(.green)
                    if prefs.sync {
                        Toggle("Pins from the Mac", isOn: Binding(
                            get: { prefs.syncPins },
                            set: { sync.syncPins($0) }
                        )).tint(.green)
                    }
                    if prefs.sync, prefs.syncPins, sync.spaces.count > 1 {
                        Picker("Pins from", selection: Binding(
                            get: { sync.pinSpace },
                            set: { sync.choose(space: $0) }
                        )) {
                            ForEach(sync.spaces) { Text($0.name).tag($0.id) }
                        }
                    }
                    if prefs.sync, let problem = sync.problem {
                        Text(problem).foregroundStyle(Palette.muted)
                    }
                    Button("Delete Search's Data from iCloud", role: .destructive) {
                        askingErase = true
                    }
                } footer: {
                    Text("Your open tabs, pins, bookmarks, search engine and appearance, the same on your iPhone and your Mac, through your own iCloud. Encrypted end to end: nobody else, us included, can read it. Private tabs never.")
                }

                Section {
                    Toggle("Handoff", isOn: $prefs.handoff).tint(.green)
                } footer: {
                    Text("The page you're on shows up on your Mac, and your Mac's page here, through Apple's Handoff: your own devices, nearby, on the same Apple Account. Private tabs never. Handoff itself keeps nothing.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $prefs.look) {
                        ForEach(Look.allCases) { look in
                            Text(look.title).tag(look)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if browser.roomy {
                    Section {
                        Toggle("Sidebar", isOn: $prefs.sidebar)
                    } footer: {
                        Text("The pins and the tabs beside the page, as on the Mac, while the screen is wide enough.")
                    }
                }

                Section {
                    Button("Clear History…") {
                        askingHistory = true
                    }
                    Button("Clear Cookies and Website Data", role: .destructive) {
                        askingData = true
                    }
                } footer: {
                    Text("History, icons and site data live on this iPhone and nowhere else, even with sync on.")
                }

                Section {
                    Link("Search is open source", destination: URL(string: "https://github.com/driceroland/Search-iOS")!)
                    LabeledContent("Version", value: Self.version)
                } footer: {
                    Text("By Office Commun. No telemetry, no analytics, no crash reports: the only things that leave your iPhone are the pages you ask for and their icons, and the ad blocking lists if you turn them on.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                }
            }
            .confirmationDialog(
                "Your tabs, pins, bookmarks and settings leave iCloud, for every device. What is on each device stays.",
                isPresented: $askingErase, titleVisibility: .visible
            ) {
                Button("Delete from iCloud", role: .destructive) {
                    prefs.sync = false
                    sync.erase()
                    browser.say(String(localized: "Deleted from iCloud"))
                }
            }
            .confirmationDialog(
                "Clear the history of…", isPresented: $askingHistory, titleVisibility: .visible
            ) {
                Button("The last hour") { clear(since: Date().addingTimeInterval(-3600)) }
                Button("Today") { clear(since: Calendar.current.startOfDay(for: Date())) }
                Button("Today and yesterday") {
                    clear(since: Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!)
                }
                Button("All time", role: .destructive) { clear(since: nil) }
            }
            .confirmationDialog(
                "Every site you're signed in to will sign you out.",
                isPresented: $askingData, titleVisibility: .visible
            ) {
                Button("Clear Cookies and Website Data", role: .destructive) {
                    WKWebsiteDataStore.default().removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast
                    ) {
                        browser.say(String(localized: "Website data cleared"))
                    }
                }
            }
        }
        .tint(Palette.ink)
    }

    /// History from a moment on, or all of it; all of it takes the icons too.
    private func clear(since moment: Date?) {
        if let moment {
            browser.history.forget(since: moment)
        } else {
            browser.history.forget()
            Favicons.shared.forgetAll()
        }
        browser.forgetClosed()
        Feel.tick()
        browser.say(String(localized: "History cleared"))
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// Where the stronger lists are at: being made, made (when, and how many
/// rules), or not made, with the way to try again.
struct ListsStatus: View {
    @ObservedObject var lists: Lists

    var body: some View {
        if lists.working {
            HStack(spacing: 10) {
                ProgressView()
                Text("Downloading and preparing the lists…")
            }
            .foregroundStyle(Palette.muted)
        } else if let problem = lists.problem {
            Text(problem).foregroundStyle(Palette.muted)
            Button("Try Again") { lists.refresh() }
        } else if let updated = lists.updated {
            Text("\(lists.rules.formatted()) rules, updated \(updated.formatted(.relative(presentation: .named)))")
                .foregroundStyle(Palette.muted)
        }
    }
}

/// Search as the iPhone's browser, once Apple lets it be one: whether it is,
/// and the way to the system's own switch (an app can't set itself).
/// Hidden until the build carries the default browser entitlement, which
/// is when iOS lists Search at all.
struct DefaultBrowserSection: View {
    @State private var status: Bool?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        if DefaultBrowser.eligible {
            Section {
                Button {
                    DefaultBrowser.openSettings()
                } label: {
                    HStack {
                        Text("Default browser app")
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Text(status == true ? "Search" : status == false ? "Another app" : "")
                            .foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.right")
                            .font(.scaled(12, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                    }
                }
            } footer: {
                Text(status == true
                     ? "Links you tap in other apps open here."
                     : "Make Search the app links open in: choose it in the list Settings shows.")
            }
            .task(id: phase) { status = DefaultBrowser.isDefault() }
        }
    }
}

enum DefaultBrowser {
    /// This build may be the default browser: it carries the entitlement.
    /// Built with DEFAULT_BROWSER, which goes with Search.browser.entitlements
    /// (see CHECKLIST.md): the two are switched on together.
    static var eligible: Bool {
        #if DEFAULT_BROWSER
        return true
        #else
        return false
        #endif
    }

    /// Asked of the system, which allows only a few asks a day: nil when
    /// it won't say.
    static func isDefault() -> Bool? {
        if #available(iOS 18.2, *) {
            return try? UIApplication.shared.isDefault(.webBrowser)
        }
        return nil
    }

    /// Settings, at the list of default apps where it can.
    static func openSettings() {
        let address: String
        if #available(iOS 18.3, *) {
            address = UIApplication.openDefaultApplicationsSettingsURLString
        } else {
            address = UIApplication.openSettingsURLString
        }
        if let url = URL(string: address) { UIApplication.shared.open(url) }
    }
}
