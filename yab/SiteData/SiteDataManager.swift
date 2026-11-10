import Foundation
import WebKit

/// The kinds of data a site can keep, in words people know.
nonisolated enum SiteDataKind: String, CaseIterable, Sendable, Comparable {
    case cookies
    /// Local and session storage, IndexedDB, WebSQL and file system data.
    case savedData
    /// Copies of pages, images and scripts kept to load faster.
    case cache
    /// Service workers, which can run without the page being open.
    case backgroundWork
    /// Media keys, search history in forms and the like.
    case other

    init(dataType: String) {
        switch dataType {
        case WKWebsiteDataTypeCookies:
            self = .cookies
        case WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases,
             WKWebsiteDataTypeWebSQLDatabases, WKWebsiteDataTypeFileSystem:
            self = .savedData
        case WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache:
            self = .cache
        case WKWebsiteDataTypeServiceWorkerRegistrations:
            self = .backgroundWork
        default:
            self = .other
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

nonisolated struct CookieSummary: Hashable, Sendable {
    var name: String
    /// The host it belongs to, like `de.wikipedia.org`.
    var domain: String
    /// `nil` for cookies that end with the browsing session.
    var expires: Date?
    var isSecure: Bool
    /// Hidden from the page's scripts.
    var isHTTPOnly: Bool

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        expires = cookie.expiresDate
        isSecure = cookie.isSecure
        isHTTPOnly = cookie.isHTTPOnly
    }
}

/// Everything one site has stored, with all its subdomains grouped under it:
/// `wikipedia.org` covers `de.wikipedia.org` and `profile.wikipedia.org`.
nonisolated struct SiteDataEntry: Identifiable, Hashable, Sendable {
    var id: String { site }
    /// WebKit's grouping, usually the registrable domain like `wikipedia.org`.
    var site: String
    var kinds: Set<SiteDataKind>
    var cookies: [CookieSummary]

    /// Whether a page on `host` belongs to this site.
    func contains(host: String) -> Bool {
        SiteDataEntry.host(host, belongsTo: site)
    }

    static func host(_ host: String, belongsTo site: String) -> Bool {
        let host = host.lowercased()
        let site = site.lowercased()
        return host == site || host.hasSuffix("." + site)
    }
}

/// Lists, searches and deletes what websites have stored in a data store.
final class SiteDataManager {
    let store: WKWebsiteDataStore

    init(store: WKWebsiteDataStore = .default()) {
        self.store = store
    }

    /// One entry per site, sorted by name.
    func entries() async -> [SiteDataEntry] {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let cookies = await store.httpCookieStore.allCookies().map(CookieSummary.init)

        var entries: [String: SiteDataEntry] = [:]
        for record in records {
            let site = record.displayName.lowercased()
            var entry = entries[site] ?? SiteDataEntry(site: site, kinds: [], cookies: [])
            entry.kinds.formUnion(record.dataTypes.map(SiteDataKind.init(dataType:)))
            entries[site] = entry
        }
        for site in entries.keys {
            entries[site]?.cookies = cookies
                .filter { SiteDataEntry.host($0.domain, belongsTo: site) }
                .sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }
        }
        return entries.values.sorted { $0.site < $1.site }
    }

    /// The site a host's data is grouped under, like `wikipedia.org` for `de.wikipedia.org`,
    /// if that site has stored anything.
    func site(containing host: String) async -> String? {
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records
            .map { $0.displayName.lowercased() }
            .filter { SiteDataEntry.host(host, belongsTo: $0) }
            .max { $0.count < $1.count }
    }

    /// Deletes everything the given sites stored, including their subdomains.
    func removeData(of sites: Set<String>) async {
        let sites = Set(sites.map { $0.lowercased() })
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let matching = records.filter { sites.contains($0.displayName.lowercased()) }
        guard !matching.isEmpty else { return }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching)
    }

    func removeAllData() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Simple search: "wikipedia" finds `wikipedia.org`, and so does a pasted
    /// `https://de.wikipedia.org/wiki/Swift`.
    nonisolated static func search(_ entries: [SiteDataEntry], for query: String, titles: [String: String] = [:]) -> [SiteDataEntry] {
        var query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        if let host = URL(string: query)?.host(), query.contains("://") {
            query = host
        }
        if query.hasPrefix("www.") {
            query.removeFirst(4)
        }
        return entries.filter { entry in
            entry.site.contains(query)
                || SiteDataEntry.host(query, belongsTo: entry.site)
                || (titles[entry.site]?.lowercased().contains(query) ?? false)
        }
    }
}
