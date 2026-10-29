import Foundation
import SQLite3

@main struct PicoMemoryTests {
    static func main() throws {
        let notes = [
            PicoMemoryNote(id: "work", text: "工作：产品设计师，在 Zoom 负责 Zoom Slides。", updated: "2026-10-13"),
            PicoMemoryNote(id: "hobby", text: "兴趣：字体排印与原创音乐。", updated: "2026-10-12"),
            PicoMemoryNote(id: "private", text: "家人：女儿的姓名和住址。", updated: "2026-10-13"),
            PicoMemoryNote(id: "key", text: "Zoom API key sk-12345678901234567890", updated: "2026-10-13"),
            PicoMemoryNote(id: "mail", text: "Zoom 邮箱 example@example.com", updated: "2026-10-13")]
        precondition(PicoMemoryStore.search(query: "owner job", notes: notes, excluded: []).notes.map(\.id) == ["work"])
        precondition(PicoMemoryStore.search(query: "兴趣", notes: notes, excluded: []).notes.map(\.id) == ["hobby"])
        precondition(PicoMemoryStore.search(query: "Zoom", notes: notes, excluded: ["work"]).notes.isEmpty)
        precondition(PicoMemoryStore.search(query: "女儿 API key 邮箱", notes: notes, excluded: []).notes.isEmpty)
        precondition(PicoMemoryStore.search(query: "unrelatedunknown", notes: notes, excluded: []).notes.isEmpty)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-memory-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.sqlite")
        var db: OpaquePointer?; precondition(sqlite3_open(file.path, &db) == SQLITE_OK)
        precondition(sqlite3_exec(db, "CREATE TABLE notes(id TEXT PRIMARY KEY,text TEXT NOT NULL,updated TEXT NOT NULL); INSERT INTO notes VALUES('test','工作：设计师','2026-10-13');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: file)
        precondition(PicoMemoryStore.search(query: "工作", directory: directory, excluded: []).notes.count == 1)
        let after = try Data(contentsOf: file)
        precondition(after == before, "search must never mutate memory")
        let brief = "Synthetic brief: the project owner is preparing a product review."
        let materials = "Synthetic meeting materials: an opportunity is still unsigned; it is not realized revenue."
        let prompt = PicoMeetingPrompt.instructions(brief: brief, history: "", memory: true, preparation: materials)
        precondition(prompt.contains(brief) && prompt.contains(materials), "enabling memory must retain the other approved evidence sources")
        precondition(PicoMeetingPrompt.memoryInstructions.contains("complementary sources"))
        precondition(PicoMeetingPrompt.memoryInstructions.contains("Empty, unrelated or failed memory results do not negate facts in the materials or brief"), "an irrelevant memory result cannot erase a material-backed answer to the next question")
        precondition(PicoMeetingPrompt.memoryInstructions.contains("MUST call telos_memory_search"), "owner-background questions still require a real bounded search when the other sources do not answer them")
        precondition(!PicoMeetingPrompt.memoryInstructions.contains("Use only facts supported by relevant returned notes"), "retrieved notes cannot become the exclusive factual source")
        let missing = PicoMemoryResult(notes: [])
        let encoded = try JSONSerialization.jsonObject(with: Data(missing.json.utf8)) as! [String: Any]
        let guidance = encoded["guidance"] as! String
        precondition(guidance.contains("supplement the owner's brief and supplied meeting materials"))
        precondition(guidance.contains("Empty, unrelated or failed memory results do not negate facts in the materials or brief"))
        precondition(guidance.contains("Only when none of the approved sources provides reliable support"), "absence can be claimed only after checking all approved sources")
        precondition(guidance.contains("do not prepend a stock disclaimer to supported facts"))
        precondition(!guidance.contains("If absent, say") && !prompt.contains("这部分资料里没有，我不能确定"), "do not force a canned absence claim after a memory search")
        let unavailable = PicoMemoryResult(notes: [], error: "Synthetic lookup failure.")
        precondition(unavailable.guidance == missing.guidance, "a failed lookup must preserve the same complementary-source policy")
        print("PASS: Chinese/English retrieval, explicit exclusions, sensitive notes blocked, absent evidence empty, SQLite read-only.")
        print("PASS: memory complements meeting materials and brief; empty/failed notes cannot erase supported facts, and genuine missing evidence stays explicit.")
        if CommandLine.arguments.contains("--inspect-live") {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos")
            let live = try PicoMemoryStore.load(directory: root)
            print("Local notes: \(live.count); eligible: \(live.filter { !$0.restricted }.count)")
            for query in ["工作", "身份", "兴趣", "Zoom Slides"] { print("\(query): \(PicoMemoryStore.search(query: query, notes: live, excluded: []).notes.count) matches") }
        }
    }
}
