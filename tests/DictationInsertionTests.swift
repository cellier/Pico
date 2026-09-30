import Foundation
@main struct DictationInsertionTests {
    static func main() {
        let expected = DictationInsertion.expected(before: "Hello world", range: CFRange(location: 6, length: 5), text: "中文 English")
        precondition(expected == "Hello 中文 English")
        precondition(!DictationInsertion.confirmed(expected: expected, actual: "Hello world"), "Unchanged editor must not report Inserted")
        precondition(DictationInsertion.confirmed(expected: expected, actual: "Hello 中文 English"))
        precondition(!DictationInsertion.confirmed(expected: nil, actual: nil), "Unreadable editors are unconfirmed")
        precondition(DictationInsertion.expected(before: "😀abc", range: CFRange(location: 2, length: 0), text: "好") == "😀好abc")
        precondition(DictationInsertion.expected(before: "abc", range: CFRange(location: 4, length: 0), text: "x") == nil)
        precondition(DictationInsertion.expected(before: "abc", range: CFRange(location: 2, length: 4), text: "x") == nil)
        print("PASS: insertion confirmation, no-op rejection, unreadable fields, UTF-16 selection replacement")
    }
}
