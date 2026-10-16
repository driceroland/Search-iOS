import Foundation

// Where this browser keeps what it knows. Its own container, its own settings —
// nothing here reaches for anything on a Mac, and nothing on a Mac reaches for
// anything here.
enum Store {
    static let folder: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }()

    static func file(_ name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    static let settings = UserDefaults.standard
}
