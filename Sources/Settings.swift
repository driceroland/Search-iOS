import SwiftUI
import WebKit

/// Settings: a short list, in the system's own form, the way the Mac's is a
/// short window. Reached from the gear at the foot of the sheet of tabs.
struct Settings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.dismiss) private var done

    @State private var askingData = false

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
                            .font(.system(size: 15))
                            .foregroundStyle(Engine.accepts(prefs.customEngine) || prefs.customEngine.isEmpty ? Palette.ink : .red)
                    }
                } footer: {
                    Text("Words typed in the field go to this search when they aren't an address. Nothing you type is sent anywhere until you press Go.")
                }

                Section {
                    Toggle("Block ads and trackers", isOn: $prefs.shield)
                        .onChange(of: prefs.shield) { _, _ in
                            Shield.shared.apply(to: browser.tabs.map { $0.web.configuration.userContentController })
                        }
                } footer: {
                    Text("Third-party ad networks and trackers are stopped before they load. If a site breaks, hold the address and allow ads on that site alone.")
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
                    Button("Clear History") {
                        browser.history.forget()
                        Favicons.shared.forgetAll()
                        Feel.tick()
                        browser.say("History cleared")
                    }
                    Button("Clear Cookies and Website Data", role: .destructive) {
                        askingData = true
                    }
                } footer: {
                    Text("History, icons and site data live on this iPhone and nowhere else. There is no account and no sync.")
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

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}
