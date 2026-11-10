import Foundation
import os
import WebKit

/// Hacker mode's memory: a site's data lives only while a tab shows that site.
///
/// All hacker mode tabs share one in-memory data store, so everything is gone when
/// the app quits anyway. While it runs, data is deleted once no tab has shown its
/// site for `gracePeriod`. Two tabs on Wikipedia keep Wikipedia's data; closing both,
/// or navigating both elsewhere, deletes it. The grace period keeps detours such as
/// logging in through another site, or going back right away, from wiping a site
/// mid-visit.
///
/// Data of sites no tab ever showed, like ad frames embedded in pages, is deleted at
/// the next cleanup.
final class SiteDataForgetter {
    static let defaultGracePeriod: Duration = .seconds(60)

    private static let logger = Logger(subsystem: "ch.archiluc.yab", category: "SiteDataForgetter")

    let store: WKWebsiteDataStore
    private let gracePeriod: Duration
    private let clock = ContinuousClock()

    /// The host each tab shows.
    private var openHosts: [UUID: String] = [:]
    /// When each host was last shown by a tab that has since left it.
    private var lastShown: [String: ContinuousClock.Instant] = [:]
    private var scheduledCleanup: Task<Void, Never>?

    init(store: WKWebsiteDataStore = .nonPersistent(), gracePeriod: Duration = defaultGracePeriod) {
        self.store = store
        self.gracePeriod = gracePeriod
    }

    /// Call whenever a tab's page changes to another URL.
    func tab(_ tab: UUID, didShow url: URL?) {
        let host = url?.host()?.lowercased()
        let previous = openHosts[tab]
        guard host != previous else { return }

        openHosts[tab] = host
        if let previous {
            left(previous)
        }
    }

    func tabDidClose(_ tab: UUID) {
        guard let host = openHosts.removeValue(forKey: tab) else { return }
        left(host)
    }

    private func left(_ host: String) {
        lastShown[host] = clock.now
        scheduleCleanup(after: gracePeriod)
    }

    private func scheduleCleanup(after delay: Duration) {
        scheduledCleanup?.cancel()
        scheduledCleanup = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.forgetClosedSites()
        }
    }

    /// Deletes the data of every site no tab shows and none showed within the grace period.
    func forgetClosedSites() async {
        let now = clock.now
        lastShown = lastShown.filter { now - $0.value < gracePeriod }

        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let closed = records.filter { record in
            let site = record.displayName
            let isOpen = openHosts.values.contains { SiteDataEntry.host($0, belongsTo: site) }
            let wasJustOpen = lastShown.keys.contains { SiteDataEntry.host($0, belongsTo: site) }
            return !isOpen && !wasJustOpen
        }
        if !closed.isEmpty {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: closed)
            Self.logger.notice("Forgot \(closed.count) sites")
        }

        // Sites still within their grace period get another look once the first one is over.
        if let earliest = lastShown.values.min() {
            scheduleCleanup(after: gracePeriod - (now - earliest))
        }
    }
}
