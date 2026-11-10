import Foundation
import Synchronization
import Testing
import WebKit
@testable import yab

/// Updates against a fake server and clock, compiled by real WebKit.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FilterListUpdateTests {
    @Test func nothingIsDownloadedBeforeTheListExpires() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 1, filters: filters("one")))
        fixture.now = UpdateFixture.listDate.addingTimeInterval(3 * day)

        let blocker = fixture.makeContentBlocker()
        await blocker.updateIfDue()

        #expect(fixture.server.requests.isEmpty)
        #expect(blocker.status(of: fixture.list)?.origin == .bundled)
    }

    @Test func expiredListIsReplacedByNewerDownload() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 1, filters: filters("one")))
        fixture.server.respond(to: UpdateFixture.primary, with: listText(version: 2, filters: filters("two")))
        fixture.now = UpdateFixture.listDate.addingTimeInterval(5 * day)

        let blocker = fixture.makeContentBlocker()
        await blocker.updateIfDue()

        let status = try #require(blocker.status(of: fixture.list))
        #expect(status.origin == .downloaded)
        #expect(status.metadata.version == "2")
        #expect(FileManager.default.fileExists(atPath: fixture.locations.downloadURL(for: fixture.list).path))

        // The rules compiled from version 1 are removed from the store.
        let identifiers: [String]? = await fixture.store.availableIdentifiers()
        #expect(identifiers == blocker.ruleListIdentifiers)

        // After a relaunch, the downloaded list is used without downloading it again.
        let relaunched = fixture.makeContentBlocker()
        await relaunched.updateIfDue()
        #expect(relaunched.status(of: fixture.list)?.metadata.version == "2")
        #expect(fixture.server.requests.count == 1)
    }

    @Test func updatedRulesReachAttachedWebViews() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 1, filters: filters("one")))
        fixture.server.respond(to: UpdateFixture.primary, with: listText(version: 2, filters: filters("two")))
        let blocker = fixture.makeContentBlocker()

        let browser = TestBrowser(html: images(["one.example/1.gif", "two.example/1.gif"]))
        await blocker.attach(to: browser.webView.configuration.userContentController)
        try await browser.load()
        #expect(browser.server.requestedURLs.contains("yabtest://two.example/1.gif"))
        #expect(!browser.server.requestedURLs.contains("yabtest://one.example/1.gif"))

        fixture.now = UpdateFixture.listDate.addingTimeInterval(5 * day)
        await blocker.updateIfDue()

        // New image paths, so WebKit's memory cache cannot answer for the server.
        browser.server.reset()
        browser.server.html = images(["one.example/2.gif", "two.example/2.gif"])
        try await browser.load()
        #expect(browser.server.requestedURLs.contains("yabtest://one.example/2.gif"))
        #expect(!browser.server.requestedURLs.contains("yabtest://two.example/2.gif"))
    }

    @Test func invalidDownloadKeepsCurrentListAndRetriesLater() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 1, filters: filters("one")))
        let loginPage = "<!DOCTYPE html><html><body>Sign in to Wi-Fi</body></html>"
        fixture.server.respond(to: UpdateFixture.primary, with: loginPage)
        fixture.server.respond(to: UpdateFixture.mirror, with: loginPage)
        fixture.now = UpdateFixture.listDate.addingTimeInterval(5 * day)

        let blocker = fixture.makeContentBlocker()
        await blocker.updateIfDue()
        #expect(blocker.status(of: fixture.list)?.origin == .bundled)
        #expect(fixture.server.requests == [UpdateFixture.primary, UpdateFixture.mirror])

        fixture.now.addTimeInterval(30 * 60)
        await blocker.updateIfDue()
        #expect(fixture.server.requests.count == 2)

        fixture.now.addTimeInterval(31 * 60)
        await blocker.updateIfDue()
        #expect(fixture.server.requests.count == 4)
    }

    @Test func sameVersionIsNotCompiledAgain() async throws {
        let text = listText(version: 1, filters: filters("one"))
        let fixture = try UpdateFixture(bundled: text)
        fixture.server.respond(to: UpdateFixture.primary, with: text)
        fixture.now = UpdateFixture.listDate.addingTimeInterval(5 * day)

        let blocker = fixture.makeContentBlocker()
        _ = await blocker.ruleLists()
        let before = blocker.ruleListIdentifiers
        await blocker.updateIfDue()

        let status = try #require(blocker.status(of: fixture.list))
        #expect(status.origin == .bundled)
        #expect(blocker.ruleListIdentifiers == before)
        #expect(status.lastUpdateCheck == fixture.now)

        // The check counts, so the next one is a full interval later.
        fixture.now.addTimeInterval(1 * day)
        await blocker.updateIfDue()
        #expect(fixture.server.requests.count == 1)
    }

    @Test func listThatLostMostFiltersIsRejected() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 1, filters: filters("one", count: 10)))
        fixture.server.respond(to: UpdateFixture.primary, with: listText(version: 2, filters: filters("two", count: 3)))
        fixture.now = UpdateFixture.listDate.addingTimeInterval(5 * day)

        let blocker = fixture.makeContentBlocker()
        await blocker.updateIfDue()

        #expect(blocker.status(of: fixture.list)?.metadata.version == "1")
    }

    @Test func mirrorIsUsedWhenPrimaryFails() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 1, filters: filters("one")))
        fixture.server.respond(to: UpdateFixture.mirror, with: listText(version: 2, filters: filters("two")))
        fixture.now = UpdateFixture.listDate.addingTimeInterval(5 * day)

        let blocker = fixture.makeContentBlocker()
        await blocker.updateIfDue()

        #expect(fixture.server.requests == [UpdateFixture.primary, UpdateFixture.mirror])
        #expect(blocker.status(of: fixture.list)?.metadata.version == "2")
    }

    @Test func newerBundledListWinsOverOlderDownload() async throws {
        let fixture = try UpdateFixture(bundled: listText(version: 3, filters: filters("three")))
        let downloadURL = fixture.locations.downloadURL(for: fixture.list)
        try FileManager.default.createDirectory(at: downloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try listText(version: 2, filters: filters("two")).write(to: downloadURL, atomically: true, encoding: .utf8)

        let blocker = fixture.makeContentBlocker()
        _ = await blocker.ruleLists()

        #expect(blocker.status(of: fixture.list)?.origin == .bundled)
        #expect(blocker.status(of: fixture.list)?.metadata.version == "3")
    }
}

// MARK: - Fixtures

private let day: TimeInterval = 24 * 60 * 60

private func listText(version: Int, filters: [String]) -> String {
    """
    [Adblock Plus 2.0]
    ! Title: Test
    ! Version: \(version)
    ! Last modified: 09 Nov 2026 10:00 UTC
    ! Expires: 4 days (update frequency)
    \(filters.joined(separator: "\n"))
    """
}

/// Blocks `host.example`, padded with more filters to make the list longer.
private func filters(_ host: String, count: Int = 5) -> [String] {
    ["||\(host).example^"] + (1..<count).map { "||\(host)-padding-\($0).example^" }
}

private func images(_ paths: [String]) -> String {
    "<html><body>" + paths.map { "<img src=\"yabtest://\($0)\">" }.joined() + "</body></html>"
}

@MainActor
private final class UpdateFixture {
    static let primary = URL(string: "https://primary.example/test.txt")!
    static let mirror = URL(string: "https://mirror.example/test.txt")!
    static let listDate = ISO8601DateFormatter().date(from: "2026-11-09T10:00:00Z")!

    let list = FilterList(identifier: "test", name: "Test", resourceName: "test", updateURLs: [primary, mirror])
    let locations: ContentBlocker.Locations
    let store: WKContentRuleListStore
    let defaults: UserDefaults
    let server = FakeListServer()
    var now = listDate

    init(bundled: String) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "yab-updates-\(UUID().uuidString)")
        locations = ContentBlocker.Locations(bundled: directory.appending(path: "bundled"), storage: directory.appending(path: "storage"))
        try FileManager.default.createDirectory(at: locations.bundled, withIntermediateDirectories: true)
        try bundled.write(to: locations.bundledURL(for: list), atomically: true, encoding: .utf8)
        store = try #require(WKContentRuleListStore(url: directory.appending(path: "store")))
        defaults = try #require(UserDefaults(suiteName: "yab-tests-\(UUID().uuidString)"))
    }

    func makeContentBlocker() -> ContentBlocker {
        ContentBlocker(
            filterLists: [list],
            store: store,
            defaults: defaults,
            locations: locations,
            fetch: { [server] url in try await server.fetch(url) },
            now: { [unowned self] in now }
        )
    }
}

private final class FakeListServer: Sendable {
    private let state = Mutex<(responses: [URL: Data], requests: [URL])>(([:], []))

    var requests: [URL] {
        state.withLock { $0.requests }
    }

    func respond(to url: URL, with text: String) {
        state.withLock { $0.responses[url] = Data(text.utf8) }
    }

    func fetch(_ url: URL) async throws -> Data {
        try state.withLock { state in
            state.requests.append(url)
            guard let data = state.responses[url] else { throw URLError(.cannotConnectToHost) }
            return data
        }
    }
}
