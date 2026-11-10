import CryptoKit
import Foundation
import os
import WebKit

/// Blocks ads and trackers in web views, and keeps the filter lists behind it fresh.
///
/// All filter lists are converted together into WebKit content rule lists (as many as
/// WebKit's size limit requires) and an index of uBlock Origin scriptlets. The result is
/// cached under a fingerprint of the lists' contents, so a launch with unchanged lists
/// only looks it up.
///
/// `updateIfDue()` downloads lists that have expired, checks them, rebuilds and swaps the
/// result into every attached web view. If anything goes wrong, the current rules stay
/// in place and the update is retried later.
final class ContentBlocker {
    typealias Fetch = @Sendable (URL) async throws -> Data

    nonisolated struct Locations: Sendable {
        /// Folder with the filter lists and scriptlets shipped in the app.
        var bundled: URL
        /// Folder for downloaded lists and what they compiled into.
        var storage: URL

        static var standard: Locations {
            Locations(
                bundled: Bundle.main.resourceURL!,
                storage: URL.applicationSupportDirectory.appending(path: "ContentBlocking", directoryHint: .isDirectory)
            )
        }

        func bundledURL(for list: FilterList) -> URL {
            bundled.appending(path: list.resourceName + ".txt")
        }

        func downloadURL(for list: FilterList) -> URL {
            storage.appending(path: "FilterLists/\(list.resourceName).txt")
        }

        var scriptletLibraryURL: URL {
            bundled.appending(path: "ubo-scriptlets.json")
        }

        func engineURL(fingerprint: String) -> URL {
            storage.appending(path: "engine-\(fingerprint).json")
        }
    }

    struct Status {
        var origin: FilterListOrigin
        var metadata: FilterListMetadata
        var lastUpdateCheck: Date?
    }

    /// How long to wait before retrying a failed update.
    static let retryInterval: TimeInterval = 60 * 60

    private nonisolated static let logger = Logger(subsystem: "ch.archiluc.yab", category: "ContentBlocker")

    private let filterLists: [FilterList]
    private let store: WKContentRuleListStore
    private let defaults: UserDefaults
    private let locations: Locations
    private let fetch: Fetch
    private let now: () -> Date

    private var preparation: Task<Void, Never>?
    private var runningUpdate: Task<Void, Never>?
    private var scriptletLibrary: ScriptletLibrary?
    /// Per filter list identifier.
    private var sources: [String: FilterListSource.Info] = [:]
    private var engine: Engine?
    private var scriptletCache: [String: [WKUserScript]] = [:]
    private let attachedControllers = NSHashTable<WKUserContentController>.weakObjects()
    /// Attached controllers whose tab shows a site with blocking switched off.
    private let pausedControllers = NSHashTable<WKUserContentController>.weakObjects()

    /// What the filter lists compiled into.
    private struct Engine {
        var ruleLists: [WKContentRuleList]
        var scriptlets: ScriptletIndex
        var redirectSkipper: RedirectSkipper
        var fingerprint: String
    }

    /// Saved next to the compiled rule lists, to find them, the scriptlets and the
    /// redirect skips again.
    nonisolated private struct Manifest: Codable {
        var ruleListCount: Int
        var scriptlets: ScriptletIndex
        var redirectSkips: RedirectSkipIndex
    }

    init(
        filterLists: [FilterList] = FilterList.bundled,
        store: WKContentRuleListStore = .default(),
        defaults: UserDefaults = .standard,
        locations: Locations = .standard,
        fetch: @escaping Fetch = ContentBlocker.download,
        now: @escaping () -> Date = { Date() }
    ) {
        self.filterLists = filterLists
        self.store = store
        self.defaults = defaults
        self.locations = locations
        self.fetch = fetch
        self.now = now
    }

    // MARK: - Using it

    /// Adds the rule lists to `controller`, and swaps in new ones whenever lists update.
    func attach(to controller: WKUserContentController) async {
        await prepare()
        attachedControllers.add(controller)
        for ruleList in engine?.ruleLists ?? [] {
            controller.add(ruleList)
        }
    }

    /// Turns content blocking on or off for an attached controller, for sites where the
    /// owner switched it off. Takes effect with the next page load.
    func setBlocking(_ enabled: Bool, in controller: WKUserContentController) {
        guard attachedControllers.contains(controller) else { return }
        let isPaused = pausedControllers.contains(controller)
        if enabled, isPaused {
            pausedControllers.remove(controller)
            for ruleList in engine?.ruleLists ?? [] { controller.add(ruleList) }
        } else if !enabled, !isPaused {
            pausedControllers.add(controller)
            for ruleList in engine?.ruleLists ?? [] { controller.remove(ruleList) }
        }
    }

    /// The scriptlets for pages on `hostname`, as user scripts.
    ///
    /// Install them when deciding on a main-frame navigation: scriptlets have to be in
    /// place before the new page's own scripts run. Frames from other sites get none.
    func scriptlets(forHostname hostname: String) -> [WKUserScript] {
        let hostname = hostname.lowercased()
        if let cached = scriptletCache[hostname] { return cached }
        guard let scriptletLibrary, let engine else { return [] }

        let calls = engine.scriptlets.calls(forHostname: hostname)
        var scripts: [WKUserScript] = []
        if let code = scriptletLibrary.script(for: calls, world: .main, hostname: hostname) {
            scripts.append(WKUserScript(source: code, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        }
        if let code = scriptletLibrary.script(for: calls, world: .isolated, hostname: hostname) {
            scripts.append(WKUserScript(source: code, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        }

        if scriptletCache.count >= 64 { scriptletCache.removeAll() }
        scriptletCache[hostname] = scripts
        return scripts
    }

    /// Where a tracking link really goes, according to uBlock Origin's `$urlskip` filters.
    func redirectDestination(of url: URL) -> URL? {
        engine?.redirectSkipper.destination(of: url)
    }

    func ruleLists() async -> [WKContentRuleList] {
        await prepare()
        return engine?.ruleLists ?? []
    }

    /// Identifiers of the compiled rule lists in use.
    var ruleListIdentifiers: [String] {
        engine?.ruleLists.map(\.identifier) ?? []
    }

    func status(of list: FilterList) -> Status? {
        guard let source = sources[list.identifier] else { return nil }
        return Status(origin: source.origin, metadata: source.metadata, lastUpdateCheck: updateState(of: list).lastAttempt)
    }

    // MARK: - Preparing

    private func prepare() async {
        if let preparation {
            return await preparation.value
        }
        let preparation = Task {
            scriptletLibrary = await Self.loadScriptletLibrary(at: locations.scriptletLibraryURL)
            var sources: [String: FilterListSource] = [:]
            for list in filterLists {
                do {
                    sources[list.identifier] = try await Self.newestLocalSource(of: list, in: locations)
                } catch {
                    Self.logger.error("Could not read \(list.identifier, privacy: .public): \(error, privacy: .public)")
                }
            }
            do {
                install(try await engine(for: sources))
                self.sources = sources.mapValues(\.info)
                await removeOutdatedEngines()
            } catch {
                Self.logger.error("Could not prepare content blocking: \(error, privacy: .public)")
            }
        }
        self.preparation = preparation
        await preparation.value
    }

    /// Swaps a new engine into every attached web view.
    private func install(_ new: Engine) {
        let previous = engine?.ruleLists ?? []
        for controller in attachedControllers.allObjects where !pausedControllers.contains(controller) {
            for ruleList in previous { controller.remove(ruleList) }
            for ruleList in new.ruleLists { controller.add(ruleList) }
        }
        engine = new
        scriptletCache.removeAll()
    }

    // MARK: - Updating

    /// Downloads and installs lists that have expired. Cheap to call when nothing is due.
    ///
    /// WebKit parses new rules on the main thread, which can stall scrolling for a moment,
    /// so call this when the app is not in front of the user.
    func updateIfDue() async {
        if let runningUpdate {
            return await runningUpdate.value
        }
        let update = Task {
            await prepare()
            let dueLists = filterLists.filter(isDue)
            Self.logger.notice("Filter lists due for an update: \(dueLists.isEmpty ? "none" : dueLists.map(\.identifier).joined(separator: ", "), privacy: .public)")
            if !dueLists.isEmpty {
                await update(dueLists)
            }
        }
        runningUpdate = update
        await withTaskCancellationHandler {
            await update.value
        } onCancel: {
            update.cancel()
        }
        runningUpdate = nil
    }

    private func isDue(_ list: FilterList) -> Bool {
        guard let current = sources[list.identifier] else { return false }
        let state = updateState(of: list)
        let interval = state.failed ? Self.retryInterval : current.metadata.updateInterval
        let listDate = min(current.metadata.lastModified ?? .distantPast, now())
        let lastCheck = max(state.lastAttempt ?? .distantPast, listDate)
        return now() >= lastCheck.addingTimeInterval(interval)
    }

    private func update(_ dueLists: [FilterList]) async {
        // Download everything first, so all new lists go into one rebuild.
        var downloads: [FilterList: FilterListSource] = [:]
        for list in dueLists {
            if Task.isCancelled { return }
            guard let current = sources[list.identifier] else { continue }
            do {
                let candidate = try await downloadSource(of: list)
                let isNewer = candidate.metadata.isNewer(than: current.metadata) ?? (candidate.digest != current.digest)
                guard isNewer else {
                    recordUpdateAttempt(of: list, failed: false)
                    Self.logger.info("\(list.identifier, privacy: .public) is up to date")
                    continue
                }
                // A list that suddenly loses half its filters is more likely broken than improved.
                guard candidate.metadata.filterCount * 2 >= current.metadata.filterCount else {
                    throw ContentBlockerError.suspiciousList(list.identifier)
                }
                downloads[list] = candidate
            } catch {
                recordUpdateAttempt(of: list, failed: true)
                Self.logger.error("Could not update \(list.identifier, privacy: .public): \(error, privacy: .public)")
            }
        }
        guard !downloads.isEmpty else { return }

        do {
            var sources: [String: FilterListSource] = [:]
            for list in filterLists {
                if let downloaded = downloads[list] {
                    sources[list.identifier] = downloaded
                } else {
                    sources[list.identifier] = try? await Self.newestLocalSource(of: list, in: locations)
                }
            }
            try Task.checkCancellation()
            let engine = try await engine(for: sources)
            for (list, source) in downloads {
                try await Self.save(source.data, to: locations.downloadURL(for: list))
            }
            install(engine)
            self.sources = sources.mapValues(\.info)
            for (list, source) in downloads {
                recordUpdateAttempt(of: list, failed: false)
                Self.logger.notice("Updated \(list.identifier, privacy: .public) to \(source.metadata.version ?? source.metadata.lastModified?.description ?? "?", privacy: .public)")
            }
            await removeOutdatedEngines()
        } catch {
            for list in downloads.keys {
                recordUpdateAttempt(of: list, failed: true)
            }
            Self.logger.error("Could not install updated filter lists: \(error, privacy: .public)")
        }
    }

    private func downloadSource(of list: FilterList) async throws -> FilterListSource {
        var lastError: any Error = ContentBlockerError.noUpdateURL(list.identifier)
        for url in list.updateURLs {
            do {
                let data = try await fetch(url)
                return try await Self.makeSource(from: data, format: list.format)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                Self.logger.info("Download from \(url, privacy: .public) failed: \(error, privacy: .public)")
                lastError = error
            }
        }
        throw lastError
    }

    private func updateState(of list: FilterList) -> (lastAttempt: Date?, failed: Bool) {
        (
            defaults.object(forKey: "ContentBlocker.\(list.identifier).lastUpdateAttempt") as? Date,
            defaults.bool(forKey: "ContentBlocker.\(list.identifier).lastUpdateFailed")
        )
    }

    private func recordUpdateAttempt(of list: FilterList, failed: Bool) {
        defaults.set(now(), forKey: "ContentBlocker.\(list.identifier).lastUpdateAttempt")
        defaults.set(failed, forKey: "ContentBlocker.\(list.identifier).lastUpdateFailed")
    }

    // MARK: - Building

    /// Looks up the engine for these sources, or builds it.
    private func engine(for sources: [String: FilterListSource]) async throws -> Engine {
        let fingerprint = fingerprint(of: sources)
        if let cached = await cachedEngine(fingerprint: fingerprint) {
            return cached
        }

        let start = ContinuousClock.now
        let inputs = filterLists.compactMap { list in
            sources[list.identifier].map { FilterListConverter.Input(text: $0.text, isTrusted: list.isTrusted) }
        }
        let converted = try await Self.convert(inputs, scriptletLibrary: scriptletLibrary)
        let convertedAt = ContinuousClock.now

        var ruleLists: [WKContentRuleList] = []
        for (index, json) in converted.ruleLists.enumerated() {
            let identifier = "yab@\(fingerprint)-\(index + 1)of\(converted.ruleLists.count)"
            let compiled: WKContentRuleList? = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
            guard let compiled else { throw ContentBlockerError.compilationFailed(identifier) }
            ruleLists.append(compiled)
        }
        let manifest = Manifest(ruleListCount: ruleLists.count, scriptlets: converted.scriptlets, redirectSkips: converted.redirectSkips)
        try await Self.save(manifest, to: locations.engineURL(fingerprint: fingerprint))

        Self.logger.notice("""
            Built content blocking \(fingerprint, privacy: .public): \(converted.report.description, privacy: .public). \
            \(ruleLists.count) rule lists. Converted in \(start.duration(to: convertedAt), privacy: .public), \
            compiled in \(convertedAt.duration(to: .now), privacy: .public)
            """)
        return Engine(ruleLists: ruleLists, scriptlets: converted.scriptlets, redirectSkipper: RedirectSkipper(converted.redirectSkips), fingerprint: fingerprint)
    }

    /// Changes whenever a list, the converter or the scriptlets change.
    private func fingerprint(of sources: [String: FilterListSource]) -> String {
        var description = "converter \(FilterListConverter.version)\nscriptlets \(scriptletLibrary?.source ?? "none")\n"
        for list in filterLists {
            guard let source = sources[list.identifier] else { continue }
            description += "\(list.identifier) \(list.isTrusted) \(source.digest)\n"
        }
        return SHA256.hash(data: Data(description.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func cachedEngine(fingerprint: String) async -> Engine? {
        guard let manifest = await Self.loadManifest(at: locations.engineURL(fingerprint: fingerprint)) else { return nil }
        var ruleLists: [WKContentRuleList] = []
        for index in 0..<manifest.ruleListCount {
            let identifier = "yab@\(fingerprint)-\(index + 1)of\(manifest.ruleListCount)"
            guard let ruleList = try? await store.contentRuleList(forIdentifier: identifier) else { return nil }
            ruleLists.append(ruleList)
        }
        return Engine(ruleLists: ruleLists, scriptlets: manifest.scriptlets, redirectSkipper: RedirectSkipper(manifest.redirectSkips), fingerprint: fingerprint)
    }

    /// Deletes compiled rule lists and manifests other than the ones in use.
    private func removeOutdatedEngines() async {
        guard let engine else { return }
        let inUse = Set(engine.ruleLists.map(\.identifier))
        let identifiers: [String]? = await store.availableIdentifiers()
        for identifier in identifiers ?? [] where !inUse.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
        await Self.removeFiles(in: locations.storage, prefix: "engine-", except: locations.engineURL(fingerprint: engine.fingerprint))
    }

    // MARK: - Background work

    @concurrent
    private nonisolated static func convert(
        _ inputs: [FilterListConverter.Input],
        scriptletLibrary: ScriptletLibrary?
    ) async throws -> (ruleLists: [String], scriptlets: ScriptletIndex, redirectSkips: RedirectSkipIndex, report: FilterListConverter.Report) {
        let output = FilterListConverter(scriptletLibrary: scriptletLibrary).convert(inputs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let ruleLists = try output.ruleLists().map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        return (ruleLists, output.scriptlets, output.redirectSkips, output.report)
    }

    /// Encodes rules for a single filter list, for tests and tools.
    @concurrent
    nonisolated static func encodeRules(from text: String) async throws -> (json: String, report: FilterListConverter.Report) {
        let output = FilterListConverter().convert(text)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let json = String(decoding: try encoder.encode(output.rules), as: UTF8.self)
        return (json, output.report)
    }

    @concurrent
    private nonisolated static func loadScriptletLibrary(at url: URL) async -> ScriptletLibrary? {
        do {
            return try ScriptletLibrary(contentsOf: url)
        } catch {
            logger.error("No scriptlets: \(error, privacy: .public)")
            return nil
        }
    }

    @concurrent
    private nonisolated static func loadManifest(at url: URL) async -> Manifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    @concurrent
    private nonisolated static func save(_ manifest: Manifest, to url: URL) async throws {
        try await save(JSONEncoder().encode(manifest), to: url)
    }

    @concurrent
    private nonisolated static func removeFiles(in directory: URL, prefix: String, except kept: URL) async {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) && file.lastPathComponent != kept.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Picks the downloaded copy of a list if it is newer than the one in the app.
    @concurrent
    private nonisolated static func newestLocalSource(of list: FilterList, in locations: Locations) async throws -> FilterListSource {
        guard let bundledData = try? Data(contentsOf: locations.bundledURL(for: list)) else {
            throw ContentBlockerError.missingFilterList(list.identifier)
        }
        let bundled = try FilterListSource(data: bundledData, origin: .bundled, format: list.format)

        guard let downloadedData = try? Data(contentsOf: locations.downloadURL(for: list)),
              let downloaded = try? FilterListSource(data: downloadedData, origin: .downloaded, format: list.format) else {
            return bundled
        }
        let isNewer = downloaded.metadata.isNewer(than: bundled.metadata) ?? (downloaded.digest != bundled.digest)
        return isNewer ? downloaded : bundled
    }

    @concurrent
    private nonisolated static func makeSource(from data: Data, format: FilterList.Format) async throws -> FilterListSource {
        try FilterListSource(data: data, origin: .downloaded, format: format)
    }

    @concurrent
    private nonisolated static func save(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // Everything here can be downloaded or rebuilt again, so keep it out of backups.
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Downloads without cookies, caches or Low Data Mode traffic.
    nonisolated static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ContentBlockerError.badResponse(url)
        }
        return data
    }

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()
}

nonisolated enum ContentBlockerError: Error {
    case missingFilterList(String)
    case notAFilterList
    case badResponse(URL)
    case noUpdateURL(String)
    case suspiciousList(String)
    case compilationFailed(String)
}

nonisolated enum FilterListOrigin: Sendable, Equatable {
    case bundled
    case downloaded
}

/// A filter list's raw contents, checked and ready to convert.
nonisolated struct FilterListSource: Sendable {
    /// What is kept about a list once it has been converted.
    struct Info: Sendable {
        var origin: FilterListOrigin
        var metadata: FilterListMetadata
        var digest: String
    }

    var data: Data
    var text: String
    var origin: FilterListOrigin
    var metadata: FilterListMetadata
    /// SHA-256 of `data`, as hex.
    var digest: String

    var info: Info {
        Info(origin: origin, metadata: metadata, digest: digest)
    }

    /// Turns a list of sites into filters blocking navigation to them: `example.com`
    /// becomes `||example.com^$document`, and `#` comments become `!` comments.
    static func filters(blockingSitesIn text: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingWhitespace()
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                lines.append("!" + line.dropFirst())
                continue
            }
            // Host names and IPv4 addresses only. Anything else is dropped, so a web page
            // downloaded by mistake ends up without the `!` header and is rejected.
            let host = line.lowercased()
            let isHost = host.contains(".") && host.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2E || byte == 0x2D || byte == 0x5F
            }
            if isHost {
                lines.append("||\(host)^$document")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Throws if `data` does not look like a filter list.
    init(data: Data, origin: FilterListOrigin, format: FilterList.Format = .filters) throws {
        guard !data.isEmpty, data.count <= 50_000_000, let raw = String(data: data, encoding: .utf8) else {
            throw ContentBlockerError.notAFilterList
        }
        let text = format == .blockedSites ? Self.filters(blockingSitesIn: raw) : raw
        let metadata = FilterListMetadata.parse(text)
        guard metadata.looksLikeFilterList, metadata.filterCount > 0 else {
            throw ContentBlockerError.notAFilterList
        }
        self.data = data
        self.text = text
        self.origin = origin
        self.metadata = metadata
        self.digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
