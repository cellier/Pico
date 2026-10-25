import Foundation
import QuartzCore

/// TEMPORARY: finds the live-resize update loop. Enabled with
/// `defaults write com.telos.mac PicoDiagLog -bool true`; writes to ~/Library/Logs/Pico/diag.log.
/// For each tracked measurement it records how often it is evaluated, how often its value
/// changes and the last values, so a value flipping between two states stands out.
enum PicoDiag {
    static let enabled = UserDefaults.standard.bool(forKey: "PicoDiagLog")
    nonisolated(unsafe) private static var calls: [String: Int] = [:]
    nonisolated(unsafe) private static var changes: [String: Int] = [:]
    nonisolated(unsafe) private static var last: [String: [String]] = [:]
    nonisolated(unsafe) private static var windowStart = CACurrentMediaTime()
    nonisolated(unsafe) private static let file: FileHandle? = {
        guard enabled else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pico")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("diag.log")
        if (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 > 20_000_000 { try? FileManager.default.removeItem(at: url) }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try? FileHandle(forWritingTo: url); _ = try? handle?.seekToEnd()
        handle?.write(Data("\n=== Pico started \(Date()) ===\n".utf8))
        return handle
    }()

    static func track(_ key: @autoclosure () -> String, _ value: @autoclosure () -> String) {
        guard enabled else { return }
        let key = key(), value = value()
        calls[key, default: 0] += 1
        if last[key]?.last != value {
            changes[key, default: 0] += 1
            var values = last[key] ?? []; values.append(value)
            if values.count > 6 { values.removeFirst(values.count - 6) }
            last[key] = values
        }
        flushIfDue()
    }

    private static func flushIfDue() {
        let now = CACurrentMediaTime()
        guard now - windowStart > 0.5 else { return }
        windowStart = now
        let busy = calls.values.reduce(0, +)
        // Quiet periods are not interesting.
        if busy > 40 {
            let top = changes.sorted { $0.value > $1.value }.prefix(10).map { key, n in
                "  \(key) changes=\(n) calls=\(calls[key] ?? 0) last=\((last[key] ?? []).joined(separator: " | "))"
            }
            let quiet = calls.filter { (changes[$0.key] ?? 0) == 0 }.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)×\($0.value)" }
            let line = "[\(Date().formatted(date: .omitted, time: .standard))] evaluations=\(busy)\n" + top.joined(separator: "\n")
                + (quiet.isEmpty ? "" : "\n  unchanged: " + quiet.joined(separator: ", ")) + "\n"
            file?.write(Data(line.utf8))
        }
        calls.removeAll(); changes.removeAll()
    }
}
