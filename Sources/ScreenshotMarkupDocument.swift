import Foundation

/// A local, explicitly saved editable copy. Unlike a shared PNG, this includes
/// the ORIGINAL screenshot, even where the visible result has been covered up.
struct ScreenshotMarkupDocument: Codable, Equatable {
    static let currentVersion = 1
    static let maximumFileBytes = 192 * 1024 * 1024
    static let maximumImageBytes = 64 * 1024 * 1024
    let version: Int
    let originalPNG: Data
    let markupData: Data
    let previewPNG: Data
    let canvasWidth: Double
    let canvasHeight: Double

    init(originalPNG: Data, markupData: Data, previewPNG: Data,
         canvasWidth: Double, canvasHeight: Double) throws {
        self.version = Self.currentVersion
        self.originalPNG = originalPNG
        self.markupData = markupData
        self.previewPNG = previewPNG
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        try validate()
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileBytes else { throw DocumentError.tooLarge }
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumFileBytes else { throw DocumentError.tooLarge }
        return data
    }

    func validate() throws {
        guard version == Self.currentVersion else { throw DocumentError.unsupportedVersion }
        guard canvasWidth.isFinite, canvasHeight.isFinite,
              canvasWidth > 0, canvasHeight > 0,
              canvasWidth <= 100_000, canvasHeight <= 100_000,
              !originalPNG.isEmpty, !markupData.isEmpty, !previewPNG.isEmpty else {
            throw DocumentError.invalidDocument
        }
        guard originalPNG.count <= Self.maximumImageBytes,
              previewPNG.count <= Self.maximumImageBytes,
              markupData.count <= Self.maximumImageBytes else { throw DocumentError.tooLarge }
    }

    enum DocumentError: LocalizedError {
        case invalidDocument, unsupportedVersion, tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidDocument: return "This is not a valid Telos editable screenshot."
            case .unsupportedVersion: return "This editable screenshot requires a newer version of Telos. The file has not been changed."
            case .tooLarge: return "This screenshot is too large to open or save safely."
            }
        }
    }
}
