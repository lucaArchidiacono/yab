import Foundation

/// Which scriptlets run on which sites, built from `##+js(...)` filters.
nonisolated struct ScriptletIndex: Codable, Sendable, Equatable {
    /// Distinct calls: a scriptlet name followed by its arguments. Index 0 is the
    /// empty call, which `#@#+js()` uses to turn off all scriptlets.
    private(set) var calls: [[String]] = [[]]
    /// Hostnames and entities (`google.*`) → indices into `calls`.
    /// A negative value `~i` excludes call `i` instead.
    private(set) var entries: [String: [Int]] = [:]
    /// Calls turned off everywhere by `#@#+js(...)` without hostnames.
    private(set) var globalExceptions: [Int] = []

    var filterCount: Int { entries.values.reduce(0) { $0 + $1.count } + globalExceptions.count }

    /// The calls to run in a frame with this hostname, following uBlock Origin's rules:
    /// filters for parent domains and entities apply, and exceptions win.
    func calls(forHostname hostname: String) -> [[String]] {
        var included = Set<Int>()
        var excluded = Set(globalExceptions)
        for key in Self.lookupKeys(forHostname: hostname) {
            for reference in entries[key] ?? [] {
                if reference >= 0 {
                    included.insert(reference)
                } else {
                    excluded.insert(~reference)
                }
            }
        }
        if excluded.contains(0) { return [] }
        return included.subtracting(excluded).sorted().map { calls[$0] }
    }

    /// `www.example.co.uk` → itself, its parent domains, and entities like `example.co.*`,
    /// `example.*` and `www.example.*`. Mirrors uBlock Origin's scriptlet template.
    static func lookupKeys(forHostname hostname: String) -> [String] {
        var hostnames = [Substring(hostname)]
        var rest = Substring(hostname)
        while let dot = rest.firstIndex(of: ".") {
            rest = rest[rest.index(after: dot)...]
            hostnames.append(rest)
        }
        var entities: [String] = []
        for var name in hostnames {
            while let dot = name.lastIndex(of: ".") {
                name = name[..<dot]
                entities.append(name + ".*")
            }
        }
        return hostnames.map(String.init) + entities
    }

    struct Builder {
        private var index = ScriptletIndex()
        private var callIndices: [[String]: Int] = [[]: 0]
        private var entries: [String: Set<Int>] = [:]
        private var globalExceptions: Set<Int> = []

        mutating func add(_ filter: ScriptletFilterParser.Filter) {
            let reference = callIndex(for: filter.call)
            if filter.isException {
                if filter.hostnames.isEmpty {
                    globalExceptions.insert(reference)
                }
                for hostname in filter.hostnames {
                    entries[hostname, default: []].insert(~reference)
                }
            } else {
                for hostname in filter.hostnames {
                    entries[hostname, default: []].insert(reference)
                }
                for hostname in filter.excludedHostnames {
                    entries[hostname, default: []].insert(~reference)
                }
            }
        }

        func build() -> ScriptletIndex {
            var index = index
            index.entries = entries.mapValues { $0.sorted() }
            index.globalExceptions = globalExceptions.sorted()
            return index
        }

        private mutating func callIndex(for call: [String]) -> Int {
            if let existing = callIndices[call] { return existing }
            let new = index.calls.count
            index.calls.append(call)
            callIndices[call] = new
            return new
        }
    }
}
