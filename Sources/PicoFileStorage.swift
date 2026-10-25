import Foundation
import Darwin

// Darwin also imports a `flock` struct; bind the BSD locking function explicitly.
@_silgen_name("flock") private func picoFilesFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// User-facing files share one root. Agent state, credentials and recordings
/// used only for recognition remain in Application Support or temporary storage.
enum PicoFileStorage {
    private static let manager = FileManager.default
    private static var defaultDataDirectory: URL {
        manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos")
    }
    private static var currentDataDirectory: URL {
        ProcessInfo.processInfo.environment["TELOS_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? defaultDataDirectory
    }

    static func directory(dataDirectory: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment["PICO_FILES_DIR"], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        }
        if dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path != defaultDataDirectory.standardizedFileURL.resolvingSymlinksInPath().path {
            return dataDirectory.appendingPathComponent("PicoFiles", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        }
        return manager.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Pico", isDirectory: true).resolvingSymlinksInPath()
    }

    static func displayPath(_ url: URL) -> String {
        let home = manager.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }

    static func workspaceURL(dataDirectory: URL, id: UUID, chat: Bool = false) -> URL {
        directory(dataDirectory: dataDirectory)
            .appendingPathComponent(chat ? "Chats" : "Tasks", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Move complete workspaces, including web assets and relative attachments.
    /// The old path remains an alias so saved messages need no destructive rewrite.
    @discardableResult static func prepare(dataDirectory: URL) throws -> URL {
        try locked(dataDirectory) {
            let root = directory(dataDirectory: dataDirectory)
            try validateRoot(root)
            try ensureDirectory(root)
            for chat in [false, true] {
                let parent = dataDirectory.appendingPathComponent(chat ? "chats" : "tasks", isDirectory: true)
                guard exists(parent) else { continue }
                try requireDirectory(parent)
                for entry in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                    guard let id = UUID(uuidString: entry.lastPathComponent), exists(entry.appendingPathComponent("files")) else { continue }
                    try requireDirectory(entry)
                    _ = try workspaceLocked(dataDirectory: dataDirectory, id: id, chat: chat)
                }
            }
            return root
        }
    }

    static func workspace(dataDirectory: URL, id: UUID, chat: Bool = false) throws -> URL {
        try locked(dataDirectory) { try workspaceLocked(dataDirectory: dataDirectory, id: id, chat: chat) }
    }

    static func exportDirectory(_ name: String, dataDirectory: URL? = nil) throws -> URL {
        guard ["Screenshots", "Recordings"].contains(name) else { throw failure("Unknown file category.") }
        let data = dataDirectory ?? currentDataDirectory
        return try locked(data) {
            let root = directory(dataDirectory: data)
            try validateRoot(root)
            try ensureDirectory(root)
            let result = root.appendingPathComponent(name, isDirectory: true)
            try ensureDirectory(result)
            return result
        }
    }

    private static func workspaceLocked(dataDirectory: URL, id: UUID, chat: Bool) throws -> URL {
        let root = directory(dataDirectory: dataDirectory)
        try validateRoot(root)
        try ensureDirectory(root)
        let category = root.appendingPathComponent(chat ? "Chats" : "Tasks", isDirectory: true)
        try ensureDirectory(category)
        let destination = workspaceURL(dataDirectory: dataDirectory, id: id, chat: chat)
        let parent = dataDirectory.appendingPathComponent(chat ? "chats" : "tasks", isDirectory: true)
        try ensureDirectory(parent)
        let legacyParent = parent.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try ensureDirectory(legacyParent)
        let legacy = legacyParent.appendingPathComponent("files", isDirectory: true)

        if isSymbolicLink(legacy) {
            guard legacy.resolvingSymlinksInPath().standardizedFileURL.path == destination.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw failure("An existing workspace points outside the Pico files folder. Its files were left unchanged.")
            }
            try ensureDirectory(destination)
            return destination
        }
        var moved = false, removedEmpty = false, removedDestination = false
        if exists(legacy) {
            try requireDirectory(legacy)
            if exists(destination) {
                try requireDirectory(destination)
                let oldEmpty = try manager.contentsOfDirectory(atPath: legacy.path).isEmpty
                let newEmpty = try manager.contentsOfDirectory(atPath: destination.path).isEmpty
                guard oldEmpty || newEmpty else {
                    throw failure("Two copies of a workspace contain files. Pico kept both folders unchanged to avoid replacing files.")
                }
                if oldEmpty {
                    try manager.removeItem(at: legacy)
                    removedEmpty = true
                } else {
                    try manager.removeItem(at: destination)
                    removedDestination = true
                    do { try renameDirectory(legacy, to: destination); moved = true }
                    catch { try? ensureDirectory(destination); throw error }
                }
            } else {
                try renameDirectory(legacy, to: destination)
                moved = true
            }
            do {
                try manager.createSymbolicLink(atPath: legacy.path, withDestinationPath: destination.path)
            } catch {
                // A failed alias must not strand previously accessible files.
                if moved && !exists(legacy) {
                    try? renameDirectory(destination, to: legacy)
                    if removedDestination { try? ensureDirectory(destination) }
                } else if removedEmpty && !exists(legacy) { try? ensureDirectory(legacy) }
                throw error
            }
        } else {
            try ensureDirectory(destination)
            try manager.createSymbolicLink(atPath: legacy.path, withDestinationPath: destination.path)
        }
        return destination
    }

    private static func locked<T>(_ data: URL, _ action: () throws -> T) throws -> T {
        let normalized = data.standardizedFileURL.resolvingSymlinksInPath()
        try ensureDirectory(normalized)
        let lockURL = normalized.appendingPathComponent("generated-files.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixFailure("Could not open the files-folder lock.") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid() else {
            throw failure("The files-folder lock has an unexpected owner or type.")
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw posixFailure("Could not protect the files-folder lock.") }
        guard picoFilesFlock(descriptor, LOCK_EX) == 0 else { throw posixFailure("Could not prepare the files folder.") }
        defer { _ = picoFilesFlock(descriptor, LOCK_UN) }
        return try action()
    }

    private static func exists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }
    private static func validateRoot(_ root: URL) throws {
        guard root.path != "/", root.path != manager.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path else {
            throw failure("Pico files need their own folder, not the home folder or a disk root.")
        }
    }
    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeSymbolicLink
    }
    private static func ensureDirectory(_ url: URL) throws {
        if exists(url) { try requireDirectory(url) }
        else { try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    private static func requireDirectory(_ url: URL) throws {
        guard !isSymbolicLink(url), (try manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw failure("The files-folder location is not a regular folder. Existing files were left unchanged.")
        }
    }
    private static func renameDirectory(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            if errno == EXDEV { throw failure("The files folder is on another disk. Existing files were kept in place; Pico could not move them automatically.") }
            throw posixFailure("Could not move existing Pico files.")
        }
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PicoFileStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func posixFailure(_ message: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: message + " " + String(cString: strerror(code))])
    }
}
