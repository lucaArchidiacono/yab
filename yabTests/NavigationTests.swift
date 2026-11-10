import Foundation
import Testing
import WebKit
@testable import yab

struct RedirectSkipStepsTests {
    @Test(arguments: [
        // Examples from uBlock Origin's documentation and lists.
        (["?url"], "https://t.example/out?url=https%3A%2F%2Fnews.example%2Fa%3Fb%3Dc", "https://news.example/a?b=c"),
        (["?to", "-base64"], "https://t.example/go?to=aHR0cHM6Ly9uZXdzLmV4YW1wbGUv", "https://news.example/"),
        (["?to", "-base64"], "https://t.example/go?to=aHR0cHM6Ly9uZXdzLmV4YW1wbGU", "https://news.example"),
        (["&1"], "https://www.pixiv.net/jump.php?https%3A%2F%2Fnews.example%2F", "https://news.example/"),
        ([#"/\/redirect\.mp3\/(.*?\.mp3\b)/"#, "+https"], "https://dts.podtrac.com/redirect.mp3/cdn.example/show.mp3", "https://cdn.example/show.mp3"),
        (["#"], "https://t.example/go#https://news.example/", "https://news.example/"),
        (["?u", "-safebase64"], "https://t.example/go?u=aHR0cHM6Ly9uZXdzLmV4YW1wbGUvP2E9MSZiPT8_", "https://news.example/?a=1&b=??"),
        (["?u", "-uricomponent"], "https://t.example/go?u=https%253A%252F%252Fnews.example%252F", "https://news.example/"),
        (["?url", "-blocked"], "https://t.example/out?url=https%3A%2F%2Fnews.example%2F", "https://news.example/"),
    ])
    func followsSteps(steps: [String], url: String, expected: String) {
        #expect(RedirectSkipper.follow(steps, from: url) == expected)
    }

    @Test(arguments: [
        (["?missing"], "https://t.example/out?url=https%3A%2F%2Fnews.example%2F"),
        (["?url"], "https://t.example/out?url=javascript%3Aalert(1)"),
        (["?url"], "https://t.example/out?url=not-a-link"),
        (["-unknown"], "https://t.example/"),
        (["&3"], "https://t.example/out?a=1"),
    ])
    func givesUpWhenAStepFails(steps: [String], url: String) {
        #expect(RedirectSkipper.follow(steps, from: url) == nil)
    }

    @Test func filtersFromTrustedListsOnly() {
        let filters = """
            ||tracker.example/out?$doc,urlskip=?to
            @@||tracker.example/out?keep$doc,urlskip
            ||player.example/*.mp3$media,urlskip=?u
            """
        let trusted = FilterListConverter().convert(filters, isTrusted: true)
        #expect(trusted.redirectSkips.skips.count == 1)
        #expect(trusted.redirectSkips.exceptions.count == 1)
        #expect(trusted.report.skipped[.unsupportedOption] == 1)
        #expect(trusted.rules.isEmpty)

        let untrusted = FilterListConverter().convert(filters, isTrusted: false)
        #expect(untrusted.redirectSkips.count == 0)
        #expect(untrusted.report.skipped[.untrustedOption] == 2)

        let skipper = RedirectSkipper(trusted.redirectSkips)
        let destination = "https%3A%2F%2Fnews.example%2Fstory"
        #expect(skipper.destination(of: URL(string: "https://tracker.example/out?to=\(destination)")!)?.absoluteString == "https://news.example/story")
        #expect(skipper.destination(of: URL(string: "https://tracker.example/out?keep&to=\(destination)")!) == nil)
        #expect(skipper.destination(of: URL(string: "https://other.example/out?to=\(destination)")!) == nil)
    }
}

@MainActor
struct HTTPSUpgraderTests {
    let tab = UUID()

    @Test func upgradesHTTPToHTTPS() {
        let upgrader = HTTPSUpgrader()
        #expect(upgrader.decide(URL(string: "http://news.example/a?b=c")!, in: tab) == .upgrade(URL(string: "https://news.example/a?b=c")!))
        upgrader.finish(in: tab)
        #expect(upgrader.decide(URL(string: "http://news.example:80/")!, in: tab) == .upgrade(URL(string: "https://news.example/")!))
        #expect(upgrader.decide(URL(string: "https://news.example/")!, in: tab) == .proceed)
    }

    @Test(arguments: ["http://localhost/", "http://192.168.1.1/", "http://printer.local/", "http://router/", "http://[::1]/"])
    func leavesLocalAddressesAlone(url: String) {
        #expect(HTTPSUpgrader().decide(URL(string: url)!, in: tab) == .proceed)
    }

    @Test func sitesWithoutHTTPSNeedTheOwnersConsent() {
        let upgrader = HTTPSUpgrader()
        let original = URL(string: "http://old.example/page")!
        #expect(upgrader.decide(original, in: tab) == .upgrade(URL(string: "https://old.example/page")!))

        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "https://old.example/page")!,
        ])
        #expect(upgrader.failedUpgrade(in: tab, after: error) == original)

        // Without consent, it is tried over HTTPS again.
        #expect(upgrader.decide(original, in: tab) != .proceed)
        upgrader.finish(in: tab)

        // With consent, the site and its subdomains open over http, without asking again.
        upgrader.allowHTTP(for: original)
        #expect(upgrader.decide(original, in: tab) == .proceed)
        #expect(upgrader.decide(URL(string: "http://random.old.example/online")!, in: tab) == .proceed)
        #expect(upgrader.decide(URL(string: "http://notold.example/")!, in: tab) != .proceed)
    }

    @Test func beingOfflineIsNoReasonToWarn() {
        let upgrader = HTTPSUpgrader()
        _ = upgrader.decide(URL(string: "http://news.example/")!, in: tab)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(upgrader.failedUpgrade(in: tab, after: error) == nil)
    }

    @Test func aSiteSendingUsBackToHTTPIsAWarning() {
        let upgrader = HTTPSUpgrader()
        let url = URL(string: "http://loop.example/")!
        #expect(upgrader.decide(url, in: tab) == .upgrade(URL(string: "https://loop.example/")!))
        // The HTTPS page redirected to http before anything loaded.
        #expect(upgrader.decide(url, in: tab) == .warn(url))
    }

    @Test func aLoadedPageEndsTheUpgrade() {
        let upgrader = HTTPSUpgrader()
        let url = URL(string: "http://news.example/")!
        #expect(upgrader.decide(url, in: tab) != .proceed)
        upgrader.finish(in: tab)
        #expect(upgrader.decide(url, in: tab) == .upgrade(URL(string: "https://news.example/")!))
    }
}

struct LoadProblemTests {
    let url = URL(string: "https://news.example/")!

    @Test func recognizesBlockedAndOfflinePages() {
        let blocked = NSError(domain: "WebKitErrorDomain", code: LoadProblem.blockedByContentBlocker, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let other = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSURLErrorFailingURLErrorKey: url])
        #expect(LoadProblem(blocked) == .blocked(url))
        #expect(LoadProblem(offline) == .offline(url))
        #expect(LoadProblem(other) == nil)
    }
}

@MainActor
struct SiteBlockingSwitchTests {
    let fileURL = FileManager.default.temporaryDirectory.appending(path: "switch-\(UUID().uuidString).json")

    @Test func switchingOffCoversTheWholeSiteAndIsRemembered() {
        let normal = SiteBlockingSwitch(fileURL: fileURL)
        normal.setBlocking(false, on: "www.Example.com")
        #expect(normal.sitesWithoutBlocking == ["example.com"])
        #expect(!normal.isBlockingEnabled(on: "example.com"))
        #expect(!normal.isBlockingEnabled(on: "shop.example.com"))
        #expect(normal.isBlockingEnabled(on: "notexample.com"))
        #expect(!SiteBlockingSwitch(fileURL: fileURL).isBlockingEnabled(on: "example.com"))

        normal.setBlocking(true, on: "shop.example.com")
        #expect(normal.isBlockingEnabled(on: "example.com"))
        #expect(SiteBlockingSwitch(fileURL: fileURL).sitesWithoutBlocking.isEmpty)
    }

    @Test func hackerModeKeepsItInMemoryOnly() {
        let hacker = SiteBlockingSwitch(fileURL: nil)
        hacker.setBlocking(false, on: "example.com")
        #expect(!hacker.isBlockingEnabled(on: "example.com"))
        #expect(SiteBlockingSwitch(fileURL: nil).isBlockingEnabled(on: "example.com"))
    }
}

/// What happens before a page opens, in real WebKit through the real `TabManager`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NavigationTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "navigation-\(UUID().uuidString)")
    let authentication = FakeAuthentication()

    func makeTabs(contentBlocker: ContentBlocker? = nil, server: TestSchemeHandler? = nil, upgradesLocalHostsToHTTPS: Bool = false) -> TabManager {
        TabManager(
            contentBlocker: contentBlocker,
            forgetter: SiteDataForgetter(gracePeriod: .milliseconds(300)),
            siteInfo: nil,
            hackerLock: authentication.makeLock(),
            normalDataStore: .nonPersistent(),
            store: TabStore(directory: directory),
            blockingSwitchURL: directory.appending(path: "sites-without-blocking.json"),
            upgradesLocalHostsToHTTPS: upgradesLocalHostsToHTTPS,
            configure: { configuration in
                if let server { configuration.setURLSchemeHandler(server, forURLScheme: "yabtest") }
            }
        )
    }

    func evaluate(_ javaScript: String, in tab: Tab) async -> Any? {
        try? await tab.webView?.callAsyncJavaScript(javaScript, arguments: [:], contentWorld: .page)
    }

    @Test func trackingRedirectsAreSkipped() async throws {
        let server = try await LocalHTTPServer(html: "<html><body>Hello</body></html>")
        let blocker = try makeTestContentBlocker(filters: "||127.0.0.1^*/out?$doc,urlskip=?to")
        let tabs = makeTabs(contentBlocker: blocker)
        let destination = "http://localhost:\(server.port)/story"
        let tracking = "http://127.0.0.1:\(server.port)/out?to=\(destination.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"

        let tab = try #require(tabs.newTab(url: URL(string: tracking)!))
        #expect(await eventually { tab.url?.absoluteString == destination && tab.webView?.isLoading == false })
        #expect(server.requests.map(\.path) == ["/story"])
    }

    @Test func pagesGetTheGlobalPrivacyControlSignal() async throws {
        let server = try await LocalHTTPServer(html: "<html><head><script>document.title = String(navigator.globalPrivacyControl)</script></head></html>")
        let tabs = makeTabs(contentBlocker: try makeTestContentBlocker(filters: "||ads.example^"))

        let tab = try #require(tabs.newTab(url: URL(string: "http://localhost:\(server.port)/")!))
        #expect(await eventually { await evaluate("return document.title", in: tab) as? String == "true" })
        #expect(server.requests.first?.headers["sec-gpc"] == "1")
    }

    @Test func sitesWithoutHTTPSAskBeforeOpeningOverHTTP() async throws {
        let server = try await LocalHTTPServer(html: "<html><head><title>Plain</title></head></html>")
        let tabs = makeTabs(upgradesLocalHostsToHTTPS: true)
        let page = URL(string: "http://localhost:\(server.port)/page")!

        // Upgraded to https://localhost, which fails, as the server only speaks plain http.
        let tab = try #require(tabs.newTab(url: page))
        #expect(await eventually(timeout: .seconds(10)) { tab.loadProblem == .insecureConnection(page) })
        #expect(!server.requests.contains { $0.path == "/page" })

        // The owner agrees: it opens over http, and shows as not secure.
        tabs.continueInsecurely(in: tab)
        #expect(await eventually(timeout: .seconds(10)) { tab.url == page && tab.title == "Plain" })
        #expect(tab.loadProblem == nil)
        #expect(tab.security == .notSecure)

        // Other pages of the site do not ask again.
        let other = URL(string: "http://localhost:\(server.port)/other")!
        tab.load(other)
        #expect(await eventually(timeout: .seconds(10)) { tab.url == other && tab.webView?.isLoading == false })
        #expect(tab.loadProblem == nil)
    }

    @Test func pagesOutsideTheWebHaveNoSecurityState() async throws {
        let server = TestSchemeHandler(html: "<html><body>Hi</body></html>")
        let tabs = makeTabs(server: server)
        let tab = try #require(tabs.newTab(url: URL(string: "yabtest://local.example/index.html")!))
        #expect(await eventually { tab.webView?.isLoading == false && tab.url != nil })
        #expect(tab.security == nil)
    }

    @Test func blockedPagesAreReported() async throws {
        let server = TestSchemeHandler(html: "<html><body>Hi</body></html>")
        let tabs = makeTabs(contentBlocker: try makeTestContentBlocker(filters: "||malware.example^$document"), server: server)
        let blocked = URL(string: "yabtest://malware.example/index.html")!

        let tab = try #require(tabs.newTab(url: blocked))
        #expect(await eventually { tab.loadProblem == .blocked(blocked) })
        #expect(!server.requestedURLs.contains(blocked.absoluteString))

        tab.load(URL(string: "yabtest://fine.example/index.html")!)
        #expect(await eventually { tab.loadProblem == nil && tab.url?.host() == "fine.example" })
    }

    @Test func blockingCanBeSwitchedOffPerSite() async throws {
        let blocker = try makeTestContentBlocker(filters: """
            ||ads.example^
            site.example##+js(set, yabTest, 42)
            """)
        let server = TestSchemeHandler(html: """
            <html><head><script>document.title = String(window.yabTest);</script></head>
            <body><img src="yabtest://ads.example/banner.gif"></body></html>
            """)
        let tabs = makeTabs(contentBlocker: blocker, server: server)
        let tab = try #require(tabs.newTab(url: URL(string: "yabtest://site.example/index.html")!))
        #expect(await eventually { await evaluate("return document.title", in: tab) as? String == "42" })
        #expect(!server.requestedURLs.contains("yabtest://ads.example/banner.gif"))
        #expect(tabs.isBlockingEnabled(forSiteOf: tab))

        // Switched off: ads load, scriptlets stay out, the privacy signal stays in.
        tabs.setBlocking(false, forSiteOf: tab)
        #expect(!tabs.isBlockingEnabled(forSiteOf: tab))
        #expect(await eventually { server.requestedURLs.contains("yabtest://ads.example/banner.gif") })
        #expect(await eventually { await evaluate("return document.title", in: tab) as? String == "undefined" })
        #expect(await evaluate("return navigator.globalPrivacyControl", in: tab) as? Bool == true)

        // Other sites are still blocked.
        server.reset()
        server.html = "<html><body><img src=\"yabtest://ads.example/other.gif\"></body></html>"
        tab.load(URL(string: "yabtest://other.example/index.html")!)
        #expect(await eventually { tab.url?.host() == "other.example" && tab.webView?.isLoading == false })
        #expect(!server.requestedURLs.contains("yabtest://ads.example/other.gif"))

        // And switched back on.
        tab.load(URL(string: "yabtest://site.example/again.html")!)
        #expect(await eventually { tab.url?.lastPathComponent == "again.html" })
        tabs.setBlocking(true, forSiteOf: tab)
        #expect(tabs.isBlockingEnabled(forSiteOf: tab))
    }
}
