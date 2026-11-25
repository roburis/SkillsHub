import Foundation

nonisolated struct StartupAccessBookmarkResolution: Equatable {
    var url: URL
    var isStale: Bool
}

typealias StartupAccessBatch = [String: Result<StartupAccessBookmarkResolution?, any Error>]

protocol StartupAccessStoring: AnyObject {
    func resolveAccess(to url: URL) throws -> StartupAccessBookmarkResolution?
    func saveAccess(to url: URL) throws
    func resolveAccessBatch(to urls: [URL]) async throws -> StartupAccessBatch
}

extension StartupAccessStoring {
    func resolveAccessBatch(to urls: [URL]) async throws -> StartupAccessBatch {
        try resolveAccessIndependently(urls, using: resolveAccess)
    }
}

nonisolated private func resolveAccessIndependently(
    _ urls: [URL], using resolve: (URL) throws -> StartupAccessBookmarkResolution?
) throws -> StartupAccessBatch {
    var result: StartupAccessBatch = [:]
    for url in urls.map(\.standardizedFileURL) where result[url.path] == nil {
        try Task.checkCancellation()
        do { result[url.path] = .success(try resolve(url)) }
        catch is CancellationError { throw CancellationError() }
        catch { result[url.path] = .failure(error) }
    }
    return result
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

    func resolveAccessBatch(to urls: [URL]) async throws -> StartupAccessBatch {
        try await Self.resolveAccessBatch(to: urls, storeURL: storeURL)
    }

    @concurrent nonisolated private static func resolveAccessBatch(
        to urls: [URL], storeURL: URL
    ) async throws -> StartupAccessBatch {
        let bookmarks = try loadBookmarks(at: storeURL)
        return try resolveAccessIndependently(urls) { try resolve($0, bookmarks: bookmarks) }
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
        guard resolvedURL.standardizedFileURL.path == path else { return nil }
        return StartupAccessBookmarkResolution(url: resolvedURL, isStale: isStale)
    }

    func saveAccess(to url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        let path = normalizedURL.path
        let bookmarkData = try url.bookmarkData(
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
        try Self.loadBookmarks(at: storeURL)
    }

    nonisolated private static func loadBookmarks(at storeURL: URL) throws -> [String: StoredBookmark] {
        let data: Data
        do { data = try Data(contentsOf: storeURL) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) { return [:] }
        var bookmarks: [String: StoredBookmark] = [:]
        for bookmark in try JSONDecoder().decode([StoredBookmark].self, from: data) {
            guard bookmarks.updateValue(bookmark, forKey: bookmark.path) == nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return bookmarks
    }
}
