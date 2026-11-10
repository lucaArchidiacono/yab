import Foundation
import os
import UIKit

/// Normal tabs on disk, so none is ever lost, even when iOS ends the app.
///
/// - `tabs.json`: the tabs in order, with their page, title and when they were last used.
/// - `<id>.history`: a tab's back/forward history with scroll positions.
/// - `<id>.jpg`: how the tab looked when it was last seen.
///
/// Each tab has its own files, so a change to one tab never rewrites the others.
/// Hacker tabs are never stored.
final class TabStore {
    nonisolated struct Index: Codable, Equatable, Sendable {
        var tabs: [Entry]
        var selectedTabID: UUID?
    }

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var id: UUID
        var url: URL?
        var title: String?
        var lastActive: Date
    }

    /// Pictures are kept for this many of the most recently used tabs. History is
    /// kept for all of them.
    static let snapshotLimit = 100

    private static let logger = Logger(subsystem: "ch.archiluc.yab", category: "TabStore")

    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Tabs", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    // MARK: - Index

    func loadIndex() -> Index? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode(Index.self, from: data)
    }

    func save(_ index: Index) {
        write(try? JSONEncoder().encode(index), to: indexURL)
    }

    // MARK: - History

    func history(for tab: UUID) -> Data? {
        try? Data(contentsOf: historyURL(for: tab))
    }

    func saveHistory(_ history: Data, for tab: UUID) {
        write(history, to: historyURL(for: tab))
    }

    // MARK: - Snapshots

    func snapshot(for tab: UUID) -> UIImage? {
        UIImage(contentsOfFile: snapshotURL(for: tab).path)
    }

    func hasSnapshot(for tab: UUID) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(for: tab).path)
    }

    /// Scales the picture to twice the point size and compresses it, away from the main thread.
    func saveSnapshot(_ image: UIImage, for tab: UUID) async {
        guard let data = await Self.compressed(image) else { return }
        write(data, to: snapshotURL(for: tab))
    }

    /// Deletes the pictures of tabs that are not among `kept`.
    func removeSnapshots(except kept: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jpg" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Closing

    func removeTab(_ tab: UUID) {
        try? FileManager.default.removeItem(at: historyURL(for: tab))
        try? FileManager.default.removeItem(at: snapshotURL(for: tab))
    }

    // MARK: - Files

    private var indexURL: URL { directory.appending(path: "tabs.json") }

    private func historyURL(for tab: UUID) -> URL {
        directory.appending(path: "\(tab.uuidString).history")
    }

    private func snapshotURL(for tab: UUID) -> URL {
        directory.appending(path: "\(tab.uuidString).jpg")
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Could not save \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
    }

    @concurrent
    private nonisolated static func compressed(_ image: UIImage) async -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(image.scale, 2)
        let scaled = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
        return scaled.jpegData(compressionQuality: 0.6)
    }
}
