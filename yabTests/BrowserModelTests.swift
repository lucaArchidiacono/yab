import Foundation
import Testing
@testable import yab

struct AddressInputTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  wikipedia.org/wiki/Swift  ", "https://wikipedia.org/wiki/Swift"),
        ("https://example.com/a?b=c", "https://example.com/a?b=c"),
        ("http://neverssl.com", "http://neverssl.com"),
        ("localhost:8080", "https://localhost:8080"),
        ("192.168.1.1", "https://192.168.1.1"),
        ("yab.swiss", "https://yab.swiss"),
    ])
    func addressesOpenDirectly(input: String, expected: String) {
        #expect(AddressInput.url(for: input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("what is yab", "https://duckduckgo.com/?q=what%20is%20yab"),
        ("c++ tutorial", "https://duckduckgo.com/?q=c%2B%2B%20tutorial"),
        ("swift", "https://duckduckgo.com/?q=swift"),
        ("version 2.5", "https://duckduckgo.com/?q=version%202.5"),
        ("1.5", "https://duckduckgo.com/?q=1.5"),
    ])
    func everythingElseIsASearch(input: String, expected: String) {
        #expect(AddressInput.url(for: input)?.absoluteString == expected)
    }

    @Test func emptyInputOpensNothing() {
        #expect(AddressInput.url(for: "   ") == nil)
    }
}

@MainActor
struct FavoritesStoreTests {
    let fileURL = FileManager.default.temporaryDirectory.appending(path: "favorites-\(UUID().uuidString).json")

    @Test func startsWithStarterFavorites() {
        #expect(FavoritesStore(fileURL: fileURL).favorites == FavoritesStore.starters)
    }

    @Test func changesAreSavedAndAnnounced() {
        let store = FavoritesStore(fileURL: fileURL)
        var changes = 0
        store.onChange = { changes += 1 }
        let url = URL(string: "https://yab.example")!

        store.add(title: "yab", url: url)
        store.add(title: "yab again", url: url)
        #expect(store.contains(url))
        #expect(changes == 1)

        let reopened = FavoritesStore(fileURL: fileURL)
        #expect(reopened.favorites.last?.title == "yab")

        reopened.remove(url)
        #expect(!FavoritesStore(fileURL: fileURL).contains(url))
    }
}
