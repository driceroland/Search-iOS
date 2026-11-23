import SwiftUI
import UIKit
import WebKit

// What a page hands over instead of showing: kept in the app's own Downloads
// folder (which the Files app shows, under On My iPhone › Search), and offered
// to be saved anywhere else the moment it arrives.

@MainActor
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()

    private weak var browser: Browser?
    private var landing: [ObjectIdentifier: URL] = [:]

    /// The button beside the bar: there only while something downloads, and
    /// a little while after, to save or share what came.
    enum Shown: Equatable {
        case going
        case done(URL)
        case failed
    }
    @Published private(set) var shown: Shown?
    /// How far along, apart from `shown`: the ring alone redraws as it
    /// fills, never the menu under the finger.
    let part = Part()
    final class Part: ObservableObject { @Published var value: Double = 0 }
    private var going: [ObjectIdentifier: WKDownload] = [:]
    private var watching: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var leave: DispatchWorkItem?

    /// Everything under way, as one fraction.
    private func progress() {
        let all = going.values.map(\.progress)
        guard !all.isEmpty else { return }
        let done = all.reduce(0.0) { $0 + ($1.totalUnitCount > 0 ? $1.fractionCompleted : 0.05) }
        part.value = min(1, done / Double(all.count))
        if shown != .going { set(.going) }
    }

    private func set(_ next: Shown?, for seconds: Double? = nil) {
        leave?.cancel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) { shown = next }
        guard let seconds else { return }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) { self?.shown = nil }
        }
        leave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The button tapped or its menu used: it goes.
    func dismiss() { set(nil) }

    /// Everything under way, stopped; what had come is thrown away.
    func cancel() {
        for (key, download) in going {
            watching.removeValue(forKey: key)?.invalidate()
            let file = landing.removeValue(forKey: key)
            // Thrown away once WebKit has let go of it: before, it went on
            // writing and the half file stayed in Files.
            download.cancel { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let file { try? FileManager.default.removeItem(at: file) }
                }
            }
        }
        going = [:]
        Feel.tick()
        set(nil)
    }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    func take(_ download: WKDownload, from browser: Browser) {
        self.browser = browser
        download.delegate = self
        Feel.tick()
        let key = ObjectIdentifier(download)
        going[key] = download
        watching[key] = download.progress.observe(\.fractionCompleted) { [weak self] _, _ in
            Task { @MainActor in self?.progress() }
        }
        part.value = 0
        set(.going)
    }

    private func finished(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        going.removeValue(forKey: key)
        watching.removeValue(forKey: key)?.invalidate()
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
        finished(download)
        guard let file = landing.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Feel.done()
        if going.isEmpty {
            // Arrived: a tick in the button, to save or share it, for a
            // while; then it melts away. The file stays in Files › Search.
            set(.done(file), for: 12)
        } else {
            progress()
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // Stopped from the button: nothing to say.
        guard going[ObjectIdentifier(download)] != nil else { return }
        finished(download)
        landing.removeValue(forKey: ObjectIdentifier(download))
        Feel.refuse()
        browser?.say(String(localized: "The download didn't finish"))
        if going.isEmpty { set(.failed, for: 3) } else { progress() }
    }
}

/// UIKit's own sheets, from wherever SwiftUI is.
@MainActor
enum Present {
    static func share(_ items: [Any], extra: [UIActivity]? = nil) {
        guard let top = top() else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: extra)
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

/// "Save as PDF" in the share sheet: the whole page, as one PDF, to Files.
final class PDFActivity: UIActivity {
    private weak var tab: Tab?

    @MainActor init(tab: Tab) {
        self.tab = tab
        super.init()
    }

    override var activityTitle: String? { "Save as PDF" }
    override var activityImage: UIImage? { UIImage(systemName: "doc.richtext") }
    override var activityType: UIActivity.ActivityType? { .init("com.officecommun.search.pdf") }
    override class var activityCategory: UIActivity.Category { .action }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        MainActor.assumeIsolated {
            guard let tab else {
                activityDidFinish(false)
                return
            }
            let name = (tab.title.isEmpty ? "Page" : tab.title)
                .replacingOccurrences(of: "/", with: "-")
                .prefix(80)
            tab.web.createPDF { [weak self] result in
                guard case .success(let data) = result else {
                    self?.activityDidFinish(false)
                    return
                }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".pdf")
                try? data.write(to: file, options: .atomic)
                self?.activityDidFinish(true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { Present.export(file) }
            }
        }
    }
}


/// The download button beside the bar, by the thumb: a ring filling while a
/// file comes, a tick once it's here (tap to save it or share it), then gone.
struct DownloadButton: View {
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        if let shown = downloads.shown {
            Menu {
                if case .done(let file) = shown {
                    Button {
                        downloads.dismiss()
                        Present.export(file)
                    } label: { Label("Save to Files", systemImage: "folder") }
                    Button {
                        downloads.dismiss()
                        Present.share([file])
                    } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                } else if case .going = shown {
                    Button(role: .destructive) { downloads.cancel() } label: {
                        Label("Stop Download", systemImage: "xmark")
                    }
                }
            } label: {
                ZStack {
                    switch shown {
                    case .going:
                        Filling(part: downloads.part)
                    case .done:
                        Image(systemName: "checkmark")
                            .font(.scaled(15, weight: .semibold))
                            .transition(.scale.combined(with: .opacity))
                    case .failed:
                        Image(systemName: "exclamationmark")
                            .font(.scaled(15, weight: .semibold))
                    }
                }
                .foregroundStyle(Palette.ink)
                .frame(width: 44, height: 44)
                .glass(Circle(), interactive: true, else: .clear)
                .background { if #unavailable(iOS 26.0) { Glass(shape: Circle()) } }
                .contentShape(Circle())
            }
            .accessibilityLabel("Downloads")
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}

/// The ring, filling as the file comes.
private struct Filling: View {
    @ObservedObject var part: Downloads.Part

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.faint.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.04, part.value))
                .stroke(Palette.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: part.value)
            Image(systemName: "arrow.down")
                .font(.scaled(11, weight: .bold))
        }
        .frame(width: 26, height: 26)
    }
}
