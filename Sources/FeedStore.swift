import Foundation
import AppKit

struct FeedRule: Codable, Identifiable {
    var id: String
    var title: String
    var rules: String
    var sources: [String]
    var interval_minutes: Int
    var enabled: Bool
    var updated: Double
    var last_refresh: Double
    var task_id: String
    var revision: Int
    var lookback_hours: Int? = nil
    var group_by_competitor: Bool? = nil
}
struct FeedItem: Codable, Identifiable {
    var id: String
    var feed_id: String
    var title: String
    var body: String
    var url: String
    var image_url: String
    var published: Double
    var read: Bool
    var hidden: Bool
    var image_urls: [String]? = nil
    var images: [String] { image_urls?.isEmpty == false ? image_urls! : (image_url.isEmpty ? [] : [image_url]) }
}
struct FeedSnapshot: Decodable {
    var feeds: [FeedRule]
    var items: [FeedItem]
}
enum BoardTab: String, CaseIterable { case tasks = "Task", calendar = "Calendar", feed = "Feed" }

extension TaskStore {
    func searchTasks(_ query: String) -> [Todo] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return filtered }
        return tasks.filter { todo in
            let text = ([todo.title, todo.summary] + todo.messages.map(\.text) + todo.artifacts.map(\.name)).joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }
    func feedCommand(_ command: [String: Any] = [:], refreshDue: Bool = false) {
        guard ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil else { return }
        guard let python = BundledRuntime.python(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/feeds.py"),
              let input = try? JSONSerialization.data(withJSONObject: command) else { return }
        let directory = dataDir.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-B", script.path]
            process.environment = ProcessInfo.processInfo.environment.merging(["TELOS_DATA_DIR": directory]) { _, new in new }
            process.standardOutput = output; process.standardInput = stdin; process.standardError = FileHandle.nullDevice
            do {
                try process.run(); try stdin.fileHandleForWriting.write(contentsOf: input + Data([10])); try stdin.fileHandleForWriting.close()
                let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let value = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: String]
                    throw NSError(domain: "TelosFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: value?["error"] ?? "Could not update feed."])
                }
                let snapshot = try JSONDecoder().decode(FeedSnapshot.self, from: bytes)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.feeds = snapshot.feeds; self.feedItems = snapshot.items; self.feedError = nil
                    if refreshDue { self.refreshDueFeeds() }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.feedError = message }
            }
        }
    }
    func refreshDueFeeds() {
        for feed in feeds where feed.enabled && feed.interval_minutes > 0 {
            let lastAttempt = UserDefaults.standard.double(forKey: "feedAttempt." + feed.id)
            if FeedSchedule.isDue(intervalMinutes: feed.interval_minutes, lastRefresh: feed.last_refresh, lastAttempt: lastAttempt) {
                refreshFeed(feed)
            }
        }
    }
    func refreshFeed(_ feed: FeedRule) {
        guard !tasks.contains(where: { $0.feedID == feed.id && ["running", "awaiting_approval"].contains($0.status) }) else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "feedAttempt." + feed.id)
        let prompt = "Refresh my existing feed \"\(feed.title)\" (ID \(feed.id)). Read its current rules, research only matching information and publish useful new items with source links. Respect exclusions and don't repeat existing items. For a daily competitor feed, only use verified news published in the most recent 24 hours. Merge multiple new updates per canonical competitor within this refresh into one new item. Preserve all historical cards; never replace prior refreshes. Reuse event keys across syndicated reports. Omit competitors without fresh news and publish an empty batch when there are no new events. Report unavailable sources honestly. Do not change rules, run arbitrary scripts or perform external actions."
        if let task = tasks.first(where: { $0.feedID == feed.id }) {
            ask(task.id, text: prompt)
        } else {
            var task = Todo(title: "Refresh " + feed.title)
            task.feedID = feed.id; task.messages = [Message(role: "user", text: prompt)]
            tasks.insert(task, at: 0); save(); run(task.id, prompt: prompt, new: false)
        }
    }
    func deleteFeed(_ feed: FeedRule) {
        for task in tasks where task.feedID == feed.id { stop(task.id) }
        feedCommand(["command": "manage", "action": "delete", "id": feed.id])
    }
}
