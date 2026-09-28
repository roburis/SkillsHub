import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: create-interprocess-bookmark <directory>\n".utf8))
    exit(2)
}

let directory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
).standardizedFileURL
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
    FileHandle.standardError.write(Data("bookmark target must be an existing directory\n".utf8))
    exit(2)
}

do {
    let bookmark = try directory.bookmarkData(
        options: [],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
    FileHandle.standardOutput.write(Data(bookmark.base64EncodedString().utf8))
} catch {
    FileHandle.standardError.write(Data("unable to create interprocess bookmark: \(error)\n".utf8))
    exit(1)
}
