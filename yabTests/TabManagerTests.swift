import Foundation
import Testing
import UIKit
import WebKit
@testable import yab

/// Counts how often the owner was asked to authenticate.
@MainActor
final class FakeAuthentication {
    var answer: Bool
    private(set) var requests = 0

    init(answer: Bool = true) {
        self.answer = answer
    }

    func makeLock() -> HackerModeLock {
        HackerModeLock { [self] in
            requests += 1
            return answer
        }
    }
}

/// Tabs made by the real `TabManager`, loading pages in real WebKit.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct TabManagerTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "tabs-\(UUID().uuidString)")
    let normalStore = WKWebsiteDataStore.nonPersistent()
    let forgetter = SiteDataForgetter(gracePeriod: .milliseconds(300))
    let authentication = FakeAuthentication()

    var tabStore: TabStore { TabStore(directory: directory) }

    func makeTabs(
        contentBlocker: ContentBlocker? = nil,
        server: TestSchemeHandler? = nil,
        maximumLiveTabs: Int = 4,
        upgradesLocalHostsToHTTPS: Bool = false
    ) -> TabManager {
        TabManager(
            contentBlocker: contentBlocker,
            forgetter: forgetter,
            siteInfo: nil,
            hackerLock: authentication.makeLock(),
            normalDataStore: normalStore,
            store: tabStore,
            blockingSwitchURL: directory.appending(path: "sites-without-blocking.json"),
            maximumLiveTabs: maximumLiveTabs,
            upgradesLocalHostsToHTTPS: upgradesLocalHostsToHTTPS,
            configure: { configuration in
                if let server { configuration.setURLSchemeHandler(server, forURLScheme: "yabtest") }
            }
        )
    }

    func sites(in store: WKWebsiteDataStore) async -> Set<String> {
        Set(await SiteDataManager(store: store).entries().map(\.site))
    }

    func title(of tab: Tab) async -> String? {
        try? await tab.webView?.callAsyncJavaScript("return document.title", arguments: [:], contentWorld: .page) as? String
    }

    // MARK: - Groups

    @Test func normalAndHackerGroupsKeepDataApart() async throws {
        let server = try await LocalHTTPServer(html: SiteDataStoreTests.page)
        let tabs = makeTabs()

        tabs.newTab(in: .normal, url: URL(string: "http://localhost:\(server.port)/")!)
        #expect(await tabs.enterHackerMode())
        let hackerTab = try #require(tabs.newTab(in: .hacker, url: URL(string: "http://127.0.0.1:\(server.port)/")!))
        #expect(tabs.normalTabs.tabs.count == 1)
        #expect(tabs.hackerTabs.tabs == [hackerTab])

        #expect(await eventually { await sites(in: normalStore) == ["localhost"] })
        #expect(await eventually { await sites(in: forgetter.store) == ["127.0.0.1"] })

        // Closing the last hacker tab on a site forgets it. Normal mode keeps everything.
        tabs.close(hackerTab)
        #expect(await eventually { await sites(in: forgetter.store).isEmpty })
        #expect(await sites(in: normalStore) == ["localhost"])
    }

    @Test func contentBlockingAndScriptletsApplyInEveryTab() async throws {
        let blocker = try makeTestContentBlocker(filters: """
            ||ads.example^
            site.example##+js(set, yabTest, 42)
            """)
        let server = TestSchemeHandler(html: """
            <html><head><script>document.title = String(window.yabTest);</script></head>
            <body><img src="yabtest://ads.example/banner.gif"></body></html>
            """)
        let tabs = makeTabs(contentBlocker: blocker, server: server)

        let first = try #require(tabs.newTab(url: URL(string: "yabtest://site.example/index.html")!))
        #expect(await tabs.enterHackerMode())
        let second = try #require(tabs.newTab(in: .hacker, url: URL(string: "yabtest://site.example/other.html")!))

        for tab in [first, second] {
            #expect(await eventually { await title(of: tab) == "42" })
        }
        #expect(!server.requestedURLs.contains("yabtest://ads.example/banner.gif"))
    }

    @Test func closingShowsTheNeighborInTheSameGroup() async throws {
        let tabs = makeTabs()
        let first = try #require(tabs.newTab())
        let second = try #require(tabs.newTab())
        let third = try #require(tabs.newTab())
        #expect(await tabs.enterHackerMode())
        let secret = try #require(tabs.newTab(in: .hacker))
        #expect(tabs.selectedTab === secret)

        tabs.leaveHackerMode()
        #expect(tabs.selectedTab === third)
        tabs.close(third)
        #expect(tabs.selectedTab === second)
        tabs.close(first)
        #expect(tabs.selectedTab === second)

        #expect(await tabs.enterHackerMode())
        #expect(tabs.selectedTab === secret)
        tabs.close(secret)
        #expect(tabs.selectedTab == nil)
    }

    // MARK: - Hacker mode lock

    @Test func enteringHackerModeNeedsTheOwner() async {
        authentication.answer = false
        let tabs = makeTabs()
        tabs.newTab()

        #expect(await !tabs.enterHackerMode())
        #expect(tabs.mode == .normal)
        #expect(tabs.newTab(in: .hacker) == nil)
        #expect(tabs.hackerTabs.tabs.isEmpty)
    }

    @Test func leavingHackerModeLocksIt() async throws {
        let tabs = makeTabs()
        tabs.newTab()
        #expect(await tabs.enterHackerMode())
        let secret = try #require(tabs.newTab(in: .hacker))

        tabs.leaveHackerMode()
        #expect(tabs.mode == .normal)
        #expect(tabs.isHackerModeLocked)
        #expect(!tabs.select(secret))

        // Coming back asks again.
        #expect(await tabs.enterHackerMode())
        #expect(authentication.requests == 2)
        #expect(tabs.shownTab === secret)
    }

    @Test func lockedHackerModeKeepsTabsInMemoryButHidesThem() async throws {
        let server = TestSchemeHandler(html: "<html><head><title>Secret</title></head></html>")
        let tabs = makeTabs(server: server)
        #expect(await tabs.enterHackerMode())
        let secret = try #require(tabs.newTab(in: .hacker, url: URL(string: "yabtest://secret.example/index.html")!))
        #expect(await eventually { await title(of: secret) == "Secret" })

        // For example when the app goes to the background.
        tabs.lockHackerMode()
        #expect(tabs.mode == .hacker)
        #expect(tabs.shownTab == nil)
        #expect(tabs.selectedTab === secret)
        #expect(secret.isLive)

        #expect(await tabs.unlockHackerMode())
        #expect(tabs.shownTab === secret)
        #expect(await title(of: secret) == "Secret")
    }

    @Test func askingTwiceAtOnceShowsOnePrompt() async {
        let lock = authentication.makeLock()
        async let first = lock.unlock()
        async let second = lock.unlock()
        #expect(await [first, second] == [true, true])
        #expect(authentication.requests == 1)
    }

    // MARK: - Never losing normal tabs

    @Test func normalTabsComeBackAfterARestartWithTheirHistory() async throws {
        let server = TestSchemeHandler(html: "<html><head><title>Page</title></head></html>")
        let tabs = makeTabs(server: server)
        let first = try #require(tabs.newTab(url: URL(string: "yabtest://one.example/a.html")!))
        #expect(await eventually { first.url?.lastPathComponent == "a.html" && first.webView?.isLoading == false })
        first.load(URL(string: "yabtest://one.example/b.html")!)
        #expect(await eventually { first.webView?.backForwardList.currentItem?.url.lastPathComponent == "b.html" && first.webView?.isLoading == false })
        let second = try #require(tabs.newTab(url: URL(string: "yabtest://two.example/index.html")!))
        #expect(await tabs.enterHackerMode())
        tabs.newTab(in: .hacker, url: URL(string: "yabtest://secret.example/index.html")!)
        tabs.leaveHackerMode()
        tabs.select(second)
        #expect(await eventually { first.url?.lastPathComponent == "b.html" && second.webView?.url != nil })
        tabs.saveSession()

        // A new launch: hacker tabs are gone, normal tabs are back.
        server.reset()
        let restored = makeTabs(server: server)
        restored.restoreSession()
        #expect(restored.normalTabs.tabs.map(\.id) == [first.id, second.id])
        #expect(restored.hackerTabs.tabs.isEmpty)
        #expect(restored.selectedTab?.id == second.id)

        // Only the selected tab loads; the other waits until it is shown.
        let restoredFirst = restored.normalTabs.tabs[0]
        #expect(!restoredFirst.isLive)
        #expect(restoredFirst.url?.lastPathComponent == "b.html")
        #expect(await eventually { restored.selectedTab?.webView?.url?.host() == "two.example" })
        #expect(!server.requestedURLs.contains { $0.contains("one.example") })

        // When shown, it comes back on the same page, with the page before it to go back to.
        restored.select(restoredFirst)
        #expect(await eventually { restoredFirst.webView?.url?.lastPathComponent == "b.html" })
        #expect(restoredFirst.webView?.backForwardList.backItem?.url.lastPathComponent == "a.html")
    }

    @Test func onlyRecentTabsStayLiveAndOthersComeBackWithTheirHistory() async throws {
        let server = TestSchemeHandler(html: "<html><head><title>Page</title></head></html>")
        let tabs = makeTabs(server: server, maximumLiveTabs: 2)
        let first = try #require(tabs.newTab(url: URL(string: "yabtest://one.example/a.html")!))
        #expect(await eventually { first.webView?.isLoading == false && first.url != nil })
        first.load(URL(string: "yabtest://one.example/b.html")!)
        #expect(await eventually { first.url?.lastPathComponent == "b.html" && first.webView?.isLoading == false })

        tabs.newTab(url: URL(string: "yabtest://two.example/index.html")!)
        tabs.newTab(url: URL(string: "yabtest://three.example/index.html")!)
        #expect(await eventually { tabs.allTabs.filter(\.isLive).count == 2 })
        #expect(!first.isLive)
        #expect(first.url?.lastPathComponent == "b.html")

        tabs.select(first)
        #expect(await eventually { first.webView?.url?.lastPathComponent == "b.html" })
        #expect(first.webView?.backForwardList.backItem?.url.lastPathComponent == "a.html")
    }

    @Test func memoryWarningsSuspendEverythingButTheShownTab() async throws {
        let tabs = makeTabs()
        let hidden = try #require(tabs.newTab(url: URL(string: "about:blank")!))
        let shown = try #require(tabs.newTab(url: URL(string: "about:blank")!))
        #expect(hidden.isLive && shown.isLive)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #expect(await eventually { !hidden.isLive })
        #expect(shown.isLive)
    }

    @Test func aPageEndedByIOSComesBackWithItsHistory() async throws {
        let server = TestSchemeHandler(html: "<html><head><title>Page</title></head></html>")
        let tabs = makeTabs(server: server)
        let tab = try #require(tabs.newTab(url: URL(string: "yabtest://one.example/a.html")!))
        #expect(await eventually { tab.webView?.isLoading == false && tab.url != nil })
        tab.load(URL(string: "yabtest://one.example/b.html")!)
        #expect(await eventually { tab.url?.lastPathComponent == "b.html" && tab.webView?.isLoading == false })
        let endedWebView = try #require(tab.webView)

        // What WebKit reports when iOS ends a page's process to free memory.
        tab.webViewWebContentProcessDidTerminate(endedWebView)

        #expect(tab.webView !== endedWebView)
        #expect(await eventually { tab.webView?.url?.lastPathComponent == "b.html" })
        #expect(tab.webView?.backForwardList.backItem?.url.lastPathComponent == "a.html")
    }

    @Test func aRestoredTabShowsItsLastPictureWhileLoading() async throws {
        let server = TestSchemeHandler(html: "<html><body style='background: rgb(255, 0, 128)'>Pink</body></html>")
        let screen = TestScreen()
        let tabs = makeTabs(server: server)
        let tab = try #require(tabs.newTab(url: URL(string: "yabtest://pink.example/index.html")!))
        screen.show(tab.view)
        #expect(await eventually { tab.webView?.isLoading == false && tab.url != nil })
        try await Task.sleep(for: .milliseconds(300))

        tabs.captureSnapshot(of: tab)
        #expect(await eventually { tabStore.hasSnapshot(for: tab.id) })
        let picture = try #require(tabStore.snapshot(for: tab.id))
        #expect(picture.size.width > 0)
        tabs.saveSession()

        let restored = makeTabs(server: server)
        restored.restoreSession()
        let restoredTab = try #require(restored.selectedTab)
        screen.show(restoredTab.view)
        #expect(restoredTab.view.isShowingSnapshot)
        #expect(await eventually { !restoredTab.view.isShowingSnapshot })
        #expect(restoredTab.webView?.url?.host() == "pink.example")
    }

    @Test func closingANormalTabDeletesItsFiles() async throws {
        let screen = TestScreen()
        let server = TestSchemeHandler(html: "<html><body>Hi</body></html>")
        let tabs = makeTabs(server: server)
        let tab = try #require(tabs.newTab(url: URL(string: "yabtest://one.example/index.html")!))
        screen.show(tab.view)
        #expect(await eventually { tab.webView?.isLoading == false && tab.url != nil })
        tabs.captureSnapshot(of: tab)
        #expect(await eventually { tabStore.hasSnapshot(for: tab.id) })
        tabs.saveSession()
        #expect(tabStore.history(for: tab.id) != nil)

        tabs.close(tab)
        #expect(!tabStore.hasSnapshot(for: tab.id))
        #expect(tabStore.history(for: tab.id) == nil)
    }

    @Test func hackerTabsAreNeverWrittenToDisk() async throws {
        let screen = TestScreen()
        let server = TestSchemeHandler(html: "<html><body>Secret</body></html>")
        let tabs = makeTabs(server: server)
        #expect(await tabs.enterHackerMode())
        let secret = try #require(tabs.newTab(in: .hacker, url: URL(string: "yabtest://secret.example/index.html")!))
        screen.show(secret.view)
        #expect(await eventually { secret.webView?.isLoading == false && secret.url != nil })

        tabs.captureSnapshot(of: secret)
        tabs.saveSession()
        try await Task.sleep(for: .milliseconds(300))

        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(!files.contains { $0.contains(secret.id.uuidString) })
        #expect(tabStore.loadIndex()?.tabs.isEmpty ?? true)
    }
}

struct TabGroupTests {
    @MainActor
    @Test func removingTheSelectedTabSelectsItsNeighbor() {
        let group = TabGroup(mode: .normal, dataStore: .nonPersistent(), blockingSwitch: SiteBlockingSwitch(fileURL: nil))
        let tabs = (0..<3).map { _ in Tab(mode: .normal) }
        tabs.forEach(group.append)

        group.select(tabs[2])
        group.remove(tabs[2])
        #expect(group.selectedTab === tabs[1])

        group.select(tabs[0])
        group.remove(tabs[0])
        #expect(group.selectedTab === tabs[1])

        group.remove(tabs[1])
        #expect(group.selectedTab == nil)
    }
}

@MainActor
struct SiteInfoStoreTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "site-info-\(UUID().uuidString)")
    let icon = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { _ in }

    /// Records what LinkPresentation was asked for.
    final class FakeFetcher {
        var requested: [URL] = []
    }

    func makeStore(fetcher: FakeFetcher, now: Date = Date()) -> SiteInfoStore {
        let icon = icon
        return SiteInfoStore(
            directory: directory,
            fetch: { url in
                fetcher.requested.append(url)
                return ("Example", icon)
            },
            siteForHost: { host in host.hasSuffix("example.com") ? "example.com" : nil },
            now: { now }
        )
    }

    @Test func visitedSitesAreLookedUpAtTheirRoot() async throws {
        let fetcher = FakeFetcher()
        let store = makeStore(fetcher: fetcher)

        store.noteVisit(to: "News.Example.com")
        #expect(await eventually { store.info(forSite: "example.com") != nil })
        #expect(fetcher.requested == [URL(string: "https://example.com/")!])
        #expect(store.info(forSite: "example.com")?.title == "Example")
        #expect(store.icon(forSite: "example.com") != nil)
        #expect(store.titles == ["example.com": "Example"])

        // Kept across launches, and not fetched again.
        let reopened = makeStore(fetcher: fetcher)
        #expect(await reopened.loadInfo(forSite: "example.com")?.title == "Example")
        #expect(fetcher.requested.count == 1)
    }

    @Test func sitesNeverOpenedAreNotContacted() async {
        let fetcher = FakeFetcher()
        let store = makeStore(fetcher: fetcher)
        #expect(await store.loadInfo(forSite: "tracker.example") == nil)
        #expect(fetcher.requested.isEmpty)
    }

    @Test func oldInfoIsRefreshed() async {
        let fetcher = FakeFetcher()
        let store = makeStore(fetcher: fetcher)
        store.noteVisit(to: "example.com")
        #expect(await eventually { store.info(forSite: "example.com") != nil })

        let later = makeStore(fetcher: fetcher, now: Date().addingTimeInterval(SiteInfoStore.refreshInterval + 60))
        _ = await later.loadInfo(forSite: "example.com")
        #expect(fetcher.requested.count == 2)
    }

    @Test func forgettingASiteRemovesEverythingAboutIt() async {
        let fetcher = FakeFetcher()
        let store = makeStore(fetcher: fetcher)
        store.noteVisit(to: "www.example.com")
        #expect(await eventually { store.icon(forSite: "example.com") != nil })

        store.forget(site: "example.com")
        #expect(store.info(forSite: "example.com") == nil)
        #expect(store.icon(forSite: "example.com") == nil)
        // No longer counted as visited, so it is not looked up again.
        #expect(await store.loadInfo(forSite: "example.com") == nil)
    }
}

@MainActor
struct SiteInfoFailureTests {
    @Test func failedLookupsAreRetriedAfterADayNotOnEveryVisit() async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "site-info-\(UUID().uuidString)")
        var attempts = 0
        var now = Date()
        let store = SiteInfoStore(
            directory: directory,
            fetch: { _ in
                attempts += 1
                throw URLError(.cannotConnectToHost)
            },
            siteForHost: { _ in "plain.example" },
            now: { now }
        )

        store.noteVisit(to: "plain.example")
        #expect(await eventually { attempts == 1 })
        _ = await store.loadInfo(forSite: "plain.example")
        #expect(attempts == 1)

        now.addTimeInterval(SiteInfoStore.retryInterval + 60)
        _ = await store.loadInfo(forSite: "plain.example")
        #expect(attempts == 2)
    }
}
