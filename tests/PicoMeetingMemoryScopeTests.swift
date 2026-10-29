import Foundation
import SQLite3

enum PicoMeetingMemoryScopeTests {
    @MainActor static func run() throws {
        let notes = [
            PicoMemoryNote(id: "zoom-slides", text: "工作 项目：Zoom Slides 页面分享。", updated: "2026-10-28"),
            PicoMemoryNote(id: "zoom-live", text: "工作 项目：Zoom Live Slides 实时演示。", updated: "2026-10-27"),
            PicoMemoryNote(id: "other-project", text: "兴趣 项目：原创音乐与字体排印。", updated: "2026-10-26"),
            PicoMemoryNote(id: "excluded", text: "工作 项目：Zoom 本地排除内容。", updated: "2026-10-25"),
            PicoMemoryNote(id: "restricted", text: "工作 项目：Zoom 私人密码不要分享。", updated: "2026-10-24")
        ]
        let excluded: Set<String> = ["excluded"]
        let chosen: Set<String> = ["zoom-slides", "zoom-live"]
        func ids(_ result: PicoMemoryResult) -> Set<String> { Set(result.notes.map(\.id)) }
        precondition(ids(PicoMemoryStore.search(query: "项目", notes: notes, excluded: excluded)) == ["zoom-slides", "zoom-live", "other-project"],
                     "nil meeting scope must retain the existing approved-memory policy")
        precondition(PicoMemoryStore.search(query: "项目", notes: notes, excluded: excluded, allowedNoteIDs: []).notes.isEmpty,
                     "an empty meeting allowlist disables long-term memory")
        precondition(ids(PicoMemoryStore.search(query: "项目", notes: notes, excluded: excluded, allowedNoteIDs: chosen)) == chosen)
        precondition(PicoMemoryStore.search(query: "原创 音乐 字体", notes: notes, excluded: excluded, allowedNoteIDs: chosen).notes.isEmpty,
                     "a question about an unapproved note must never broaden this meeting's scope")
        let cannotOverride: Set<String> = ["zoom-slides", "excluded", "restricted", "unknown"]
        precondition(ids(PicoMemoryStore.search(query: "工作 项目 Zoom", notes: notes, excluded: excluded, allowedNoteIDs: cannotOverride)) == ["zoom-slides"],
                     "allowlisting cannot override global exclusions or restricted content")
        precondition(PicoMemoryStore.search(query: "项目", notes: notes, excluded: [], allowedNoteIDs: ["unknown"]).notes.isEmpty,
                     "unknown IDs match nothing; they never fall back to all notes")
        precondition(PicoMemoryStore.search(query: "项目", notes: notes, excluded: chosen, allowedNoteIDs: chosen).notes.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-meeting-memory-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.sqlite")
        var db: OpaquePointer?
        precondition(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        precondition(sqlite3_exec(db, "CREATE TABLE notes(id TEXT PRIMARY KEY,text TEXT NOT NULL,updated TEXT NOT NULL);", nil, nil, nil) == SQLITE_OK)
        for note in notes {
            var statement: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, "INSERT INTO notes(id,text,updated) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            precondition(sqlite3_bind_text(statement, 1, note.id, -1, transient) == SQLITE_OK)
            precondition(sqlite3_bind_text(statement, 2, note.text, -1, transient) == SQLITE_OK)
            precondition(sqlite3_bind_text(statement, 3, note.updated, -1, transient) == SQLITE_OK)
            precondition(sqlite3_step(statement) == SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        sqlite3_close(db); db = nil
        let before = try Data(contentsOf: file)
        // Exercise the actual SQLite-backed entry point used by both the initial
        // background load and realtime memoryLookup, not a prompt-only fixture.
        let beforeMeeting = PicoMemoryStore.search(query: "身份 工作 项目 兴趣 计划 想法", directory: directory, excluded: excluded, allowedNoteIDs: chosen)
        let runtimeLookup = PicoMemoryStore.search(query: "Zoom Live Slides", directory: directory, excluded: excluded, allowedNoteIDs: chosen)
        precondition(ids(beforeMeeting) == chosen && ids(runtimeLookup) == chosen)
        precondition(PicoMemoryStore.search(query: "原创音乐", directory: directory, excluded: excluded, allowedNoteIDs: chosen).notes.isEmpty)
        precondition(ids(PicoMemoryStore.search(query: "工作 项目", directory: directory, excluded: excluded, allowedNoteIDs: cannotOverride)) == ["zoom-slides"])
        precondition(PicoMemoryStore.search(query: "项目", directory: directory, excluded: [], allowedNoteIDs: ["unknown"]).notes.isEmpty)
        precondition(PicoMemoryStore.search(query: "项目", directory: directory, excluded: [], allowedNoteIDs: []).notes.isEmpty)
        precondition(ids(PicoMemoryStore.search(query: "项目", directory: directory, excluded: excluded)) == ["zoom-slides", "zoom-live", "other-project"])
        let after = try Data(contentsOf: file)
        precondition(after == before, "meeting scope must never modify or delete the original memory database")

        let old = Data(#"{"background":"Synthetic meeting","goal":"Discuss slides","present":false,"materials":[]}"#.utf8)
        var preparation = try JSONDecoder().decode(PicoMeetingPreparation.self, from: old)
        precondition(preparation.memoryNoteIDs == nil && preparation.automaticallyLeavesOnGoodbye,
                     "an older draft retains default memory policy and other optional defaults")
        let nullScope = Data(#"{"background":"Synthetic meeting","goal":"Discuss slides","present":false,"materials":[],"memoryNoteIDs":null}"#.utf8)
        let nullPreparation = try JSONDecoder().decode(PicoMeetingPreparation.self, from: nullScope)
        precondition(nullPreparation.memoryNoteIDs == nil)
        preparation.memoryNoteIDs = ["zoom-slides", "zoom-live"]
        let scoped = try JSONDecoder().decode(PicoMeetingPreparation.self, from: JSONEncoder().encode(preparation))
        precondition(scoped.memoryNoteIDs == ["zoom-slides", "zoom-live"] && scoped.background == preparation.background && scoped.goal == preparation.goal)
        preparation.memoryNoteIDs = []
        let disabledBytes = try JSONEncoder().encode(preparation)
        let disabled = try JSONDecoder().decode(PicoMeetingPreparation.self, from: disabledBytes)
        let disabledObject = try JSONSerialization.jsonObject(with: disabledBytes) as? [String: Any]
        precondition(disabled.memoryNoteIDs == [] && disabledObject?["memoryNoteIDs"] is [Any],
                     "an explicit empty scope must survive saving rather than becoming nil")
        preparation.memoryNoteIDs = nil
        let defaulted = try JSONDecoder().decode(PicoMeetingPreparation.self, from: JSONEncoder().encode(preparation))
        precondition(defaulted.memoryNoteIDs == nil)
        let store = PicoPreparationStore(directory: directory)
        store.draft = scoped
        let restored = PicoPreparationStore(directory: directory)
        precondition(restored.draft.memoryNoteIDs == scoped.memoryNoteIDs && restored.draft.goal == scoped.goal,
                     "the real preparation store preserves the per-meeting allowlist")
        restored.draft.memoryNoteIDs = []
        precondition(PicoPreparationStore(directory: directory).draft.memoryNoteIDs == [])

        // Even an unreadable database is not opened when this meeting opts out.
        let unavailable = directory.appendingPathComponent("unavailable", isDirectory: true)
        try FileManager.default.createDirectory(at: unavailable, withIntermediateDirectories: true)
        try Data("not a SQLite database".utf8).write(to: unavailable.appendingPathComponent("memory.sqlite"))
        let off = PicoMemoryStore.search(query: "项目", directory: unavailable, excluded: [], allowedNoteIDs: [])
        precondition(off.notes.isEmpty && off.error == nil)
        print("PASS: per-meeting memory scope nil/empty/subset, exclusions and restricted notes remain enforced, unknown IDs fail closed, SQLite background/runtime searches, unchanged source memory, and legacy/scoped/disabled draft persistence")
    }
}

#if PICO_MEETING_MEMORY_SCOPE_STANDALONE
@main struct PicoMeetingMemoryScopeStandaloneTests {
    @MainActor static func main() throws { try PicoMeetingMemoryScopeTests.run() }
}
#endif
