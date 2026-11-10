import Foundation
import Testing
@testable import yab

struct FilterListMetadataTests {
    let day: TimeInterval = 24 * 60 * 60

    @Test func easyListHeader() {
        let metadata = FilterListMetadata.parse("""
            [Adblock Plus 2.0]
            ! Version: 202611091034
            ! Title: EasyList
            ! Last modified: 09 Nov 2026 10:34 UTC
            ! Expires: 4 days (update frequency)
            ! Homepage: https://easylist.to/
            ||ads.example^
            ##.ad
            ! Version: 999 (not a header any more)
            """)
        #expect(metadata.title == "EasyList")
        #expect(metadata.version == "202611091034")
        #expect(metadata.lastModified == ISO8601DateFormatter().date(from: "2026-11-09T10:34:00Z"))
        #expect(metadata.expires == 4 * day)
        #expect(metadata.filterCount == 2)
        #expect(metadata.looksLikeFilterList)
    }

    @Test func uBlockOriginMirrorHeader() {
        let metadata = FilterListMetadata.parse("""
            [Adblock Plus 2.0]
            ! Title: EasyList
            ! Expires: 6 days (update frequency)
            ! Last modified: Mon, 09 Nov 2026 01:13:15 +0000
            ||ads.example^
            """)
        #expect(metadata.version == nil)
        #expect(metadata.lastModified == ISO8601DateFormatter().date(from: "2026-11-09T01:13:15Z"))
        #expect(metadata.expires == 6 * day)
    }

    @Test(arguments: [
        ("! Expires: 12 hours", 0.5),
        ("! Expires: 8 hours", 8.0 / 24), // uBlock Origin's Quick fixes
        ("! Expires: 1 hour", 8.0 / 24), // raised to the minimum
        ("! Expires: 30 days", 14.0), // lowered to the maximum
        ("! Expires: soon", 4.0), // unreadable, so the default
        ("! Title: No expiry", 4.0),
    ])
    func updateInterval(header: String, days: Double) {
        let metadata = FilterListMetadata.parse("[Adblock Plus 2.0]\n\(header)\n||ads.example^")
        #expect(metadata.updateInterval == days * day)
    }

    @Test func isoUpdatedDate() {
        let metadata = FilterListMetadata.parse("! Title: Sites\n! Updated: 2026-11-09T12:09:01Z\n||a.example^")
        #expect(metadata.lastModified == ISO8601DateFormatter().date(from: "2026-11-09T12:09:01Z"))
    }

    @Test func webPageIsNotAFilterList() {
        let metadata = FilterListMetadata.parse("<!DOCTYPE html>\n<html><body>Sign in to Wi-Fi</body></html>")
        #expect(!metadata.looksLikeFilterList)
    }

    @Test func comparesVersionsThenDates() {
        let older = FilterListMetadata(version: "202611091034", lastModified: Date(timeIntervalSince1970: 200))
        let newer = FilterListMetadata(version: "202611101200", lastModified: Date(timeIntervalSince1970: 100))
        #expect(newer.isNewer(than: older) == true)
        #expect(older.isNewer(than: newer) == false)

        let mirror = FilterListMetadata(lastModified: Date(timeIntervalSince1970: 300))
        #expect(mirror.isNewer(than: older) == true)

        #expect(FilterListMetadata().isNewer(than: older) == nil)
    }
}

struct BlockedSitesFormatTests {
    let list = """
        # Title: Online Malicious Domains Blocklist
        # Updated: 2026-11-09T12:09:01Z
        # Expires: 12 hours (update frequency)
        1.92.101.221
        Malware.Example
        not a host
        """

    @Test func sitesBecomeNavigationBlocks() throws {
        let source = try FilterListSource(data: Data(list.utf8), origin: .bundled, format: .blockedSites)
        #expect(source.metadata.title == "Online Malicious Domains Blocklist")
        #expect(source.metadata.expires == 12.0 * 60 * 60)
        #expect(source.metadata.lastModified == ISO8601DateFormatter().date(from: "2026-11-09T12:09:01Z"))
        #expect(source.metadata.filterCount == 2)

        let rules = FilterListConverter().convert(source.text).rules
        #expect(rules.count == 2)
        #expect(rules.allSatisfy { $0.action == .block && $0.trigger.resourceType == [.topDocument] })
        #expect(rules.last?.trigger.urlFilter == URLFilterTranslator.domainAnchor + #"malware\.example[/:]"#)
    }

    @Test func webPageIsRejected() {
        let page = "<!DOCTYPE html>\n<html><body>\nSign in to Wi-Fi\nwifi.example\n</body></html>"
        #expect(throws: ContentBlockerError.self) {
            try FilterListSource(data: Data(page.utf8), origin: .downloaded, format: .blockedSites)
        }
    }
}
