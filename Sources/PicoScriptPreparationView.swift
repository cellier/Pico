import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PicoScriptPreparationView: View {
    @ObservedObject var store: PicoPreparationStore
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slides 与完整讲稿").font(.subheadline.bold())
                Spacer()
                Button("导入演示脚本…") { choose() }
            }
            if let script = store.draft.presentationScript {
                Text("\(script.title) · \(script.slides.count) 页").textSelection(.enabled)
                Text(script.deckURL).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Text("开场可等待回答；每页讲完才翻页。介绍结束后保持共享，继续聊天和回看。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("查看与编辑讲稿…") { editing = true }
                    Button("改用提纲") { store.draft.presentationScript = nil }
                }
            } else {
                Text("已有完整讲稿时，可将它与 Zoom Slides 配对，按页讲解并接受插话。").font(.caption).foregroundStyle(.secondary)
            }
        }.sheet(isPresented: $editing) {
            if let script = store.draft.presentationScript {
                PicoScriptEditor(script: script) { value in
                    do { try value.validate(); store.draft.presentationScript = value; editing = false }
                    catch { store.message = error.localizedDescription }
                }
            }
        }
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.title = "导入已准备的演示脚本"; panel.prompt = "导入脚本"
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 512 * 1024 else { throw PicoPresentationScriptError.invalid("请选择 512 KB 以内的演示脚本。") }
                let value = try PicoPresentationScript.decode(Data(contentsOf: url))
                store.draft.presentationScript = value; store.draft.present = true
                store.message = "已保存 \(value.slides.count) 页演示脚本；尚未共享或向模型发送内容。"
            } catch { store.message = "脚本导入失败：" + error.localizedDescription }
        }
    }
}

private struct PicoScriptEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var script: PicoPresentationScript
    let save: (PicoPresentationScript) -> Void
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本场演示与讲稿").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("文稿标题（与 Zoom 中一致）", text: $script.title)
                    TextField("Zoom Slides 链接", text: $script.deckURL)
                    TextField("讲解语言，例如 zh-CN", text: $script.language)
                    DisclosureGroup("开场 · 可在问候后等待回答") { PicoScriptChunksEditor(chunks: $script.opening) }
                    DisclosureGroup("开始共享前的台词") { PicoScriptChunksEditor(chunks: $script.shareIntro) }
                    ForEach(script.slides.indices, id: \.self) { index in
                        DisclosureGroup("第 \(index + 1) 页 · \(script.slides[index].title)") {
                            TextField("本页标题", text: $script.slides[index].title)
                            PicoScriptChunksEditor(chunks: $script.slides[index].chunks)
                        }
                    }
                    DisclosureGroup("收尾 · 保持共享，回到聊天") { PicoScriptChunksEditor(chunks: $script.closing) }
                    Text("段落完成以本机声音播放结束为准。操作和等待由程序处理，不会念给听众。").font(.caption).foregroundStyle(.secondary)
                }.padding(.trailing, 8)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("取消") { dismiss() }; Spacer()
                Button("保存讲稿") {
                    do { try script.validate(); save(script) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width: 680, height: 650)
    }
}

private struct PicoScriptChunksEditor: View {
    @Binding var chunks: [PicoScriptChunk]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(chunks.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    TextEditor(text: $chunks[index].text).frame(minHeight: 55).border(.quaternary)
                        .accessibilityLabel("第 \(index + 1) 段台词")
                    Toggle("这段讲完后等待对方回答", isOn: $chunks[index].waitForReply)
                    if chunks[index].waitForReply {
                        if let seconds = chunks[index].replyTimeoutSeconds {
                            Text("无人回应时，约 \(seconds.formatted()) 秒后自然继续；对方发言、等待提问、暂停和接管时不会抢话。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("一直等待回复，不自动续讲。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("添加一段") { chunks.append(PicoScriptChunk(text: "")) }
        }.padding(.vertical, 6)
    }
}
