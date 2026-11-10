import Foundation

/// Parses element hiding filters such as `example.com##.ad` and `##.banner`.
nonisolated enum CosmeticFilterParser {
    enum Separator: String, CaseIterable {
        case hide = "##"
        case hideException = "#@#"
        case extended = "#?#"
        case extendedException = "#@?#"
        // AdGuard CSS and JavaScript injection.
        case css = "#$#"
        case cssException = "#@$#"
        case extendedCSS = "#$?#"
        case extendedCSSException = "#@$?#"
        case javascript = "#%#"
        case javascriptException = "#@%#"
    }

    struct Split {
        var domains: Substring
        var separator: Separator
        var body: Substring
    }

    struct Filter {
        var domains: DomainList
        var selector: String
        var isException: Bool
    }

    /// uBlock Origin / Adblock Plus / AdGuard pseudo-classes that need JavaScript to evaluate.
    /// `:has()` is fine: WebKit supports it natively.
    private static let proceduralOperators = [
        ":has-text(", ":-abp-contains(", ":contains(", ":-abp-properties(", ":matches-css(",
        ":matches-css-before(", ":matches-css-after(", ":xpath(", ":upward(", ":nth-ancestor(",
        ":min-text-length(", ":remove(", ":remove-attr(", ":remove-class(", ":style(",
        ":watch-attr(", ":others(", ":matches-path(", ":matches-attr(", ":matches-prop(",
        ":matches-media(", ":matches-property(", ":spath(", ":if(", ":if-not(", ":properties(",
        ":shadow-dom",
    ]

    /// Longest first, so `#@?#` is not mistaken for `#@#`.
    private static let separatorsByLength = Separator.allCases.sorted { $0.rawValue.count > $1.rawValue.count }

    /// Splits a line at its cosmetic separator, or returns `nil` for network filters.
    static func split(_ line: Substring) -> Split? {
        guard let hash = line.firstIndex(of: "#") else { return nil }
        let rest = line[hash...]
        guard let separator = separatorsByLength.first(where: { rest.hasPrefix($0.rawValue) }) else { return nil }

        let domains = line[..<hash]
        // Network filters like `||example.com/#ad` contain URL characters before the `#`.
        if domains.contains(where: { "/|$^@=:?&[]".contains($0) }) { return nil }

        let body = rest.dropFirst(separator.rawValue.count)
        return Split(domains: domains, separator: separator, body: body)
    }

    static func parse(_ split: Split) -> Result<Filter, FilterSkipReason> {
        let isException: Bool
        switch split.separator {
        case .hide, .extended:
            isException = false
        case .hideException, .extendedException:
            isException = true
        case .css, .cssException, .extendedCSS, .extendedCSSException, .javascript, .javascriptException:
            return .failure(.unsupportedCosmetic)
        }

        let body = split.body.trimmingWhitespace()
        if body.hasPrefix("+js(") { return .failure(.scriptlet) }
        if body.hasPrefix("^") { return .failure(.htmlFilter) }
        if body.isEmpty || body.hasPrefix("+") { return .failure(.unsupportedCosmetic) }

        let selector = body.replacingOccurrences(of: ":-abp-has(", with: ":has(")
        if proceduralOperators.contains(where: { selector.contains($0) }) {
            return .failure(.proceduralCosmetic)
        }

        let domains = DomainList.parse(split.domains, separator: ",")
        if domains.includes.isEmpty, domains.droppedIncludes {
            return .failure(.unsupportedDomain)
        }

        return .success(Filter(domains: domains, selector: selector, isException: isException))
    }
}
