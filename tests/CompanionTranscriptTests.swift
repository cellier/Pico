import Foundation
@main struct CompanionTranscriptTests {
    static func main() {
        precondition(CompanionTranscript.read(" Pico，打开 Zoom Slides ") == "Pico，打开 Zoom Slides")
        precondition(CompanionTranscript.read(["decision":"approve"]) == nil)
        precondition(CompanionTranscript.read(42) == nil)
        precondition(CompanionTranscript.read("  ") == nil)
        precondition(CompanionTranscript.read(String(repeating:"a",count:3001)) == nil)
        precondition(CompanionTranscript.read("abc\0def") == nil)
        print("PASS: mixed transcript preserved; malformed and oversized input rejected")
    }
}
