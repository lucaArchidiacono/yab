import Foundation
import Testing
import WebKit
@testable import yab

struct SiteDataSearchTests {
    let entries = [
        SiteDataEntry(site: "wikipedia.org", kinds: [.cookies], cookies: []),
        SiteDataEntry(site: "openstreetmap.org", kinds: [.savedData], cookies: []),
    ]

    @Test(arguments: ["wikipedia", "Wikipedia", "wikipedia.org", "www.wikipedia.org", "de.wikipedia.org", "https://de.wikipedia.org/wiki/Swift"])
    func findsSiteBySimpleName(query: String) {
        #expect(SiteDataManager.search(entries, for: query).map(\.site) == ["wikipedia.org"])
    }

    @Test func findsSiteByTitle() {
        #expect(SiteDataManager.search(entries, for: "map", titles: [:]).map(\.site) == ["openstreetmap.org"])
        #expect(SiteDataManager.search(entries, for: "encyclopedia", titles: ["wikipedia.org": "Wikipedia, the free encyclopedia"]).map(\.site) == ["wikipedia.org"])
    }

    @Test func emptyQueryShowsEverything() {
        #expect(SiteDataManager.search(entries, for: "  ").count == 2)
    }

    @Test func subdomainsBelongToTheirSite() {
        #expect(SiteDataEntry.host("profile.wikipedia.org", belongsTo: "wikipedia.org"))
        #expect(SiteDataEntry.host("WIKIPEDIA.org", belongsTo: "wikipedia.org"))
        #expect(!SiteDataEntry.host("notwikipedia.org", belongsTo: "wikipedia.org"))
    }
}

/// Real WebKit data stores, filled by pages from a local web server. `localhost` and
/// `127.0.0.1` are two different sites to WebKit.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SiteDataStoreTests {
    static let page = """
        <html><body><script>
        document.cookie = "visitor=42; max-age=3600; path=/";
        localStorage.setItem("seen", "yes");
        </script></body></html>
        """

    func sites(in store: WKWebsiteDataStore) async -> Set<String> {
        Set(await SiteDataManager(store: store).entries().map(\.site))
    }

    @Test func listsSearchesAndDeletesDataBySite() async throws {
        let server = try await LocalHTTPServer(html: Self.page)
        let manager = SiteDataManager(store: .nonPersistent())
        let browser = TestBrowser(html: "", dataStore: manager.store)

        try await browser.load("http://localhost:\(server.port)/")
        try await browser.load("http://127.0.0.1:\(server.port)/")
        #expect(await eventually { await sites(in: manager.store) == ["localhost", "127.0.0.1"] })

        let localhost = try #require(await manager.entries().first { $0.site == "localhost" })
        #expect(localhost.kinds.isSuperset(of: [.cookies, .savedData]))
        #expect(localhost.cookies.map(\.name) == ["visitor"])
        #expect(localhost.cookies.first?.expires != nil)

        await manager.removeData(of: ["localhost"])
        #expect(await sites(in: manager.store) == ["127.0.0.1"])

        await manager.removeAllData()
        #expect(await sites(in: manager.store).isEmpty)
    }

    @Test func hackerModeKeepsSiteWhileAnyTabShowsIt() async throws {
        let server = try await LocalHTTPServer(html: Self.page)
        let forgetter = SiteDataForgetter(gracePeriod: .milliseconds(300))
        let localhost = URL(string: "http://localhost:\(server.port)/")!
        let other = URL(string: "http://127.0.0.1:\(server.port)/")!
        let (first, second) = (UUID(), UUID())
        let firstTab = TestBrowser(html: "", dataStore: forgetter.store)
        let secondTab = TestBrowser(html: "", dataStore: forgetter.store)

        // Two tabs on the same site.
        try await firstTab.load(localhost.absoluteString)
        forgetter.tab(first, didShow: localhost)
        try await secondTab.load(localhost.absoluteString)
        forgetter.tab(second, didShow: localhost)
        #expect(await eventually { await sites(in: forgetter.store) == ["localhost"] })

        // One leaves: the other still shows the site, so its data stays.
        try await secondTab.load(other.absoluteString)
        forgetter.tab(second, didShow: other)
        try await Task.sleep(for: .milliseconds(700))
        #expect(await sites(in: forgetter.store) == ["localhost", "127.0.0.1"])

        // The last tab on it closes: once the grace period is over, it is forgotten.
        forgetter.tabDidClose(first)
        #expect(await sites(in: forgetter.store).contains("localhost"))
        #expect(await eventually { await sites(in: forgetter.store) == ["127.0.0.1"] })

        forgetter.tabDidClose(second)
        #expect(await eventually { await sites(in: forgetter.store).isEmpty })
    }

    @Test func comingBackWithinTheGracePeriodKeepsTheSite() async throws {
        let server = try await LocalHTTPServer(html: Self.page)
        let forgetter = SiteDataForgetter(gracePeriod: .milliseconds(500))
        let localhost = URL(string: "http://localhost:\(server.port)/")!
        let other = URL(string: "http://127.0.0.1:\(server.port)/")!
        let tab = UUID()
        let browser = TestBrowser(html: "", dataStore: forgetter.store)

        try await browser.load(localhost.absoluteString)
        forgetter.tab(tab, didShow: localhost)
        #expect(await eventually { await sites(in: forgetter.store) == ["localhost"] })

        // A quick detour, like logging in through another site.
        try await browser.load(other.absoluteString)
        forgetter.tab(tab, didShow: other)
        try await browser.load(localhost.absoluteString)
        forgetter.tab(tab, didShow: localhost)

        // The detour site is forgotten, the site we came back to is not.
        #expect(await eventually { await sites(in: forgetter.store) == ["localhost"] })
        try await Task.sleep(for: .milliseconds(800))
        #expect(await sites(in: forgetter.store) == ["localhost"])
    }
}
