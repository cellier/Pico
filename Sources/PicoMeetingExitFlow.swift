import Foundation

/// The narrow barrier between an explicitly requested farewell and a local leave action.
/// This value performs no audio, UI, model or timer work. One instance permits one request;
/// a new meeting (or an explicitly authorised retry) must use a new instance.
struct PicoMeetingExitFlow: Sendable {
    enum Phase: String, Sendable {
        case idle, waitingForSpeech, awaitingResponse, awaitingPlayback
        case readyToExit, executing, completed, cancelled
    }
    private(set) var phase = Phase.idle
    private(set) var epoch: UUID?
    private(set) var replyID: String?
    private(set) var deadline: Date?
    private(set) var cancellationReason: String?
    private(set) var completionSucceeded: Bool?
    private(set) var resultMessage: String?
    private var completedWithAudio = false

    var pending: Bool {
        switch phase {
        case .waitingForSpeech, .awaitingResponse, .awaitingPlayback, .readyToExit, .executing: return true
        case .idle, .completed, .cancelled: return false
        }
    }
    var freezesScript: Bool { pending }

    @discardableResult mutating func request(epoch token: UUID, now: Date = Date(), timeout: TimeInterval = 30) -> Bool {
        guard phase == .idle, timeout.isFinite, timeout > 0 else { return false }
        epoch = token; deadline = now.addingTimeInterval(min(timeout, 120))
        phase = .waitingForSpeech
        return true
    }
    /// Call only when the realtime client has accepted the app's farewell speech request.
    @discardableResult mutating func markSpeechRequested(epoch token: UUID) -> Bool {
        guard token == epoch, phase == .waitingForSpeech else { return false }
        phase = .awaitingResponse
        return true
    }
    @discardableResult mutating func responseStarted(id: String, epoch token: UUID) -> Bool {
        guard token == epoch, phase == .awaitingResponse, !id.isEmpty else { return false }
        replyID = id; phase = .awaitingPlayback
        return true
    }
    @discardableResult mutating func responseFinished(id: String, completed: Bool, hasAudio: Bool, epoch token: UUID) -> Bool {
        guard token == epoch, phase == .awaitingPlayback, replyID == id, !completedWithAudio else { return false }
        guard completed else { return cancel(reason: "告别语音未完成，已取消自动离会。") }
        guard hasAudio else { return cancel(reason: "告别回复没有可播放的音频，已取消自动离会。") }
        completedWithAudio = true
        return true
    }
    /// Only a drain observed after successful audio completion is eligible. An earlier drain
    /// might be a temporary queue gap while more audio is still arriving, so it is ignored.
    @discardableResult mutating func drained(replyIDs: Set<String>, epoch token: UUID) -> Bool {
        guard token == epoch, phase == .awaitingPlayback, completedWithAudio,
              let replyID, replyIDs.contains(replyID) else { return false }
        phase = .readyToExit
        return true
    }
    /// Consume readiness once immediately before the caller invokes its local leave driver.
    @discardableResult mutating func beginExecuting(epoch token: UUID) -> Bool {
        guard token == epoch, phase == .readyToExit else { return false }
        phase = .executing
        return true
    }
    @discardableResult mutating func complete(epoch token: UUID, success: Bool, message: String? = nil) -> Bool {
        guard token == epoch, phase == .executing else { return false }
        completionSucceeded = success; resultMessage = message
        if success { phase = .completed }
        else { phase = .cancelled; cancellationReason = message ?? "离会操作未成功。" }
        return true
    }
    /// Cancelling an idle instance is intentionally a no-op: ordinary conversation and
    /// interruptions before an exit request must not disable a later explicit request.
    @discardableResult mutating func cancel(reason: String = "自动离会已取消。") -> Bool {
        guard pending else { return false }
        phase = .cancelled; cancellationReason = reason; completedWithAudio = false
        return true
    }
    /// The owner drives this check from its existing timer. Executing remains pending until
    /// the local driver reports a result or an explicit lifecycle cancellation occurs.
    @discardableResult mutating func checkTimeout(now: Date = Date()) -> Bool {
        guard pending, phase != .executing, let deadline, now >= deadline else { return false }
        return cancel(reason: "等待告别播放或离会确认超时，已取消自动离会。")
    }
}
