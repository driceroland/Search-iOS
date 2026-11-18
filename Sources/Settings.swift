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

    var body: some View {
        NavigationStack {
            Form {
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
                    Toggle("Search suggestions", isOn: $prefs.engineSuggestions)
                } footer: {
                    Text(prefs.engineSuggestions
                         ? "What you type is sent to \(prefs.engine.name(custom: prefs.customEngine)) as you type, so it can suggest searches. Never from private tabs."
                         : "Words typed in the field go to this search when they aren't an address. Nothing you type is sent anywhere until you press Go.")
                }

                Section {
                    Picker("Close tabs", selection: $prefs.autoClose) {
                        ForEach(AutoClose.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Lock private tabs", isOn: $prefs.lockPrivate)
                } footer: {
                    Text("Tabs you haven't looked at for that long close by themselves; pinned tabs never do. Locked private tabs ask for Face ID when you come back to Search.")
                }

                Section {
                    Toggle("Block ads and trackers", isOn: $prefs.shield)
                        .onChange(of: prefs.shield) { _, _ in
                            Shield.shared.apply(to: browser.tabs.map { $0.web.configuration.userContentController })
                        }
                } footer: {
                    Text("Third-party ad networks and trackers are stopped before they load. If a site breaks, hold the address and allow ads on that site alone.")
                }

                Section {
                    Toggle("Sync with iCloud", isOn: $prefs.sync)
                    if prefs.sync, sync.spaces.count > 1 {
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
                    Toggle("Handoff", isOn: $prefs.handoff)
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
                    Text("By Office Commun. No telemetry, no analytics, no crash reports: the only things that leave your iPhone are the pages you ask for and their icons.")
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
                    browser.say("Deleted from iCloud")
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
                        browser.say("Website data cleared")
                    }
                }
            }
        }
        .tint(Palette.ink)
        .preferredColorScheme(prefs.look.scheme)
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
        browser.say("History cleared")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}
