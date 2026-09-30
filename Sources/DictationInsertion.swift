import Foundation

/// AX selected ranges are UTF-16 offsets, not Swift character offsets.
enum DictationInsertion {
    static func expected(before: String?, range: CFRange?, text: String) -> String? {
        guard let before, let range, range.location >= 0, range.length >= 0 else { return nil }
        let source = before as NSString
        guard range.location <= source.length, range.length <= source.length - range.location else { return nil }
        return source.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }
    static func confirmed(expected: String?, actual: String?) -> Bool {
        guard let expected, let actual else { return false }
        return expected == actual
    }
}
