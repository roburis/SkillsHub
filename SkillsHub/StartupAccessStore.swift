import Foundation

nonisolated struct StartupAccessBookmarkResolution: Equatable {
    var url: URL
    var isStale: Bool
}

protocol StartupAccessStoring: AnyObject {
    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution?
    func saveAccess(to url: URL) throws
    func resolvePresentationAccess(to urls: [URL]) async throws -> [String: StartupAccessBookmarkResolution]
}

extension StartupAccessStoring {
    func resolvePresentationAccess(to urls: [URL]) async throws -> [String: StartupAccessBookmarkResolution] {
        var result: [String: StartupAccessBookmarkResolution] = [:]
        for url in urls {
            if let resolution = try resolveAccess(to: url) { result[url.standardizedFileURL.path] = resolution }
        }
        return result
    }
}

final class SecurityScopedStartupAccessStore: StartupAccessStoring {
    nonisolated private struct StoredBookmark: Codable, Hashable {
        var path: String
        var bookmarkData: Data
    }

    private let fileManager: FileManager
    private let storeURL: URL
    private let encoder: JSONEncoder

    init(appSupportURL: URL, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.storeURL = appSupportURL.appendingPathComponent("startup-access-bookmarks.json")
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution? {
        try Self.resolve(url, bookmarks: loadBookmarks())
    }

    func resolvePresentationAccess(to urls: [URL]) async throws -> [String: StartupAccessBookmarkResolution] {
        try await Self.resolvePresentationAccess(to: urls, storeURL: storeURL, fileManager: fileManager)
    }

    @concurrent nonisolated private static func resolvePresentationAccess(
        to urls: [URL], storeURL: URL, fileManager: FileManager
    ) async throws -> [String: StartupAccessBookmarkResolution] {
        let bookmarks = try loadBookmarks(at: storeURL, fileManager: fileManager)
        var result: [String: StartupAccessBookmarkResolution] = [:]
        for url in urls {
            try Task.checkCancellation()
            if let resolution = try resolve(url, bookmarks: bookmarks) { result[url.standardizedFileURL.path] = resolution }
        }
        return result
    }

    nonisolated private static func resolve(_ url: URL, bookmarks: [String: StoredBookmark]) throws -> StartupAccessBookmarkResolution? {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        guard let bookmark = bookmarks[path] else {
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
        try Self.loadBookmarks(at: storeURL, fileManager: fileManager)
    }

    nonisolated private static func loadBookmarks(at storeURL: URL, fileManager: FileManager) throws -> [String: StoredBookmark] {
        guard fileManager.fileExists(atPath: storeURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: storeURL)
        let bookmarks = try JSONDecoder().decode([StoredBookmark].self, from: data)
        return Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.path, $0) })
    }
}
