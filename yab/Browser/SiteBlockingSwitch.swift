import Foundation
import os

/// Sites where the owner turned blocking off, usually because something broke.
/// Turning it off for `example.com` covers `www.example.com` and every other subdomain.
final class SiteBlockingSwitch {
    private static let logger = Logger(subsystem: "ch.archiluc.yab", category: "SiteBlockingSwitch")

    private(set) var sitesWithoutBlocking: Set<String>
    private let fileURL: URL?

    /// - Parameter fileURL: Where to keep the list. `nil` keeps it in memory only, as
    ///   hacker mode does.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Set<String>.self, from: data) {
            sitesWithoutBlocking = saved
        } else {
            sitesWithoutBlocking = []
        }
    }

    func isBlockingEnabled(on host: String) -> Bool {
        let host = host.lowercased()
        return !sitesWithoutBlocking.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setBlocking(_ enabled: Bool, on host: String) {
        let host = host.lowercased()
        if enabled {
            sitesWithoutBlocking = sitesWithoutBlocking.filter { !(host == $0 || host.hasSuffix("." + $0)) }
        } else {
            sitesWithoutBlocking.insert(Self.site(of: host))
        }
        save()
    }

    /// `www.example.com` → `example.com`, so the switch covers the whole site.
    static func site(of host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(sitesWithoutBlocking).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Could not save sites without blocking: \(error, privacy: .public)")
        }
    }
}
