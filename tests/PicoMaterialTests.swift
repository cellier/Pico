import AppKit
import SwiftUI
import PDFKit
@main struct PicoMaterialTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-material-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let note = directory.appendingPathComponent("项目介绍.md")
        try "# 测试项目\n目标：听取建议。\n这是一份测试会议材料。".write(to: note, atomically: true, encoding: .utf8)
        let material = try PicoMaterialReader.read(note, python: nil, script: nil)
        precondition(material.text.contains("听取建议"))
        let scanImage = NSImage(size: NSSize(width: 100, height: 100))
        scanImage.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); scanImage.unlockFocus()
        let pdf = PDFDocument(); let page = PDFPage(image: scanImage)!; pdf.insert(page, at: 0)
        let scan = directory.appendingPathComponent("scan.pdf"); pdf.write(to: scan)
        do { _ = try PicoMaterialReader.read(scan, python: nil, script: nil); preconditionFailure("Image PDF must not claim text extraction success") } catch { }
        let large = directory.appendingPathComponent("large.txt"); try String(repeating: "x", count: 20001).write(to: large, atomically: true, encoding: .utf8)
        do { _ = try PicoMaterialReader.read(large, python: nil, script: nil); preconditionFailure("Must not truncate") } catch { }
        let store = PicoPreparationStore(directory: directory)
        store.draft.background = "讨论产品"; store.draft.goal = "获取反馈"; store.draft.materials = [material]; store.draft.present = true
        let restored = PicoPreparationStore(directory: directory)
        precondition(restored.draft.materials.first?.text == material.text && restored.draft.goal == "获取反馈")
        let prompt = restored.draft.context
        precondition(prompt.contains(material.text.replacingOccurrences(of: "\n", with: "\\n")) && prompt.contains("获取反馈") && prompt.contains("untrusted"))
        restored.newMeeting(); precondition(restored.draft.materials.isEmpty && restored.draft.goal.isEmpty)
        precondition(FileManager.default.fileExists(atPath: note.path))
        print("PASS: local text parsing, unreadable PDF refusal, no truncation, draft persistence, prompt material inclusion, new-meeting isolation")
        if CommandLine.arguments.contains("--preview") || Bundle.main.object(forInfoDictionaryKey: "PicoMaterialsQA") as? Bool == true {
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 550), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Pico Materials QA · 本地测试"
            window.contentView = NSHostingView(rootView: ScrollView { PicoPreparationView(store: store, disabled: false).padding(20) })
            window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); app.run()
        }
        try? FileManager.default.removeItem(at: directory)
    }
}
