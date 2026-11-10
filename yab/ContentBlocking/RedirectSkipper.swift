import Foundation

/// uBlock Origin's `$urlskip` filters: links that only bounce you through a tracker,
/// like `https://tracker.example/out?url=https%3A%2F%2Fnews.example`, with directions
/// to the real destination inside them.
nonisolated struct RedirectSkipIndex: Codable, Sendable, Equatable {
    struct Rule: Codable, Sendable, Equatable {
        /// A WebKit URL filter, which is also a valid `NSRegularExpression`.
        var urlFilter: String
        var isCaseSensitive: Bool
        /// Empty for exceptions.
        var steps: [String]
    }

    var skips: [Rule] = []
    var exceptions: [Rule] = []

    var count: Int { skips.count + exceptions.count }
}

/// Finds where a tracking link really goes, so the browser can go there directly.
nonisolated struct RedirectSkipper: Sendable {
    private struct CompiledRule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let steps: [String]
    }

    private let skips: [CompiledRule]
    private let exceptions: [CompiledRule]

    init(_ index: RedirectSkipIndex) {
        func compile(_ rules: [RedirectSkipIndex.Rule]) -> [CompiledRule] {
            rules.compactMap { rule in
                let options: NSRegularExpression.Options = rule.isCaseSensitive ? [] : [.caseInsensitive]
                guard let pattern = try? NSRegularExpression(pattern: rule.urlFilter, options: options) else { return nil }
                return CompiledRule(pattern: pattern, steps: rule.steps)
            }
        }
        skips = compile(index.skips)
        exceptions = compile(index.exceptions)
    }

    /// The real destination of a tracking link, or `nil` if `url` is not one.
    func destination(of url: URL) -> URL? {
        let string = url.absoluteString
        let range = NSRange(string.startIndex..., in: string)
        guard !exceptions.contains(where: { $0.pattern.firstMatch(in: string, range: range) != nil }) else { return nil }
        for rule in skips where rule.pattern.firstMatch(in: string, range: range) != nil {
            if let destination = Self.follow(rule.steps, from: string), destination != string, let url = URL(string: destination) {
                return url
            }
        }
        return nil
    }

    /// A port of uBlock Origin's `urlSkip` (src/js/urlskip.js). Each step turns the
    /// current string into the next; any failing step gives up.
    ///
    /// - `?name`: the value of query parameter `name`
    /// - `&i`: the name of the i-th query parameter (1-based)
    /// - `#`: the fragment
    /// - `/regex/`: the first capture group
    /// - `+https`: put `https://` in front
    /// - `-base64`, `-safebase64`, `-uricomponent`: decode
    /// - `-blocked`: uBO-specific, about blocked requests; nothing to do here
    static func follow(_ steps: [String], from url: String) -> String? {
        var current = url
        for step in steps {
            switch step.first {
            case "#" where step == "#":
                current = current.firstIndex(of: "#").map { String(current[current.index(after: $0)...]) } ?? ""
            case "&":
                guard let position = Int(step.dropFirst()), position >= 1 else { return nil }
                let names = queryParameters(of: current).map(\.name)
                guard position <= names.count else { return nil }
                current = names[position - 1]
            case "+" where step == "+https":
                var rest = Substring(current)
                if rest.hasPrefix("https://") {
                    rest = rest.dropFirst(8)
                } else if rest.hasPrefix("http://") {
                    rest = rest.dropFirst(7)
                }
                current = "https://" + rest
            case "-" where step == "-base64":
                guard let decoded = base64Decode(current) else { return nil }
                current = decoded
            case "-" where step == "-safebase64":
                let standard = current.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                guard let decoded = base64Decode(standard) else { return nil }
                current = decoded
            case "-" where step == "-uricomponent":
                guard let decoded = current.removingPercentEncoding else { return nil }
                current = decoded
            case "-" where step == "-blocked":
                continue
            case "/" where step.count > 2 && step.hasSuffix("/"):
                guard let regex = try? NSRegularExpression(pattern: String(step.dropFirst().dropLast())),
                      let match = regex.firstMatch(in: current, range: NSRange(current.startIndex..., in: current)),
                      match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: current) else { return nil }
                current = String(current[range])
            case "?":
                let name = String(step.dropFirst())
                guard let value = queryParameters(of: current).first(where: { $0.name == name })?.value else { return nil }
                current = value.replacingOccurrences(of: " ", with: "%20")
            default:
                return nil
            }
        }
        guard let url = URL(string: current), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else {
            return nil
        }
        return current
    }

    /// Query parameters decoded the way a browser's `URLSearchParams` does: `+` is a space.
    private static func queryParameters(of url: String) -> [(name: String, value: String)] {
        guard let questionMark = url.firstIndex(of: "?") else { return [] }
        var query = url[url.index(after: questionMark)...]
        if let hash = query.firstIndex(of: "#") {
            query = query[..<hash]
        }
        func decode(_ part: Substring) -> String {
            let spaced = part.replacingOccurrences(of: "+", with: " ")
            return spaced.removingPercentEncoding ?? spaced
        }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            if let equals = pair.firstIndex(of: "=") {
                return (decode(pair[..<equals]), decode(pair[pair.index(after: equals)...]))
            }
            return (decode(pair), "")
        }
    }

    /// Like JavaScript's `atob`, which does not insist on `=` padding.
    private static func base64Decode(_ text: String) -> String? {
        var padded = text
        if padded.count % 4 != 0 {
            padded += String(repeating: "=", count: 4 - padded.count % 4)
        }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
