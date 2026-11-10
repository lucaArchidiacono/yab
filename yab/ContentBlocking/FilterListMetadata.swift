import Foundation

/// The header of a filter list, such as `! Version: 202611091034` and `! Expires: 4 days`.
nonisolated struct FilterListMetadata: Sendable, Equatable {
    static let defaultUpdateInterval: TimeInterval = 4 * 24 * 60 * 60

    /// Lists ask for anything from hourly to monthly updates. Stay within reason, but
    /// allow uBlock Origin's Quick fixes (8 hours), which carry fixes for broken sites.
    static let updateIntervalRange: ClosedRange<TimeInterval> = (8 * 60 * 60)...(14 * 24 * 60 * 60)

    var title: String?
    var version: String?
    var lastModified: Date?
    var expires: TimeInterval?
    /// Lines that are neither comments nor headers.
    var filterCount = 0
    /// Whether the text starts like a filter list, as opposed to, say, a Wi-Fi login page.
    var looksLikeFilterList = false

    var updateInterval: TimeInterval {
        let interval = expires ?? Self.defaultUpdateInterval
        return min(max(interval, Self.updateIntervalRange.lowerBound), Self.updateIntervalRange.upperBound)
    }

    /// Compares by version number, falling back to the modification date.
    /// Returns `nil` when the two cannot be compared.
    func isNewer(than other: FilterListMetadata) -> Bool? {
        if let version, let otherVersion = other.version, let number = Int(version), let otherNumber = Int(otherVersion) {
            return number > otherNumber
        }
        if let lastModified, let otherLastModified = other.lastModified {
            return lastModified > otherLastModified
        }
        return nil
    }

    static func parse(_ text: String) -> FilterListMetadata {
        var metadata = FilterListMetadata()
        var isFirstLine = true

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingWhitespace()
            if line.isEmpty { continue }
            if isFirstLine {
                metadata.looksLikeFilterList = line.hasPrefix("[") || line.hasPrefix("!")
                isFirstLine = false
            }
            if line.hasPrefix("!") {
                // Header fields come before the first filter.
                if metadata.filterCount == 0 { metadata.readHeaderField(line) }
            } else if !line.hasPrefix("[") {
                metadata.filterCount += 1
            }
        }
        return metadata
    }

    private mutating func readHeaderField(_ line: Substring) {
        guard let colon = line.firstIndex(of: ":") else { return }
        let name = line[line.index(after: line.startIndex)..<colon].trimmingWhitespace().lowercased()
        let value = line[line.index(after: colon)...].trimmingWhitespace()
        guard !value.isEmpty else { return }

        switch name {
        case "title": title = String(value)
        case "version": version = String(value)
        case "last modified", "updated": lastModified = Self.parseDate(value)
        case "expires": expires = Self.parseInterval(value)
        default: break
        }
    }

    /// Parses `4 days (update frequency)` or `12 hours`.
    static func parseInterval(_ text: Substring) -> TimeInterval? {
        let words = text.split(separator: " ")
        guard words.count >= 2, let amount = Double(words[0]), amount > 0 else { return nil }
        let unit = words[1].lowercased()
        if unit.hasPrefix("day") { return amount * 24 * 60 * 60 }
        if unit.hasPrefix("hour") { return amount * 60 * 60 }
        return nil
    }

    /// Parses EasyList's `09 Nov 2026 10:34 UTC`, uBlock Origin's `Mon, 09 Nov 2026 01:13:15 +0000`
    /// and malware-filter's `2026-11-09T12:09:01Z`.
    static func parseDate(_ text: Substring) -> Date? {
        if let date = try? Date(String(text), strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["dd MMM yyyy HH:mm 'UTC'", "EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss 'UTC'"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: String(text)) { return date }
        }
        return nil
    }
}
