import Foundation

/// Parses scriptlet filters such as `example.com,google.*##+js(set, ads, false)`.
nonisolated enum ScriptletFilterParser {
    struct Filter: Equatable {
        /// The scriptlet's canonical name (`set-constant.js`) followed by its arguments.
        /// Empty for `#@#+js()`, which turns off every scriptlet.
        var call: [String]
        /// Hostnames and entities (`google.*`) it applies to. Empty means everywhere.
        var hostnames: [String]
        /// Hostnames from `~example.com`.
        var excludedHostnames: [String]
        var isException: Bool
    }

    static func parse(
        domains: Substring,
        body: Substring,
        isException: Bool,
        isTrusted: Bool,
        library: ScriptletLibrary
    ) -> Result<Filter, FilterSkipReason> {
        let body = body.trimmingWhitespace()
        guard body.hasPrefix("+js("), body.hasSuffix(")") else { return .failure(.invalid) }
        var arguments = ScriptletArguments.split(body.dropFirst(4).dropLast())

        var call: [String] = []
        if let token = arguments.first {
            guard let scriptlet = library.scriptlet(named: token) else { return .failure(.unknownScriptlet) }
            if scriptlet.requiresTrust, !isTrusted { return .failure(.untrustedScriptlet) }
            arguments[0] = scriptlet.name
            call = arguments
        } else if !isException {
            return .failure(.invalid)
        }

        var hostnames: [String] = []
        var excludedHostnames: [String] = []
        var droppedHostnames = false
        for rawEntry in domains.split(separator: ",") {
            var entry = rawEntry.trimmingWhitespace()
            let isExcluded = entry.hasPrefix("~")
            if isExcluded { entry = entry.dropFirst() }
            let hostname = entry.lowercased()
            if hostname == "*" { continue }
            guard isSupportedHostname(hostname) else {
                if !isExcluded { droppedHostnames = true }
                continue
            }
            if isExcluded {
                excludedHostnames.append(hostname)
            } else {
                hostnames.append(hostname)
            }
        }
        if hostnames.isEmpty, droppedHostnames { return .failure(.unsupportedDomain) }
        // Like uBlock Origin: only exceptions may apply everywhere, and exceptions to
        // exceptions (`~example.com#@#+js(...)`) mean nothing.
        if hostnames.isEmpty, !isException { return .failure(.invalid) }
        if isException { excludedHostnames = [] }

        return .success(Filter(call: call, hostnames: hostnames, excludedHostnames: excludedHostnames, isException: isException))
    }

    /// ASCII hostnames and entities like `google.*`. Not regular expressions or `a.com>>` ancestors.
    private static func isSupportedHostname(_ hostname: String) -> Bool {
        var name = Substring(hostname)
        if name.hasSuffix(".*") { name = name.dropLast(2) }
        return !name.isEmpty && name.utf8.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x2D || byte == 0x5F
        }
    }
}

/// Splits scriptlet arguments the way uBlock Origin does: commas separate arguments,
/// `\,` is a literal comma, and quoted arguments ("…", '…' or `…`) may contain commas.
/// A port of uBlock Origin's `ArglistParser` (src/js/arglist-parser.js).
nonisolated enum ScriptletArguments {
    private struct Parser {
        let pattern: [Character]
        var separator: Character = ","
        var quoteBegin = 0
        var argumentBegin = 0
        var argumentEnd = 0
        var separatorEnd = 0
        var needsUnescaping = false

        init(_ text: Substring) {
            pattern = Array(text)
        }

        mutating func nextArgument(from begin: Int) -> String {
            let length = pattern.count
            quoteBegin = begin + leadingWhitespace(from: begin)
            if quoteBegin < length, ["\"", "'", "`"].contains(pattern[quoteBegin]) {
                findSeparator(pattern[quoteBegin])
                if argumentEnd != length {
                    let quoteEnd = argumentEnd + 1
                    separatorEnd = quoteEnd + leadingWhitespace(from: quoteEnd)
                    if separatorEnd == length {
                        return value()
                    }
                    if pattern[separatorEnd] == "," {
                        separatorEnd += 1
                        return value()
                    }
                }
            }
            findSeparator(",")
            let separatorBegin = argumentEnd
            separatorEnd = separatorBegin < length ? separatorBegin + 1 : separatorBegin
            argumentEnd -= trailingWhitespace(before: separatorBegin)
            return value()
        }

        /// Finds the next unescaped `character`, starting inside the quote if it is one.
        private mutating func findSeparator(_ character: Character) {
            argumentBegin = character == "," ? quoteBegin : quoteBegin + 1
            argumentEnd = argumentBegin
            needsUnescaping = false
            separator = character
            while argumentEnd < pattern.count {
                guard let position = pattern[argumentEnd...].firstIndex(of: character) else {
                    argumentEnd = pattern.count
                    return
                }
                if !hasOddTrailingBackslashes(before: position) {
                    argumentEnd = position
                    return
                }
                needsUnescaping = true
                argumentEnd = position + 1
            }
        }

        private func value() -> String {
            guard argumentEnd > argumentBegin else { return "" }
            let text = String(pattern[argumentBegin..<argumentEnd])
            return needsUnescaping ? Self.unescape(text, separator) : text
        }

        /// Removes the backslash in front of each escaped `separator`.
        private static func unescape(_ text: String, _ separator: Character) -> String {
            var remaining = Array(text)
            var output: [Character] = []
            while let position = remaining.lastIndex(of: separator) {
                output.insert(contentsOf: remaining[position...], at: 0)
                remaining.removeSubrange(position...)
                let backslashes = remaining.reversed().prefix { $0 == "\\" }.count
                guard backslashes > 0 else { continue }
                let kept = backslashes % 2 == 1 ? backslashes - 1 : backslashes
                output.insert(contentsOf: repeatElement("\\", count: kept), at: 0)
                remaining.removeLast(backslashes)
            }
            return String(remaining + output)
        }

        private func hasOddTrailingBackslashes(before position: Int) -> Bool {
            var count = 0
            var index = position - 1
            while index >= 0, pattern[index] == "\\" {
                count += 1
                index -= 1
            }
            return count % 2 == 1
        }

        private func leadingWhitespace(from index: Int) -> Int {
            guard index < pattern.count else { return 0 }
            return pattern[index...].prefix { $0.isWhitespace }.count
        }

        private func trailingWhitespace(before index: Int) -> Int {
            pattern[..<index].reversed().prefix { $0.isWhitespace }.count
        }
    }

    static func split(_ text: Substring) -> [String] {
        var parser = Parser(text)
        var arguments: [String] = []
        var index = 0
        while true {
            let argument = parser.nextArgument(from: index)
            if index == parser.pattern.count { break }
            arguments.append(argument)
            index = parser.separatorEnd
        }
        return arguments
    }
}
