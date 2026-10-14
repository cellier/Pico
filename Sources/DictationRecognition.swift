import Foundation

/// One recognition attempt, with local recovery and stale-result suppression.
/// Recovery never sends the fallback transcript to a second cloud service.
@MainActor final class DictationRecognition {
    typealias CloudReply = (Result<String, Error>) -> Void
    typealias LocalReply = ([String: Any]) -> Void
    enum Stage { case cloud, local, fallback(Error), polishing }
    private let cloud: (URL, @escaping CloudReply) -> Void
    private let local: (URL, Bool, @escaping LocalReply) -> Void
    private let cancelProviders: () -> Void
    private var generation = UUID()
    private var active = false

    init(cloud: @escaping (URL, @escaping CloudReply) -> Void,
         local: @escaping (URL, Bool, @escaping LocalReply) -> Void,
         cancel: @escaping () -> Void) {
        self.cloud = cloud; self.local = local; cancelProviders = cancel
    }
    convenience init(cloud: BailianDictation, local: DictationEngine) {
        self.init(cloud: cloud.transcribe, local: { local.transcribe($0, polish: $1, reply: $2) },
                  cancel: { cloud.cancel(); local.stop() })
    }
    func cancel() {
        generation = UUID()
        if active { active = false; cancelProviders() }
    }
    func transcribe(_ file: URL, useCloud: Bool, polish: Bool,
                    stage: @escaping (Stage) -> Void, completion: @escaping LocalReply) {
        cancel(); active = true
        let token = generation
        func finish(_ value: [String: Any]) {
            guard self.active, self.generation == token else { return }
            self.active = false; self.generation = UUID()
            completion(value)
        }
        var localStarted = false
        func runLocal(polish: Bool) {
            guard self.active, self.generation == token, !localStarted else { return }
            localStarted = true
            self.local(file, polish) { value in
                guard self.active, self.generation == token else { return }
                if value["stage"] as? String == "polishing" { stage(.polishing) }
                else { finish(value) }
            }
        }
        if useCloud {
            stage(.cloud)
            cloud(file) { result in
                guard self.active, self.generation == token, !localStarted else { return }
                switch result {
                case .success(let text): finish(["text": text])
                case .failure(let error):
                    stage(.fallback(error))
                    runLocal(polish: false)
                }
            }
        } else { stage(.local); runLocal(polish: polish) }
    }
}
