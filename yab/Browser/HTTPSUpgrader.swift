import Foundation

/// Opens sites over HTTPS even when a link says `http`. Sites without working HTTPS are
/// only opened over `http` once the owner agreed to it, after a warning.
///
/// That agreement is remembered for the site and its subdomains until the app quits,
/// so browsing such a site does not ask on every page.
final class HTTPSUpgrader {
    enum Decision: Equatable {
        /// Open the page as it is.
        case proceed
        /// Open this `https` address instead.
        case upgrade(URL)
        /// The site has no working HTTPS. Warn before opening this `http` address.
        case warn(URL)
    }

    /// Hosts the owner agreed to open over `http`, with their subdomains.
    private var allowedHTTPHosts: Set<String> = []
    /// Upgrades still loading: the `http` address each tab was upgraded from.
    private var upgrading: [UUID: URL] = [:]
    private let upgradesLocalHosts: Bool

    /// - Parameter upgradesLocalHosts: Also upgrade `localhost` and the like, for tests.
    init(upgradesLocalHosts: Bool = false) {
        self.upgradesLocalHosts = upgradesLocalHosts
    }

    /// What to do with a page about to open in a tab.
    func decide(_ url: URL, in tab: UUID) -> Decision {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased(),
              upgradesLocalHosts || Self.canUpgrade(host),
              !isHTTPAllowed(on: host) else { return .proceed }

        // An upgraded page that sends us straight back to `http` has no HTTPS to offer.
        if let previous = upgrading[tab], previous.host()?.lowercased() == host {
            upgrading[tab] = nil
            return .warn(url)
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        if components?.port == 80 {
            components?.port = nil
        }
        guard let upgraded = components?.url else { return .proceed }
        upgrading[tab] = url
        return .upgrade(upgraded)
    }

    /// The `http` address to warn about, if an upgraded page failed because the site has
    /// no working HTTPS.
    func failedUpgrade(in tab: UUID, after error: any Error) -> URL? {
        guard let original = upgrading[tab], let host = original.host()?.lowercased() else { return nil }
        let failed = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        guard failed == nil || failed?.host()?.lowercased() == host else { return nil }
        upgrading[tab] = nil
        return Self.isHTTPSProblem(error) ? original : nil
    }

    /// The owner agreed to open the site of `url` over `http`.
    func allowHTTP(for url: URL) {
        if let host = url.host()?.lowercased() {
            allowedHTTPHosts.insert(host)
        }
    }

    /// The upgraded page loaded, or the tab moved on.
    func finish(in tab: UUID) {
        upgrading[tab] = nil
    }

    private func isHTTPAllowed(on host: String) -> Bool {
        allowedHTTPHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Local addresses and bare names usually have no certificate a browser would accept.
    static func canUpgrade(_ host: String) -> Bool {
        guard host.contains("."), !host.contains(":") else { return false }
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        let localSuffixes = [".local", ".localhost", ".internal", ".lan", ".home.arpa"]
        return !localSuffixes.contains { host.hasSuffix($0) }
    }

    /// Errors that mean "no working HTTPS here", as opposed to, say, being offline.
    static func isHTTPSProblem(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        let codes: Set<Int> = [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorCannotConnectToHost,
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorBadServerResponse,
        ]
        return codes.contains(error.code)
    }
}
