import Foundation

/// Turns what someone types into the address field into a URL: a web address if it
/// looks like one, otherwise a search.
nonisolated enum AddressInput {
    /// DuckDuckGo: no tracking, no profile of what you search.
    static let searchURL = "https://duckduckgo.com/?q="

    static func url(for text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if let url = URL(string: input), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host() != nil {
            return url
        }
        if !input.contains(where: \.isWhitespace), looksLikeHost(input), let url = URL(string: "https://" + input), url.host() != nil {
            return url
        }
        return searchURL(for: input)
    }

    static func searchURL(for query: String) -> URL? {
        // Only unreserved characters stay as they are, so `+` in "c++" is not read as a space.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: searchURL + encoded)
    }

    /// `example.com`, `example.com/path`, `localhost:8080`, `192.168.1.1`.
    private static func looksLikeHost(_ input: String) -> Bool {
        let host = input.prefix { $0 != "/" && $0 != "?" && $0 != "#" }.split(separator: ":").first.map(String.init) ?? ""
        if host.lowercased() == "localhost" { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return false }
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return labels.count == 4 }
        // A top-level domain is letters only, like `com` or `swiss`.
        return labels.last!.count >= 2 && labels.last!.allSatisfy(\.isLetter)
    }
}
