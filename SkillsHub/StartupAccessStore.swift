import Foundation

nonisolated struct StartupAccessBookmarkResolution: Equatable {
    var url: URL
    var isStale: Bool
}

protocol StartupAccessStoring: AnyObject {
    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution?
    func saveAccess(to url: URL) throws
}

final class SecurityScopedStartupAccessStore: StartupAccessStoring {
    private struct StoredBookmark: Codable, Hashable {
        var path: String
        var bookmarkData: Data
    }

    private let fileManager: FileManager
    private let storeURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(appSupportURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storeURL = appSupportURL.appendingPathComponent("startup-access-bookmarks.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        guard let bookmark = try loadBookmarks()[path] else {
            return nil
        }
        var isStale = false
        let resolvedURL = try URL(
            resolvingBookmarkData: bookmark.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        let resolved = resolvedURL.standardizedFileURL
        guard resolved.path == path else {
            return nil
        }
        return StartupAccessBookmarkResolution(url: resolved, isStale: isStale)
    }

    func saveAccess(to url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        let bookmarkData = try normalizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var bookmarks = try loadBookmarks()
        bookmarks[path] = StoredBookmark(path: path, bookmarkData: bookmarkData)
        try fileManager.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(Array(bookmarks.values).sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending })
        try data.write(to: storeURL, options: [.atomic])
    }

    private func loadBookmarks() throws -> [String: StoredBookmark] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: storeURL)
        let bookmarks = try decoder.decode([StoredBookmark].self, from: data)
        return Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.path, $0) })
    }
}
