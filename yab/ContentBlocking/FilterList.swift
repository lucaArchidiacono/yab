import Foundation

/// A filter list shipped inside the app and kept up to date from the internet.
nonisolated struct FilterList: Sendable, Hashable {
    enum Format: Sendable, Hashable {
        /// Adblock Plus / uBlock Origin filter syntax.
        case filters
        /// One dangerous site per line, with `#` comments. Navigating to those sites is blocked.
        case blockedSites
    }

    let identifier: String
    let name: String
    /// File name without the `.txt` extension, for both the bundled and the downloaded copy.
    let resourceName: String
    /// Trusted lists may use scriptlets that can do almost anything to a page.
    /// Like uBlock Origin, only its own lists are trusted.
    let isTrusted: Bool
    let format: Format
    /// Where fresh copies come from, tried in order. Mirrors are uBlock Origin's.
    let updateURLs: [URL]

    init(
        identifier: String,
        name: String,
        resourceName: String,
        isTrusted: Bool = false,
        format: Format = .filters,
        updateURLs: [URL]
    ) {
        self.identifier = identifier
        self.name = name
        self.resourceName = resourceName
        self.isTrusted = isTrusted
        self.format = format
        self.updateURLs = updateURLs
    }

    static let uBlockFilters = uBlockOrigin("filters", name: "uBlock filters – Ads")
    static let uBlockBadware = uBlockOrigin("badware", name: "uBlock filters – Badware risks")
    static let uBlockPrivacy = uBlockOrigin("privacy", name: "uBlock filters – Privacy")
    static let uBlockQuickFixes = uBlockOrigin("quick-fixes", name: "uBlock filters – Quick fixes")
    static let uBlockUnbreak = uBlockOrigin("unbreak", name: "uBlock filters – Unbreak")

    /// uBlock Origin's lists, as combined by its CDN with `!#include`s resolved.
    private static func uBlockOrigin(_ file: String, name: String) -> FilterList {
        FilterList(
            identifier: "ublock-\(file)",
            name: name,
            resourceName: "ublock-\(file)",
            isTrusted: true,
            updateURLs: [
                URL(string: "https://ublockorigin.github.io/uAssetsCDN/filters/\(file).min.txt")!,
                URL(string: "https://ublockorigin.pages.dev/filters/\(file).min.txt")!,
            ]
        )
    }

    static let easyList = FilterList(
        identifier: "easylist",
        name: "EasyList",
        resourceName: "easylist",
        updateURLs: [
            URL(string: "https://easylist.to/easylist/easylist.txt")!,
            URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt")!,
            URL(string: "https://ublockorigin.pages.dev/thirdparties/easylist.txt")!,
        ]
    )

    static let easyPrivacy = FilterList(
        identifier: "easyprivacy",
        name: "EasyPrivacy",
        resourceName: "easyprivacy",
        updateURLs: [
            URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt")!,
            URL(string: "https://ublockorigin.pages.dev/thirdparties/easyprivacy.txt")!,
        ]
    )

    /// Sites URLhaus has seen spreading malware. The full list also names individual
    /// malware files (mostly Windows programs), which is 11 MB every 12 hours for little
    /// gain on an iPhone, so only whole sites are used.
    static let maliciousSites = FilterList(
        identifier: "malicious-sites",
        name: "Online Malicious Domains Blocklist",
        resourceName: "malicious-sites",
        format: .blockedSites,
        updateURLs: [
            URL(string: "https://curbengh.github.io/malware-filter/urlhaus-filter-domains-online.txt")!,
            URL(string: "https://malware-filter.gitlab.io/urlhaus-filter/urlhaus-filter-domains-online.txt")!,
        ]
    )

    /// uBlock Origin's default selection, with malicious sites.
    static let bundled: [FilterList] = [
        .uBlockFilters, .uBlockBadware, .uBlockPrivacy, .uBlockQuickFixes, .uBlockUnbreak,
        .easyList, .easyPrivacy,
        .maliciousSites,
    ]
}
