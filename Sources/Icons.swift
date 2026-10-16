import ImageIO
import SwiftUI
import WebKit

// A site's own icon, for the pill, the pins and the lines of the sheet.
//
// The Mac's way, rebuilt here (nothing is shared between the two): WebKit
// doesn't hand icons over, so the page is asked what it declares, the best of
// those is fetched once, and kept as a small PNG beside the history, under its
// host and port. A tab brought back from yesterday has its icon before it has
// a page; a site never seen before shows a letter until its icon arrives.

@MainActor
final class Favicons {
    static let shared = Favicons()

    /// Called with a key and its icon whenever one arrives, so every tab on
    /// that site can put it on at once.
    var arrived: ((String, UIImage) -> Void)?

    private var memory: [String: UIImage] = [:]
    private var busy: Set<String> = []
    private var missing: Set<String> = []
    private var absent: Set<String> = []

    private static var folder: URL { Store.folder.appendingPathComponent("icons", isDirectory: true) }
    private static func file(_ key: String) -> URL { folder.appendingPathComponent(key + ".png") }

    /// The name an icon is kept under: the host without "www.", and the port
    /// when there is one, so two local servers don't wear each other's icon.
    static func key(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map { "\(bare)_\($0)" } ?? bare
    }

    func forgetAll() {
        try? FileManager.default.removeItem(at: Favicons.folder)
        memory.removeAll()
        missing.removeAll()
        absent.removeAll()
    }

    /// What is already known, and nothing fetched.
    func cached(_ url: URL) -> UIImage? {
        guard let key = Favicons.key(url) else { return nil }
        if let hit = memory[key] { return hit }
        if absent.contains(key) { return nil }
        guard let data = try? Data(contentsOf: Favicons.file(key)),
              let image = UIImage(data: data, scale: 2)
        else {
            absent.insert(key)
            return nil
        }
        memory[key] = image
        return image
    }

    private static func fresh(_ key: String) -> Bool {
        guard let stamp = try? file(key).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(stamp) < 7 * 86_400
    }

    /// Asks the page which icon it wants to be known by, fetches it, and keeps
    /// it. Nothing happens if a fresh one is already on disk.
    func fetch(for tab: Tab) {
        guard let url = tab.address, url.scheme?.hasPrefix("http") == true,
              let key = Favicons.key(url)
        else { return }
        if Favicons.fresh(key), let known = cached(url) {
            tab.icon = known
            return
        }
        guard !busy.contains(key), !missing.contains(key) else { return }
        busy.insert(key)

        tab.web.evaluateJavaScript(Favicons.probe) { [weak self] answer, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let declared = (answer as? [[String: String]]) ?? []
                let candidates = Favicons.rank(declared, page: url)
                let keep = !tab.isPrivate
                Task { await self.download(candidates, key: key, keep: keep) }
            }
        }
    }

    private func download(_ candidates: [URL], key: String, keep: Bool) async {
        defer { busy.remove(key) }
        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            return config
        }())
        for candidate in candidates {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  data.count > 60, data.count < 2_000_000
            else { continue }
            guard let png = await Favicons.square(data), let image = UIImage(data: png, scale: 2) else { continue }
            memory[key] = image
            absent.remove(key)
            if keep { Favicons.keep(png, for: key) }
            arrived?(key, image)
            return
        }
        // Not asked again this session: hammering a site for an icon it
        // doesn't have is exactly the kind of thing a quiet browser doesn't do.
        missing.insert(key)
    }

    /// The kinds of picture a site's icon may be. Anything else isn't opened:
    /// every kind is one more decoder a site can reach in this process.
    nonisolated private static let kinds: Set<String> = [
        "public.png", "com.microsoft.ico", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "com.microsoft.bmp",
    ]

    /// Decoded off the main thread, the frame nearest 64 pixels picked from an
    /// .ico of many, and drawn into a 64-pixel square PNG.
    nonisolated private static func square(_ data: Data) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let kind = CGImageSourceGetType(source) as String?, kinds.contains(kind)
            else { return nil }
            var best = 0, bestSide = 0
            for index in 0..<min(CGImageSourceGetCount(source), 32) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                let w = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
                let h = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
                guard w > 0, h > 0, w <= 4096, h <= 4096 else { continue }
                let side = max(w, h)
                if bestSide == 0 || (side >= 64 && (bestSide < 64 || side < bestSide)) || (bestSide < 64 && side > bestSide) {
                    best = index
                    bestSide = side
                }
            }
            guard bestSide > 0,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, best, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 128,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            let side: CGFloat = 64
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                let w = CGFloat(decoded.width), h = CGFloat(decoded.height)
                let scale = min(side / w, side / h)
                UIImage(cgImage: decoded).draw(
                    in: CGRect(x: (side - w * scale) / 2, y: (side - h * scale) / 2, width: w * scale, height: h * scale)
                )
            }
            return out.pngData()
        }.value
    }

    private static func keep(_ png: Data, for key: String) {
        let file = Favicons.file(key)
        let dir = folder
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }

    /// Best first: a crisp icon around 32–64 pixels, then the touch icon, then
    /// the file at the root every site has had since 1999.
    private static func rank(_ declared: [[String: String]], page: URL) -> [URL] {
        var scored: [(URL, Int)] = []
        for entry in declared {
            guard let href = entry["href"],
                  let url = URL(string: href, relativeTo: page)?.absoluteURL,
                  url.scheme?.hasPrefix("http") == true
            else { continue }
            let rel = entry["rel"] ?? ""
            let sizes = entry["sizes"] ?? ""
            let type = entry["type"] ?? ""
            // SVG isn't one of the kinds opened; asking for it is a wasted
            // request.
            if type.contains("svg") || url.pathExtension.lowercased() == "svg" { continue }
            // An icon for the dark scheme only is a last resort in the light.
            let media = (entry["media"] ?? "").lowercased()
            let darkOnly = media.contains("prefers-color-scheme") && media.contains("dark")
            var score = 25
            if rel.contains("apple-touch") { score = 44 }
            if let px = sizes.split(separator: " ").compactMap({ Int($0.split(separator: "x").first ?? "") }).max() {
                switch px {
                case ..<24: score = 10
                case 24..<48: score = 42
                case 48..<128: score = 50
                case 128..<260: score = 46
                default: score = 20
                }
            }
            if darkOnly { score -= 30 }
            scored.append((url, score))
        }
        var list = scored.sorted { $0.1 > $1.1 }.map(\.0)
        if let host = page.host() {
            var root = URLComponents()
            root.scheme = page.scheme ?? "https"
            root.host = host
            root.port = page.port
            root.path = "/favicon.ico"
            if let url = root.url { list.append(url) }
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.absoluteString).inserted }
    }

    private static let probe = """
    (function () {
      var out = [];
      var links = document.querySelectorAll('link[rel]');
      for (var i = 0; i < links.length; i++) {
        var l = links[i];
        var rel = (l.getAttribute('rel') || '').toLowerCase();
        if (rel.indexOf('icon') < 0) continue;
        out.push({
          href: l.href,
          rel: rel,
          sizes: (l.getAttribute('sizes') || '').toLowerCase(),
          type: (l.getAttribute('type') || '').toLowerCase(),
          media: (l.getAttribute('media') || '').toLowerCase()
        });
      }
      return out;
    })();
    """
}

/// What stands for a page where its title doesn't fit: the site's icon, and a
/// letter in a faint square until there is one.
struct Mark: View {
    let icon: UIImage?
    let letter: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                Text(letter)
                    .font(.system(size: size * 0.56, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .frame(width: size, height: size)
                    .background(
                        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                            .fill(Palette.ink.opacity(0.06))
                    )
            }
        }
        .transition(.opacity)
        .animation(Motion.quick, value: icon == nil)
    }
}
