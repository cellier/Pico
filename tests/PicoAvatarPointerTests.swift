import AppKit
import Foundation

/// Check the AppKit -> JavaScript coordinate contract without launching an app.
@main struct PicoAvatarPointerTests {
    static func coordinates(_ point: NSPoint, in bounds: NSRect) -> [Double] {
        guard let script = PicoAvatarPointer.script(point: point, bounds: bounds),
              let start = script.range(of: "pointerAt("),
              let end = script[start.upperBound...].firstIndex(of: ")") else {
            fatalError("A finite point in a nonempty avatar must produce a pointer script")
        }
        return script[start.upperBound..<end].split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))!
        }
    }

    static func expect(_ actual: [Double], _ x: Double, _ y: Double) {
        precondition(actual.count == 2 && abs(actual[0] - x) < 1e-9 && abs(actual[1] - y) < 1e-9,
                     "Pointer normalization differs: \(actual), expected [\(x), \(y)]")
    }

    static func main() {
        for edge in [26.0, 36, 52, 179.2] {
            let bounds = NSRect(x: 0, y: 0, width: edge, height: edge)
            expect(coordinates(NSPoint(x: edge / 2, y: edge / 2), in: bounds), 0, 0)
            expect(coordinates(NSPoint(x: 0, y: edge / 2), in: bounds), -1, 0)
            expect(coordinates(NSPoint(x: edge, y: edge / 2), in: bounds), 1, 0)
            expect(coordinates(NSPoint(x: edge / 2, y: 0), in: bounds), 0, -1)
            expect(coordinates(NSPoint(x: edge / 2, y: edge), in: bounds), 0, 1)
            expect(coordinates(NSPoint(x: edge * 2, y: edge * -0.5), in: bounds), 3, -2)
        }
        let movedBounds = NSRect(x: 17, y: -6, width: 52, height: 36)
        expect(coordinates(NSPoint(x: 43, y: 12), in: movedBounds), 0, 0)
        expect(coordinates(NSPoint(x: 56, y: 21), in: movedBounds), 0.5, 0.5)
        // Backing pixels are deliberately absent from this API: Retina changes
        // drawing resolution, never the logical point or normalized direction.
        for invalid in [NSRect(x: 0, y: 0, width: 0, height: 26),
                        NSRect(x: 0, y: 0, width: 26, height: 0),
                        NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 26)] {
            precondition(PicoAvatarPointer.script(point: .zero, bounds: invalid) == nil)
        }
        for invalid in [NSPoint(x: CGFloat.nan, y: 0), NSPoint(x: 0, y: CGFloat.infinity)] {
            precondition(PicoAvatarPointer.script(point: invalid, bounds: NSRect(x: 0, y: 0, width: 26, height: 26)) == nil)
        }
        print("PASS avatar native pointer: 26/36/52/179.2pt, center/edges, nonzero bounds, distance fade coordinates, non-finite guards")
    }
}
