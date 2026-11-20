import SwiftUI
import ObjectiveC

// The clock's colour, light or dark, following what is behind it: the page's
// own colour at the top, as in Safari, rather than the app's appearance.
// SwiftUI has no say in the status bar's style, so the root controller is
// taught to answer it.

@MainActor
enum StatusBar {
    private static var style: UIStatusBarStyle = .default
    private static var taught: Set<ObjectIdentifier> = []

    /// Light text on a dark colour, dark text on a light one; the system's
    /// own choice when there's nothing to go by.
    static func follow(_ colour: UIColor?, scheme: UIUserInterfaceStyle) {
        let next: UIStatusBarStyle
        if let colour {
            let resolved = colour.resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if resolved.getRed(&r, green: &g, blue: &b, alpha: &a), a > 0.5 {
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                next = luma < 0.55 ? .lightContent : .darkContent
            } else {
                next = .default
            }
        } else {
            next = .default
        }
        guard next != style else { return }
        style = next
        apply()
    }

    private static func apply() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows {
                guard let root = window.rootViewController else { continue }
                teach(type(of: root))
                root.setNeedsStatusBarAppearanceUpdate()
            }
        }
    }

    /// The hosting controller's class answers preferredStatusBarStyle with
    /// ours, once.
    private static func teach(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard !taught.contains(id) else { return }
        taught.insert(id)
        let selector = #selector(getter: UIViewController.preferredStatusBarStyle)
        let block: @convention(block) (UIViewController) -> UIStatusBarStyle = { _ in
            MainActor.assumeIsolated { StatusBar.style }
        }
        let imp = imp_implementationWithBlock(block)
        let types = method_getTypeEncoding(class_getInstanceMethod(UIViewController.self, selector)!)
        if !class_addMethod(cls, selector, imp, types) {
            if let method = class_getInstanceMethod(cls, selector) { method_setImplementation(method, imp) }
        }
    }
}
