import SwiftUI
import AppKit

struct FeedList: View {
    @ObservedObject var store: TaskStore
    var query: String
    var newFeed: () -> Void
    var topInset: CGFloat = 60
    @State private var showingRules = false
    var items: [FeedItem] {
        guard !query.isEmpty else { return store.feedItems }
        return store.feedItems.filter { ($0.title + " " + $0.body).localizedStandardContains(query) }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !store.feeds.isEmpty && query.isEmpty {
                    HStack {
                        Spacer()
                        Button("Manage feeds") { showingRules = true }.buttonStyle(HoverButtonStyle()).font(.system(size: 12))
                    }.padding(.horizontal, 24).padding(.bottom, 4)
                }
                ForEach(store.feeds.filter { $0.needsRetry }) { feed in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feed.title).font(.system(size: 12, weight: .medium))
                        Text(feed.healthText).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 24).padding(.vertical, 10)
                }
                if items.isEmpty {
                    ContentUnavailableView(query.isEmpty ? (store.feeds.isEmpty ? "A feed shaped by you" : "No articles yet") : "No results", systemImage: "text.below.photo", description: Text(query.isEmpty ? (store.feeds.isEmpty ? "Tell Telos what you want to follow in a new task. Your updates will appear here." : "New articles will appear here.") : "Try another topic."))
                        .padding(.top, 40)
                    if query.isEmpty && store.feeds.isEmpty {
                        Button("Create a feed", action: newFeed)
                            .buttonStyle(.bordered).nativeHoverFeedback().frame(maxWidth: .infinity)
                    }
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.title).font(serif(24)).tracking(0.3).lineSpacing(-5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).progressiveScrollBlur()
                        if item.delayed == 1 {
                            Text("Delayed discovery · original source dates below")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(description(item)).font(.system(size: 14)).lineSpacing(1).tracking(-0.2).foregroundStyle(TelosTheme.shade(0.35, 0.72)).textSelection(.enabled).progressiveScrollBlur()
                        if !item.images.isEmpty {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(Array(item.images.enumerated()), id: \.offset) { _, source in
                                        FeedImage(source: source).progressiveScrollBlur()
                                    }
                                }
                            }.scrollIndicators(.hidden).padding(.top, 8)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            if let url = safeURL(item.url) { Button("Open source") { NSWorkspace.shared.open(url) } }
                            Button("Mark as read") { store.feedCommand(["command": "item", "action": "read", "id": item.id]) }
                            Button("Remove item") { store.feedCommand(["command": "item", "action": "hide", "id": item.id]) }
                        }
                }
            }.padding(.top, topInset).padding(.bottom, 16)
        }.scrollIndicators(.hidden)
            .softScrollEdges(top: topInset + 12, bottom: 40, alwaysTop: true)
            .defaultScrollAnchor(ProcessInfo.processInfo.environment["TELOS_PREVIEW_SCROLL"] == "bottom" ? .bottom : .top)
            .environment(\.openURL, OpenURLAction { url in
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return .discarded }
                return .systemAction
            })
            .sheet(isPresented: $showingRules) { FeedRulesView(store: store, newFeed: newFeed) }
    }
    func description(_ item: FeedItem) -> AttributedString {
        var value = (try? AttributedString(markdown: item.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.body)
        if let url = safeURL(item.url), !value.runs.contains(where: { $0.link == url }) {
            value += AttributedString(" ")
            var source = AttributedString(url.host ?? "Source"); source.link = url
            value += source
        }
        return value
    }
    func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
}
struct FeedImage: View {
    var source: String
    var body: some View {
        Group {
            if source == "preview", let url = Bundle.main.url(forResource: "feed-preview", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let url = URL(string: source), ["http", "https"].contains(url.scheme ?? "") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                    else { RoundedRectangle(cornerRadius: 16).fill(TelosTheme.shade(0.95, 0.20)).overlay(Image(systemName: "photo").foregroundStyle(.secondary)) }
                }
            }
        }.frame(width: 188, height: 120).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
struct FeedRulesView: View {
    @ObservedObject var store: TaskStore
    var newFeed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing: FeedRule?
    @State private var deleting: FeedRule?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your feeds").font(serif(30)); Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Create or change a feed in a task, or edit its rules here. Scheduled refreshes run while Telos is open.").font(.system(size: 13)).foregroundStyle(.secondary)
            if let error = store.feedError { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
            List {
                ForEach(store.feeds) { feed in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(feed.title).font(.headline); Spacer()
                            Text(feed.enabled ? (feed.interval_minutes == 0 ? "Manual" : "Every \(feed.interval_minutes) min") : "Paused").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(feed.rules).font(.system(size: 13)).lineLimit(3).foregroundStyle(.secondary)
                        Text(feed.healthText).font(.system(size: 12)).foregroundStyle(feed.needsRetry ? Color.orange : Color.secondary)
                        if let total = feed.source_count, total > 0 {
                            Text("\(feed.checked_sources ?? 0) of \(total) sources checked").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Edit rules") { editing = feed }
                            Button("Refresh") { store.refreshFeed(feed) }.disabled(store.tasks.contains { $0.feedID == feed.id && ["running", "awaiting_approval"].contains($0.status) })
                            Button(feed.enabled ? "Pause" : "Resume") { store.feedCommand(["command": "manage", "action": "update", "id": feed.id, "enabled": !feed.enabled]) }
                            Spacer()
                            Button("Delete", role: .destructive) { deleting = feed }
                        }.buttonStyle(HoverButtonStyle())
                    }.padding(.vertical, 8)
                }
                if store.feeds.isEmpty { Text("No feeds yet.").foregroundStyle(.secondary) }
            }.listStyle(.inset).frame(minHeight: 180)
            Button("Create a feed in a task") { dismiss(); newFeed() }.buttonStyle(.borderedProminent).nativeHoverFeedback()
        }.padding(24).frame(width: 570, height: 450)
            .confirmationDialog("Delete this feed and its saved items?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete feed", role: .destructive) { if let feed = deleting { store.deleteFeed(feed) }; deleting = nil }
                Button("Cancel", role: .cancel) { deleting = nil }
            }
            .sheet(item: $editing) { rule in FeedRuleEditor(store: store, feed: rule) }
    }
}
struct FeedRuleEditor: View {
    @ObservedObject var store: TaskStore
    let feed: FeedRule
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var rules = ""
    @State private var sources = ""
    @State private var interval = 0
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit feed").font(serif(28))
            Form {
                TextField("Name", text: $title)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Content rules")
                    TextEditor(text: $rules).frame(height: 110).font(.system(size: 13)).border(.quaternary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sources · one URL per line")
                    TextEditor(text: $sources).frame(height: 60).font(.system(size: 12)).border(.quaternary)
                }
                Picker("Refresh while Telos is open", selection: $interval) {
                    Text("Manually").tag(0); Text("Every hour").tag(60); Text("Every 6 hours").tag(360); Text("Daily").tag(1440)
                    if ![0,60,360,1440].contains(feed.interval_minutes) { Text("Every \(feed.interval_minutes) minutes").tag(feed.interval_minutes) }
                }
            }
            if let error = store.feedError { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button(saving ? "Saving…" : "Save rules") {
                saving = true
                store.feedCommand(["command": "manage", "action": "update", "id": feed.id, "title": title, "rules": rules, "sources": sources.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }, "interval_minutes": interval])
            }.buttonStyle(.borderedProminent).nativeHoverFeedback().disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 510)
            .onChange(of: store.feeds.first(where: { $0.id == feed.id })?.revision) { _, revision in if saving, let revision, revision > feed.revision { dismiss() } }
            .onChange(of: store.feedError) { _, error in if error != nil { saving = false } }
            .onAppear { title = feed.title; rules = feed.rules; sources = feed.sources.joined(separator: "\n"); interval = feed.interval_minutes }
    }
}
