import SwiftUI
import LocalAuthentication

// A keyboard on the iPhone or an iPad: the Mac's shortcuts, nothing on screen.
// Asked of the app delegate, the last stop of every key press, so they work
// whatever has the caret.

final class Shortcuts: UIResponder, UIApplicationDelegate {
    @MainActor static weak var browser: Browser?

    /// Portrait, the way the app is drawn, except while a video fills the
    /// screen: then the phone can be turned.
    @MainActor static var turning = false {
        didSet {
            guard turning != oldValue else { return }
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !turning, !onPad {
                scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad || Shortcuts.onPad { return .all }
        return MainActor.assumeIsolated { Shortcuts.turning } ? .allButUpsideDown : .portrait
    }

    /// Run on an iPad as an iPhone app: the idiom says phone, the hardware
    /// says iPad. Held to portrait there, the app shows up turned on its side
    /// when the iPad is held the long way, so it turns with the iPad instead.
    static let onPad: Bool = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return machine.hasPrefix("iPad")
    }()

    override var keyCommands: [UIKeyCommand]? {
        var keys: [UIKeyCommand] = [
            command("New Tab", "t", .command, #selector(newTab)),
            command("New Private Tab", "n", [.command, .shift], #selector(newPrivate)),
            command("Close Tab", "w", .command, #selector(closeTab)),
            command("Reopen Closed Tab", "t", [.command, .shift], #selector(reopen)),
            command("Open Location", "l", .command, #selector(location)),
            command("Reload", "r", .command, #selector(reload)),
            command("Stop", ".", .command, #selector(stop)),
            command("Back", "[", .command, #selector(back)),
            command("Forward", "]", .command, #selector(forward)),
            command("Find", "f", .command, #selector(findOnPage)),
            command("Show All Tabs", "\\", [.command, .shift], #selector(allTabs)),
            command("Next Tab", "\t", .control, #selector(nextTab)),
            command("Previous Tab", "\t", [.control, .shift], #selector(previousTab)),
            command("Bigger Text", "=", .command, #selector(bigger)),
            command("Smaller Text", "-", .command, #selector(smaller)),
            command("Actual Size", "0", .command, #selector(actual)),
            command("Pin Tab", "d", .command, #selector(pin)),
        ]
        for number in 1...9 {
            keys.append(command("Tab \(number)", "\(number)", .command, #selector(tabNumber(_:))))
        }
        return keys
    }

    private func command(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
        let key = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
        key.wantsPriorityOverSystemBehavior = true
        return key
    }

    @MainActor private func on(_ act: (Browser) -> Void) {
        guard let browser = Shortcuts.browser else { return }
        act(browser)
    }

    @objc func newTab() { MainActor.assumeIsolated { on { $0.newTab() } } }
    @objc func newPrivate() { MainActor.assumeIsolated { on { $0.newTab(private: true) } } }
    @objc func closeTab() { MainActor.assumeIsolated { on { b in b.active.map(b.close) } } }
    @objc func reopen() { MainActor.assumeIsolated { on { $0.reopen() } } }
    @objc func location() { MainActor.assumeIsolated { on { $0.edit() } } }
    @objc func reload() { MainActor.assumeIsolated { on { $0.active?.reload() } } }
    @objc func stop() { MainActor.assumeIsolated { on { $0.active?.stop() } } }
    @objc func back() { MainActor.assumeIsolated { on { $0.active?.back() } } }
    @objc func forward() { MainActor.assumeIsolated { on { $0.active?.forward() } } }
    @objc func findOnPage() { MainActor.assumeIsolated { on { b in b.active.map(b.find) } } }
    @objc func allTabs() { MainActor.assumeIsolated { on { $0.showingTabs.toggle() } } }
    @objc func nextTab() { MainActor.assumeIsolated { on { b in b.step(1) } } }
    @objc func previousTab() { MainActor.assumeIsolated { on { b in b.step(-1) } } }
    @objc func bigger() { MainActor.assumeIsolated { on { b in b.active.map { b.zoom($0, step: 1) } } } }
    @objc func smaller() { MainActor.assumeIsolated { on { b in b.active.map { b.zoom($0, step: -1) } } } }
    @objc func actual() { MainActor.assumeIsolated { on { b in b.active.map { b.zoom($0, step: 0) } } } }
    @objc func pin() { MainActor.assumeIsolated { on { b in b.active.map(b.pin) } } }
    @objc func tabNumber(_ sender: UIKeyCommand) {
        let number = Int(sender.input ?? "") ?? 1
        MainActor.assumeIsolated {
            on { b in
                // ⌘9 is the last tab, as everywhere.
                let index = number == 9 ? b.tabs.count - 1 : number - 1
                if b.tabs.indices.contains(index) { b.select(b.tabs[index]) }
            }
        }
    }
}

extension Browser {
    /// The tab next to this one, round the ends.
    func step(_ by: Int) {
        guard let here = activeIndex, !tabs.isEmpty else { return }
        select(tabs[(here + by + tabs.count) % tabs.count])
    }

    // MARK: - private tabs behind Face ID

    /// Search going to the background with private tabs open: they lock,
    /// when that was asked for.
    func lock() {
        guard Prefs.shared.lockPrivate, tabs.contains(where: \.isPrivate) else { return }
        locked = true
    }

    /// Back in front on a private tab: asked at once.
    func askToUnlock() {
        // Only where a private tab is on screen: the private side of the
        // tabs, or a private page. Never over the other tabs.
        let onScreen = showingTabs ? privateView : active?.isPrivate == true
        guard locked, onScreen else { return }
        unlock()
    }

    func unlock() {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            // No passcode on this iPhone: nothing to ask with.
            locked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Unlock your private tabs")) { ok, _ in
            DispatchQueue.main.async { [weak self] in
                if ok { withAnimation(Motion.settle) { self?.locked = false } }
            }
        }
    }
}

/// Over a private page while it is locked.
struct Locked: View {
    @ObservedObject var browser: Browser

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            VStack(spacing: 14) {
                Image(systemName: "eyeglasses")
                    .font(.scaled(22, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Text("Private tabs are locked")
                    .font(.scaled(16))
                    .foregroundStyle(Palette.ink)
                Button {
                    browser.unlock()
                } label: {
                    Text("Unlock")
                        .font(.scaled(15, weight: .medium))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Palette.wash, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
            }
        }
        .ignoresSafeArea()
    }
}
