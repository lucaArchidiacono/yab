import Foundation

nonisolated struct Favorite: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
}

/// Favorites, kept in a small JSON file.
final class FavoritesStore {
    private(set) var favorites: [Favorite]
    var onChange: (() -> Void)?
    private let fileURL: URL

    /// A few sites everyone can use, so the empty tab screen is not empty on day one.
    static let starters = [
        Favorite(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!),
        Favorite(title: "OpenStreetMap", url: URL(string: "https://www.openstreetmap.org")!),
        Favorite(title: "DuckDuckGo", url: URL(string: "https://duckduckgo.com")!),
    ]

    init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "favorites.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Favorite].self, from: data) {
            favorites = saved
        } else {
            favorites = Self.starters
        }
    }

    func contains(_ url: URL) -> Bool {
        favorites.contains { $0.url == url }
    }

    func add(title: String, url: URL) {
        guard !contains(url) else { return }
        favorites.append(Favorite(title: title, url: url))
        save()
    }

    func remove(_ url: URL) {
        favorites.removeAll { $0.url == url }
        save()
    }

    func remove(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(favorites).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("Could not save favorites: \(error)")
        }
        onChange?()
    }
}
