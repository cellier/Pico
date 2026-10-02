import Foundation

@main struct ScreenshotMarkupDocumentTests {
    static func main() throws {
        let document = try ScreenshotMarkupDocument(
            originalPNG: Data([1, 2, 3]), markupData: Data([4, 5]),
            previewPNG: Data([6, 7]), canvasWidth: 1440, canvasHeight: 900)
        let data = try document.encoded()
        let roundTrip = try ScreenshotMarkupDocument.decode(data)
        precondition(roundTrip == document, "Preserve the original, annotations and preview independently")
        precondition(roundTrip.originalPNG != roundTrip.previewPNG)
        for (width, height) in [(0.0, 1.0), (-1, 1), (1, 0), (Double.infinity, 1),
                                (1, Double.nan), (100_001, 1)] {
            expectFailure {
                _ = try ScreenshotMarkupDocument(originalPNG: Data([1]), markupData: Data([2]),
                    previewPNG: Data([3]), canvasWidth: width, canvasHeight: height)
            }
        }
        expectFailure { _ = try ScreenshotMarkupDocument.decode(Data("not JSON".utf8)) }
        for key in ["originalPNG", "markupData", "previewPNG"] {
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            json[key] = ""
            expectFailure { _ = try ScreenshotMarkupDocument.decode(JSONSerialization.data(withJSONObject: json)) }
        }
        var future = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        future["version"] = 99
        expectFailure { _ = try ScreenshotMarkupDocument.decode(JSONSerialization.data(withJSONObject: future)) }
        var invalid = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        invalid["canvasWidth"] = -10
        expectFailure { _ = try ScreenshotMarkupDocument.decode(JSONSerialization.data(withJSONObject: invalid)) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)
        let reopened = try ScreenshotMarkupDocument.decode(Data(contentsOf: url))
        precondition(reopened == document, "Editable copies must reopen without data loss")
        print("PASS: editable-document round trip, independent layers, invalid dimensions, empty payloads, future version, corrupt input, atomic file round trip")
    }
    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected validation failure") } catch { }
    }
}
