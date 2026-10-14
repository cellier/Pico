import Foundation

@main struct TaskExecutionPolicyTests {
    static func main() {
        let suite = "TelosExecutionTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func request(_ voice: String? = nil, feed: String? = nil) -> [String: Bool] {
            TaskExecutionPolicy.requestOptions(feedID: feed, voiceRequestID: voice, defaults: defaults)
        }
        precondition(request() == ["auto_approve": true, "voice": false])
        precondition(request("spoken-request") == ["auto_approve": true, "voice": true])
        precondition(request(feed: "feed")["auto_approve"] == false)
        precondition(request("spoken-request", feed: "feed")["auto_approve"] == false)
        defaults.set(false, forKey: TaskExecutionPolicy.preference)
        precondition(request()["auto_approve"] == false)
        precondition(request("spoken-request")["auto_approve"] == false)
        defaults.set(true, forKey: TaskExecutionPolicy.preference)
        precondition(request("spoken-request")["auto_approve"] == true)
        precondition(request(feed: "feed")["auto_approve"] == false)
        print("PASS: automatic by default for text and voice; manual preference and restricted feeds preserved")
    }
}
