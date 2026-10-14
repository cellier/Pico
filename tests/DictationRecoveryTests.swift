import Foundation

@main struct DictationRecoveryTests {
    @MainActor static func main() {
        var cloudReplies: [DictationRecognition.CloudReply] = []
        var localReplies: [DictationRecognition.LocalReply] = []
        var localPolish: [Bool] = []
        var results: [[String: Any]] = []
        var cancellations = 0
        var fallbackCount = 0
        let recognizer = DictationRecognition(cloud: { _, reply in cloudReplies.append(reply) },
            local: { _, polish, reply in localPolish.append(polish); localReplies.append(reply) },
            cancel: { cancellations += 1 })
        let file = URL(fileURLWithPath: "/test/recording.wav")
        func start(cloud: Bool = true) {
            recognizer.transcribe(file, useCloud: cloud, polish: true, stage: { stage in
                if case .fallback = stage { fallbackCount += 1 }
            }, completion: { results.append($0) })
        }
        start()
        cloudReplies[0](.failure(URLError(.userAuthenticationRequired)))
        precondition(localReplies.count == 1 && localPolish == [false] && fallbackCount == 1)
        cloudReplies[0](.success("stale cloud reply"))
        precondition(results.isEmpty)
        localReplies[0](["text": "请打开 Zoom Slides"])
        localReplies[0](["text": "duplicate"])
        precondition(results.count == 1 && results[0]["text"] as? String == "请打开 Zoom Slides")
        start()
        recognizer.cancel()
        cloudReplies[1](.failure(URLError(.timedOut)))
        precondition(localReplies.count == 1 && results.count == 1 && cancellations == 1)
        start()
        cloudReplies[2](.failure(URLError(.notConnectedToInternet)))
        precondition(localReplies.count == 2)
        recognizer.cancel()
        localReplies[1](["text": "cancelled"])
        precondition(results.count == 1)
        start()
        cloudReplies[3](.success("中英文 review PRD"))
        precondition(results.count == 2 && localReplies.count == 2)
        start()
        cloudReplies[4](.success(""))
        precondition(results.count == 3 && localReplies.count == 2, "silence must not be re-recognized")
        start(cloud: false)
        precondition(localPolish.last == true && cloudReplies.count == 5)
        localReplies[2](["error": "Local engine unavailable"])
        precondition(results.count == 4 && results.last?["error"] != nil)
        start(); start()
        cloudReplies[5](.success("superseded"))
        cloudReplies[6](.success("current"))
        precondition(results.count == 5 && results.last?["text"] as? String == "current")
        print("PASS: inaccessible key and offline recovery, no fallback polish, cloud success/silence, local failure, cancellation, duplicate and stale callbacks")
    }
}
