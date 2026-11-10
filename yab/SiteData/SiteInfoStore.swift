import Foundation
import LinkPresentation
import os
import UIKit

/// A site's name and icon, for the site data list.
nonisolated struct SiteInfo: Codable, Equatable, Sendable {
    var site: String
    var title: String?
    var hasIcon: Bool
    var fetched: Date
}

/// Remembers names and icons of sites opened in normal tabs.
///
/// Apple's LinkPresentation fetches them from the site's root, like
/// `https://wikipedia.org`, so the name is the site's own ("Wikipedia") rather than
/// a page title. Only sites opened in a normal tab are looked up: third parties that
/// stored data, like ad networks, are never contacted. Hacker mode records nothing.
final class SiteInfoStore {
    typealias Fetch = (URL) async throws -> (title: String?, icon: Data?)
    /// The site a host's data is grouped under, if it stored anything yet.
    typealias SiteForHost = (String) async -> String?

    /// Sites change names and icons rarely.
    static let refreshInterval: TimeInterval = 30 * 24 * 60 * 60
    /// A lookup that found nothing is tried again after this long, not on every visit.
    static let retryInterval: TimeInterval = 24 * 60 * 60

    private static let logger = Logger(subsystem: "ch.archiluc.yab", category: "SiteInfoStore")

    private let directory: URL
    private let fetch: Fetch
    private let siteForHost: SiteForHost
    private let now: () -> Date

    private var state: State
    /// Which site each visited host's data is grouped under, once known.
    private var sitesByHost: [String: String] = [:]
    private var lookups: [String: Task<SiteInfo?, Never>] = [:]
    /// Lookups run one at a time, as each can start a hidden web page.
    private var queue: Task<Void, Never>?

    private struct State: Codable {
        var infos: [String: SiteInfo] = [:]
        /// Hosts opened in normal tabs. Only their sites get looked up.
        var visitedHosts: Set<String> = []
    }

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "SiteInfo", directoryHint: .isDirectory),
        fetch: @escaping Fetch = SiteInfoStore.linkPresentation,
        siteForHost: @escaping SiteForHost,
        now: @escaping () -> Date = { Date() }
    ) {
        self.directory = directory
        self.fetch = fetch
        self.siteForHost = siteForHost
        self.now = now
        if let data = try? Data(contentsOf: directory.appending(path: "sites.json")),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State()
        }
    }

    // MARK: - Reading

    func info(forSite site: String) -> SiteInfo? {
        state.infos[site.lowercased()]
    }

    func icon(forSite site: String) -> UIImage? {
        guard info(forSite: site)?.hasIcon == true else { return nil }
        return UIImage(contentsOfFile: iconURL(forSite: site).path)
    }

    /// Site → name, for searching by name.
    var titles: [String: String] {
        state.infos.compactMapValues(\.title)
    }

    // MARK: - Learning about sites

    /// Call when a normal tab finishes loading a page.
    func noteVisit(to host: String) {
        let host = host.lowercased()
        if state.visitedHosts.insert(host).inserted {
            save()
        }
        Task {
            let site: String?
            if let known = sitesByHost[host] {
                site = known
            } else {
                site = await siteForHost(host)
                sitesByHost[host] = site
            }
            if let site {
                _ = await loadInfo(forSite: site)
            }
        }
    }

    /// The cached info, fetched first if the site was opened in a normal tab and its
    /// info is missing or old. `nil` for sites that were never opened.
    func loadInfo(forSite site: String) async -> SiteInfo? {
        let site = site.lowercased()
        if let cached = state.infos[site] {
            let isEmpty = cached.title == nil && !cached.hasIcon
            let age = now().timeIntervalSince(cached.fetched)
            if age < (isEmpty ? Self.retryInterval : Self.refreshInterval) {
                return cached
            }
        }
        guard state.visitedHosts.contains(where: { SiteDataEntry.host($0, belongsTo: site) }) else { return nil }
        if let running = lookups[site] {
            return await running.value
        }

        let previous = queue
        let lookup = Task { () -> SiteInfo? in
            await previous?.value
            return await lookUp(site)
        }
        lookups[site] = lookup
        queue = Task { _ = await lookup.value }
        let info = await lookup.value
        lookups[site] = nil
        return info
    }

    private func lookUp(_ site: String) async -> SiteInfo? {
        do {
            let (title, icon) = try await fetch(URL(string: "https://\(site)/")!)
            if let icon {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try icon.write(to: iconURL(forSite: site), options: .atomic)
            }
            let info = SiteInfo(site: site, title: title, hasIcon: icon != nil, fetched: now())
            state.infos[site] = info
            save()
            return info
        } catch {
            Self.logger.info("No info for \(site, privacy: .public): \(error, privacy: .public)")
            // Remember the attempt, keeping whatever was found before.
            var info = state.infos[site] ?? SiteInfo(site: site, title: nil, hasIcon: false, fetched: now())
            info.fetched = now()
            state.infos[site] = info
            save()
            return info
        }
    }

    // MARK: - Forgetting

    /// Forgets a site's name, icon and visits, for when its data is deleted.
    func forget(site: String) {
        let site = site.lowercased()
        state.infos[site] = nil
        state.visitedHosts = state.visitedHosts.filter { !SiteDataEntry.host($0, belongsTo: site) }
        sitesByHost = sitesByHost.filter { $0.value != site }
        try? FileManager.default.removeItem(at: iconURL(forSite: site))
        save()
    }

    func forgetAll() {
        state = State()
        sitesByHost = [:]
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Files

    private func iconURL(forSite site: String) -> URL {
        directory.appending(path: "\(site.lowercased()).png")
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: directory.appending(path: "sites.json"), options: .atomic)
        } catch {
            Self.logger.error("Could not save site info: \(error, privacy: .public)")
        }
    }

    /// Asks LinkPresentation for the site's name and icon. The icon is scaled down to
    /// 64 points, which is all a list needs.
    static func linkPresentation(_ url: URL) async throws -> (title: String?, icon: Data?) {
        let provider = LPMetadataProvider()
        provider.timeout = 15
        let metadata = try await provider.startFetchingMetadata(for: url)
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)

        var icon: Data?
        if let iconProvider = metadata.iconProvider, iconProvider.canLoadObject(ofClass: UIImage.self) {
            icon = await withCheckedContinuation { continuation in
                iconProvider.loadObject(ofClass: UIImage.self) { image, _ in
                    continuation.resume(returning: (image as? UIImage).flatMap(Self.thumbnail))
                }
            }
        }
        return (title?.isEmpty == false ? title : nil, icon)
    }

    nonisolated private static func thumbnail(of image: UIImage) -> Data? {
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
