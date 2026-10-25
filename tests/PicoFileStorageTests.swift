import Foundation

@main struct PicoFileStorageTests {
    static func main() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "workspace" {
            print(try PicoFileStorage.workspace(dataDirectory: URL(fileURLWithPath: CommandLine.arguments[2]),
                                              id: UUID(uuidString: CommandLine.arguments[3])!, chat: CommandLine.arguments[4] == "chat").path)
            return
        }
        func check(_ condition: Bool, _ message: String = "") { precondition(condition, message) }
        let original = ProcessInfo.processInfo.environment["PICO_FILES_DIR"]
        unsetenv("PICO_FILES_DIR")
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent("pico-file-storage-" + UUID().uuidString)
        defer {
            try? fm.removeItem(at: fixture)
            if let original { setenv("PICO_FILES_DIR", original, 1) } else { unsetenv("PICO_FILES_DIR") }
        }
        let realDataPath = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos").path
        let expectedRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Pico").resolvingSymlinksInPath().path
        for isDirectory in [true, false] {
            precondition(PicoFileStorage.directory(dataDirectory: URL(fileURLWithPath: realDataPath, isDirectory: isDirectory)).path == expectedRoot,
                         "Directory URL hints cannot change the production output location")
        }
        let data = fixture.appendingPathComponent("data").resolvingSymlinksInPath()
        func text(_ value: String, at file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: file)
        }
        func read(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }
        func rejected(_ action: () throws -> Void) { do { try action(); preconditionFailure("Unsafe migration was accepted") } catch {} }
        func legacy(_ id: UUID, chat: Bool = false) -> URL {
            data.appendingPathComponent("\(chat ? "chats" : "tasks")/\(id.uuidString.lowercased())/files")
        }
        let id = UUID(), chat = UUID()
        let old = legacy(id), oldChat = legacy(chat, chat: true)
        try text("<img src='assets/图片.svg'>", at: old.appendingPathComponent("site/index.html"))
        try text("original image", at: old.appendingPathComponent("site/assets/图片.svg"))
        try text("chat deliverable", at: oldChat.appendingPathComponent("report.md"))
        try text("internal state", at: data.appendingPathComponent("tasks/\(id.uuidString.lowercased())/history.json"))
        let inode = try fm.attributesOfItem(atPath: old.path)[.systemFileNumber] as! NSNumber
        let root = try PicoFileStorage.prepare(dataDirectory: data)
        precondition(root.path == data.appendingPathComponent("PicoFiles").standardizedFileURL.path)
        let current = PicoFileStorage.workspaceURL(dataDirectory: data, id: id)
        precondition(current.path == root.appendingPathComponent("Tasks/\(id.uuidString.lowercased())").path)
        let target = try fm.destinationOfSymbolicLink(atPath: old.path)
        precondition(target == current.path)
        let movedInode = try fm.attributesOfItem(atPath: current.path)[.systemFileNumber] as! NSNumber
        precondition(inode == movedInode, "Migration must rename the directory, not copy its files")
        check(try read(current.appendingPathComponent("site/assets/图片.svg")) == "original image")
        check(try read(old.appendingPathComponent("site/assets/图片.svg")) == "original image", "Historical absolute file URLs must still work")
        check(try read(oldChat.appendingPathComponent("report.md")) == "chat deliverable")
        precondition(!fm.fileExists(atPath: current.appendingPathComponent("history.json").path), "Internal history must remain private")
        _ = try PicoFileStorage.prepare(dataDirectory: data)
        _ = try PicoFileStorage.workspace(dataDirectory: data, id: id)
        let lockMode = try fm.attributesOfItem(atPath: data.appendingPathComponent("generated-files.lock").path)[.posixPermissions] as! NSNumber
        precondition(lockMode.intValue == 0o600)
        let newID = UUID()
        let newWorkspace = try PicoFileStorage.workspace(dataDirectory: data, id: newID)
        check(try fm.destinationOfSymbolicLink(atPath: legacy(newID).path) == newWorkspace.path)

        let conflict = UUID(), conflictOld = legacy(conflict)
        let conflictNew = PicoFileStorage.workspaceURL(dataDirectory: data, id: conflict)
        try text("old bytes", at: conflictOld.appendingPathComponent("report.pdf"))
        try text("new bytes", at: conflictNew.appendingPathComponent("report.pdf"))
        rejected { _ = try PicoFileStorage.workspace(dataDirectory: data, id: conflict) }
        check(try read(conflictOld.appendingPathComponent("report.pdf")) == "old bytes")
        check(try read(conflictNew.appendingPathComponent("report.pdf")) == "new bytes")

        let unsafeID = UUID(), unsafe = legacy(unsafeID)
        let outside = fixture.appendingPathComponent("unrelated")
        try text("untouched", at: outside.appendingPathComponent("keep.txt"))
        try fm.createDirectory(at: unsafe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: unsafe, withDestinationURL: outside)
        rejected { _ = try PicoFileStorage.workspace(dataDirectory: data, id: unsafeID) }
        check(try read(outside.appendingPathComponent("keep.txt")) == "untouched")

        let override = fixture.appendingPathComponent("Chosen Outputs").resolvingSymlinksInPath()
        setenv("PICO_FILES_DIR", override.path, 1)
        let overridden = try PicoFileStorage.exportDirectory("Screenshots", dataDirectory: data)
        precondition(overridden.path == override.appendingPathComponent("Screenshots").path)
        rejected { _ = try PicoFileStorage.exportDirectory("../escape", dataDirectory: data) }
        let blocker = fixture.appendingPathComponent("blocked")
        try text("preserve", at: blocker)
        setenv("PICO_FILES_DIR", blocker.path, 1)
        rejected { _ = try PicoFileStorage.prepare(dataDirectory: data) }
        check(try read(blocker) == "preserve")
        setenv("PICO_FILES_DIR", fm.homeDirectoryForCurrentUser.path, 1)
        rejected { _ = try PicoFileStorage.prepare(dataDirectory: data) }
        print("PASS native storage migration, inode preservation, web resources, historical links, Chat/Task isolation, idempotence, conflicts, unknown aliases, export paths and failure preservation")
    }
}
