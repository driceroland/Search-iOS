import UIKit
import WebKit

// What a page hands over instead of showing: kept in the app's own Downloads
// folder (which the Files app shows, under On My iPhone › Search), and offered
// to be saved anywhere else the moment it arrives.

@MainActor
final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()

    private weak var browser: Browser?
    private var landing: [ObjectIdentifier: URL] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    func take(_ download: WKDownload, from browser: Browser) {
        self.browser = browser
        download.delegate = self
        Feel.tick()
        browser.say("Downloading…")
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let folder = Downloads.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "Download" : suggestedFilename
        // Never over a file already there: "name 2.pdf", "name 3.pdf"…
        var target = folder.appendingPathComponent(name)
        let stem = target.deletingPathExtension().lastPathComponent
        let kind = target.pathExtension
        var count = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(kind.isEmpty ? "\(stem) \(count)" : "\(stem) \(count).\(kind)")
            count += 1
        }
        landing[ObjectIdentifier(download)] = target
        return target
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let file = landing.removeValue(forKey: ObjectIdentifier(download)) else { return }
        browser?.say("Downloaded \(file.lastPathComponent)")
        Present.export(file)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        landing.removeValue(forKey: ObjectIdentifier(download))
        Feel.refuse()
        browser?.say("The download didn't finish")
    }
}

/// UIKit's own sheets, from wherever SwiftUI is.
@MainActor
enum Present {
    static func share(_ items: [Any]) {
        guard let top = top() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 1, height: 1
        )
        top.present(sheet, animated: true)
    }

    /// "Save to Files", for a download that has just arrived.
    static func export(_ file: URL) {
        guard let top = top() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        top.present(picker, animated: true)
    }

    private static func top() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        var top = scene?.keyWindow?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
