import SwiftUI

func meetingTimestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds : 0))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
struct MeetingSettingsView: View {
    @ObservedObject var manager: MeetingSessionManager
    @AppStorage("TelosMeetingLanguage") private var language = "mixed"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Meeting → Transcript → Todo").font(.system(size: 14, weight: .medium))
            Text("Detect Zoom meetings and transcribe your microphone and Zoom audio separately on this Mac, including when using headphones. Audio recordings are not kept. After a meeting, the transcript is sent to your configured DeepSeek provider to suggest tasks. Nothing becomes a todo until you confirm.").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("Meeting language", selection: $language) {
                Text("Chinese + English · Local Qwen").tag("mixed")
                Text("Chinese · Apple").tag("zh-CN")
                Text("English · Apple").tag("en-US")
            }.disabled(manager.enabled || manager.preparing)
            Text("Apple provides streaming partial results for the selected language. Local Qwen handles mixed Chinese and English in short chunks. Both stay on this Mac. Requires macOS 26.").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button(manager.enabled ? "Turn off meeting capture" : "Enable Zoom meetings") { manager.enabled ? manager.disable() : manager.enable() }
                    .disabled(manager.preparing).buttonStyle(.bordered).nativeHoverFeedback()
                if manager.enabled {
                    Button("Set up meeting access") { manager.enable() }.disabled(manager.preparing).nativeHoverFeedback()
                }
                if manager.preparing { ProgressView().controlSize(.small) }
            }
            if !manager.setupMessage.isEmpty { Text(manager.setupMessage).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}
struct MeetingDetailView: View {
    @ObservedObject var store: TaskStore
    let session: MeetingSession
    @State private var selection = Set<UUID>()
    @State private var error: String?
    @State private var follow = true
    private var running: Bool { [.preparing, .recording, .finishing].contains(session.status) }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Text(session.title).font(serif(28)).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text("\(max(0, Int((session.endTime ?? context.date).timeIntervalSince(session.startTime) / 60))) min · \(running ? "Meeting in progress" : "Meeting \(session.status.rawValue)")")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Text(session.startTime.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
                    if running {
                        HStack {
                            Text(session.status == .preparing ? "Preparing transcription…" : session.status == .finishing ? "Saving final transcript…" : "Recording & transcribing…")
                            Spacer()
                            Button("Stop recording") { store.meetingManager.endByUser() }.disabled(session.status == .finishing)
                        }.font(.system(size: 13))
                    }
                    if let notice = session.notice { Text(notice).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled) }
                    if !running {
                        if session.analysisStatus == "analyzing" { Label("Finding possible next actions…", systemImage: "sparkles").font(.system(size: 13)) }
                        else if session.analysisStatus == "failed" || session.analysisStatus == "not_started" {
                            Button("Analyze saved transcript") { store.meetingManager.analyze(session.id) }.disabled(!session.transcript.contains { $0.isFinal })
                        }
                        if !session.suggestions.isEmpty {
                            suggestionSection("My todos", owner: "me")
                            suggestionSection("Others’ todos", owner: "others")
                            suggestionSection("Requests to confirm", owner: "unassigned")
                            Button("Create \(selection.count) \(selection.count == 1 ? "task" : "tasks")") {
                                do { _ = try store.createMeetingTasks(meetingID: session.id, selected: selection); selection.removeAll(); error = nil }
                                catch { self.error = error.localizedDescription }
                            }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 9)
                                .foregroundStyle(selection.isEmpty ? Color.secondary : TelosTheme.contrast)
                                .background(selection.isEmpty ? TelosTheme.shade(0.93, 0.23) : TelosTheme.primary, in: Capsule())
                                .disabled(selection.isEmpty || selection.count > 5).nativeHoverFeedback()
                            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
                        } else if session.analysisStatus == "ready" {
                            Text("No high-confidence action items found.").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        if !session.decisions.isEmpty {
                            Text("Decisions").font(.system(size: 16, weight: .semibold))
                            ForEach(session.decisions) { decision in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(decision.text).textSelection(.enabled)
                                    evidence(decision.evidence, proxy: proxy)
                                }
                            }
                        }
                        Divider()
                    }
                    HStack {
                        Text("Transcript").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        if running { Toggle("Follow", isOn: $follow).toggleStyle(.checkbox).font(.system(size: 12)) }
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.transcript.map { "[\(meetingTimestamp($0.startTime))] \($0.speakerSource == .me ? "Me" : "Others"): \($0.text)" }.joined(separator: "\n"), forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(HoverButtonStyle()).help("Copy full transcript")
                    }
                    if session.transcript.isEmpty { Text(running ? "Waiting for speech…" : "No speech was transcribed.").foregroundStyle(.secondary) }
                    ForEach(session.transcript) { segment in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(meetingTimestamp(segment.startTime)) · \(segment.speakerSource == .me ? "Me" : "Others")\(segment.isFinal ? "" : " · transcribing")").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(segment.text).font(.system(size: 14)).textSelection(.enabled)
                        }.id(segment.id).progressiveScrollBlur()
                    }
                    Color.clear.frame(height: 30).id("transcriptBottom")
                }.padding(.horizontal, 24).padding(.top, 44).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden).softScrollEdges(top: 40, bottom: 28, whiteSurface: true)
                .onChange(of: session.transcript.last?.text) { _, _ in if running && follow { proxy.scrollTo("transcriptBottom", anchor: .bottom) } }
        }.background(TelosTheme.surface).font(.system(size: 14))
    }
    @ViewBuilder private func suggestionSection(_ title: String, owner: String) -> some View {
        let values = session.suggestions.filter { $0.owner == owner }
        if !values.isEmpty {
            Text(title).font(.system(size: 16, weight: .semibold))
            ForEach(values) { item in
                VStack(alignment: .leading, spacing: 8) {
                    if item.createdTaskID != nil || store.tasks.contains(where: { $0.sourceSuggestionID == item.id }) {
                        Label(item.title, systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                    } else {
                        Toggle(item.title, isOn: Binding(get: { selection.contains(item.id) }, set: { if $0 { selection.insert(item.id) } else { selection.remove(item.id) } }))
                            .toggleStyle(.checkbox).disabled(!selection.contains(item.id) && selection.count >= 5)
                    }
                    if !item.description.isEmpty { Text(item.description).font(.system(size: 13)).textSelection(.enabled) }
                    if let due = item.dueDate { Text("Due " + due).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Text("\(meetingTimestamp(item.evidence.startTime)) · “\(item.evidence.text)”").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }
    private func evidence(_ value: TranscriptEvidence, proxy: ScrollViewProxy) -> some View {
        Button { proxy.scrollTo(value.segmentID, anchor: .center) } label: { Text("\(meetingTimestamp(value.startTime)) · “\(value.text)”").font(.system(size: 12)).foregroundStyle(.secondary) }.buttonStyle(HoverButtonStyle())
    }
}
