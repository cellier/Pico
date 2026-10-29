import Foundation

struct PicoScriptChunk: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var text: String
    var waitForReply: Bool
    /// Keep a discussion open across ordinary answers until an explicit continue.
    var waitForExplicitContinue: Bool
    var replyTimeoutSeconds: TimeInterval?
    var replyTimeoutTransition: String?
    init(id: String = UUID().uuidString, text: String, waitForReply: Bool = false,
         replyTimeoutSeconds: TimeInterval? = 12, replyTimeoutTransition: String? = nil,
         waitForExplicitContinue: Bool = false) {
        self.id = id; self.text = text; self.waitForReply = waitForReply
        self.waitForExplicitContinue = waitForExplicitContinue
        self.replyTimeoutSeconds = replyTimeoutSeconds; self.replyTimeoutTransition = replyTimeoutTransition
    }
    private enum CodingKeys: String, CodingKey { case id, text, waitForReply, replyTimeoutSeconds, replyTimeoutTransition, waitForExplicitContinue }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try values.decode(String.self, forKey: .text)
        waitForReply = try values.decodeIfPresent(Bool.self, forKey: .waitForReply) ?? false
        waitForExplicitContinue = try values.decodeIfPresent(Bool.self, forKey: .waitForExplicitContinue) ?? false
        replyTimeoutSeconds = values.contains(.replyTimeoutSeconds) ? try values.decodeIfPresent(TimeInterval.self, forKey: .replyTimeoutSeconds) : 12
        replyTimeoutTransition = try values.decodeIfPresent(String.self, forKey: .replyTimeoutTransition)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(text, forKey: .text)
        try values.encode(waitForReply, forKey: .waitForReply)
        try values.encode(waitForExplicitContinue, forKey: .waitForExplicitContinue)
        // Explicit null disables fallback and must survive round-tripping; omission means 12s.
        if let replyTimeoutSeconds { try values.encode(replyTimeoutSeconds, forKey: .replyTimeoutSeconds) }
        else { try values.encodeNil(forKey: .replyTimeoutSeconds) }
        try values.encodeIfPresent(replyTimeoutTransition, forKey: .replyTimeoutTransition)
    }
}

struct PicoScriptSlide: Codable, Equatable, Identifiable, Sendable {
    var number: Int
    var title: String
    var chunks: [PicoScriptChunk]
    var pageID: String?
    var id: Int { number }
    init(number: Int, title: String, chunks: [PicoScriptChunk], pageID: String? = nil) {
        self.number = number; self.title = title; self.chunks = chunks; self.pageID = pageID
    }
}

enum PicoPresentationScriptError: LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct PicoPresentationScript: Codable, Equatable, Sendable {
    var version: Int
    var deckURL: String
    var deckID: String?
    var title: String
    var language: String
    var opening: [PicoScriptChunk]
    var shareIntro: [PicoScriptChunk]
    var slides: [PicoScriptSlide]
    var closing: [PicoScriptChunk]
    /// The full deck can contain unpresented appendix pages available for review.
    var deckSlideCount: Int?
    /// An explicit conclusion starts this prepared closing section, if already sharing.
    var closingStartSlide: Int?
    var totalDeckSlides: Int { deckSlideCount ?? slides.count }
    init(version: Int = 1, deckURL: String, deckID: String? = nil, title: String, language: String = "zh-CN",
         opening: [PicoScriptChunk] = [], shareIntro: [PicoScriptChunk] = [],
         slides: [PicoScriptSlide], closing: [PicoScriptChunk] = [],
         deckSlideCount: Int? = nil, closingStartSlide: Int? = nil) {
        self.version = version; self.deckURL = deckURL; self.deckID = deckID; self.title = title; self.language = language
        self.opening = opening; self.shareIntro = shareIntro; self.slides = slides; self.closing = closing
        self.deckSlideCount = deckSlideCount; self.closingStartSlide = closingStartSlide
    }
    private enum CodingKeys: String, CodingKey { case version, deckURL, deckID, title, language, opening, shareIntro, slides, closing, deckSlideCount, closingStartSlide }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        deckURL = try values.decode(String.self, forKey: .deckURL)
        deckID = try values.decodeIfPresent(String.self, forKey: .deckID)
        title = try values.decode(String.self, forKey: .title)
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "zh-CN"
        opening = try values.decodeIfPresent([PicoScriptChunk].self, forKey: .opening) ?? []
        shareIntro = try values.decodeIfPresent([PicoScriptChunk].self, forKey: .shareIntro) ?? []
        slides = try values.decode([PicoScriptSlide].self, forKey: .slides)
        closing = try values.decodeIfPresent([PicoScriptChunk].self, forKey: .closing) ?? []
        deckSlideCount = try values.decodeIfPresent(Int.self, forKey: .deckSlideCount)
        closingStartSlide = try values.decodeIfPresent(Int.self, forKey: .closingStartSlide)
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512 * 1024 else { throw PicoPresentationScriptError.invalid("演示脚本超过 512 KB，请拆分。") }
        let script = try JSONDecoder().decode(Self.self, from: data)
        try script.validate()
        return script
    }
    func validate() throws {
        func require(_ accepted: Bool, _ message: String) throws {
            if !accepted { throw PicoPresentationScriptError.invalid(message) }
        }
        try require(version == 1, "暂不支持这个演示脚本版本。")
        try require(!title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 200, "请填写 200 字符以内的演示标题。")
        try require(language.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil && language.count <= 35, "演示语言需要使用 zh-CN、en-US 等语言代码。")
        _ = try validatedDeckURL()
        if let deckID { try require(deckID.range(of: "^[A-Za-z0-9_-]{1,160}$", options: .regularExpression) != nil, "演示文档编号无效。") }
        try require((1...60).contains(slides.count), "演示需要包含 1–60 页。")
        try require((slides.count...60).contains(totalDeckSlides), "文稿总页数不能小于讲稿页数，且最多支持 60 页。")
        if let closingStartSlide { try require((1...slides.count).contains(closingStartSlide), "收尾起始页必须是已准备讲稿中的有效页码。") }
        try require(slides.map(\.number) == Array(1...slides.count), "幻灯片页码必须按顺序从 1 连续排列。")
        try require(opening.count <= 12 && shareIntro.count <= 8 && closing.count <= 8, "开场、共享介绍或收尾的段数过多。")
        for slide in slides {
            try require(!slide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && slide.title.count <= 200, "每页需要填写 200 字符以内的标题。")
            try require((1...12).contains(slide.chunks.count), "每页需要包含 1–12 个讲解段落。")
            if let pageID = slide.pageID { try require(pageID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, "幻灯片页面编号无效。") }
        }
        let chunks = opening + shareIntro + slides.flatMap(\.chunks) + closing
        try require(chunks.count <= 512, "演示脚本总段数超过 512 段，请拆分。")
        try require(Set(chunks.map(\.id)).count == chunks.count, "演示段落编号不能重复。")
        for chunk in chunks {
            if chunk.waitForExplicitContinue {
                try require(chunk.waitForReply && chunk.replyTimeoutSeconds == nil, "持续问答段落必须开启等待，并关闭静默后自动继续。")
            }
            try require(!chunk.id.isEmpty && chunk.id.utf8.count <= 128, "段落编号为空或过长。")
            try require(!chunk.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chunk.text.count <= 800 && chunk.text.utf8.count <= 4800, "每段需要包含 1–800 字符，请把长段落拆开。")
            try require(!chunk.text.unicodeScalars.contains(where: { $0.value == 0 }), "段落包含无效的空字符。")
            if let seconds = chunk.replyTimeoutSeconds { try require(seconds.isFinite && (1...120).contains(seconds), "等待回复的静默时长需为 1–120 秒，或使用 null 关闭自动继续。") }
            if let transition = chunk.replyTimeoutTransition {
                try require(!transition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && transition.count <= 240 && !transition.unicodeScalars.contains(where: { $0.value == 0 }), "静默过渡语需为 1–240 字符。")
            }
        }
        try require(chunks.reduce(0, { $0 + $1.text.count }) <= 60000 && chunks.reduce(0, { $0 + $1.text.utf8.count }) <= 240000, "演示脚本文字总量过大，请拆分。")
    }
    func validatedDeckURL() throws -> URL {
        guard deckURL.utf8.count <= 4096, let components = URLComponents(string: deckURL),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), !components.path.isEmpty, components.path != "/",
              host == "slides.zoom.us" || host.hasSuffix(".slides.zoom.us") || host.range(of: "^[a-z0-9-]+slides\\.zoom\\.us$", options: .regularExpression) != nil,
              let url = components.url else {
            throw PicoPresentationScriptError.invalid("请使用有效的 HTTPS Zoom Slides 文档链接；不支持其他网站、账号信息或自定义端口。")
        }
        return url
    }
}

enum PicoScriptPhase: String, Codable, Sendable { case opening, shareIntro, awaitingShare, slides, closing, freeChat, cancelled }
struct PicoScriptCursor: Equatable, Sendable {
    var phase: PicoScriptPhase
    var slideNumber: Int?
    var chunkIndex: Int
}
struct PicoScriptSpeech: Equatable, Sendable {
    var id: UUID
    var generation: UUID
    var chunkID: String
    var text: String
    var phase: PicoScriptPhase
    var slideNumber: Int?
    var needsTransition: Bool
    var isReplyTimeoutTransition = false
}
struct PicoScriptReplyWait: Equatable, Sendable {
    var chunkID: String
    var timeoutSeconds: TimeInterval?
    var transition: String
}
enum PicoScriptAction: Equatable, Sendable {
    case speak(PicoScriptSpeech)
    case requestShare(page: Int)
    case showSlide(page: Int)
    case waitForReply
    /// Enter free chat while retaining the shared deck and currently displayed final slide.
    case finished
}

/// Pure event-driven agenda. Text generation is never proof of playback or page visibility.
/// The caller confirms actual sharing, visible pages and playback; this type runs no timers.
struct PicoPresentationFlow: Sendable {
    let script: PicoPresentationScript
    private(set) var generation = UUID()
    private(set) var phase = PicoScriptPhase.opening
    private(set) var chunkIndex = 0
    private(set) var slideIndex = 0
    private(set) var isSharing = false
    private(set) var visibleSlide: Int?
    private(set) var waitingForReply = false
    private(set) var waitingForExplicitContinue = false
    private(set) var isPaused = false
    private(set) var isTakenOver = false
    private(set) var pending: PicoScriptSpeech?
    private(set) var answerID: UUID?
    private(set) var replyWait: PicoScriptReplyWait?
    private var needsTransition = false
    private var sharingRequested = false
    private var requestedPage: Int?
    private var waitingNoticeSent = false
    private var finishedNoticeSent = false
    private var closingPreservesVisibleSlide = false
    private var conclusionRequested = false
    var isConcluding: Bool {
        guard phase != .cancelled else { return false }
        if conclusionRequested || phase == .closing || phase == .freeChat { return true }
        return script.closingStartSlide.map { phase == .slides && script.slides[slideIndex].number >= $0 } ?? false
    }
    var canConclude: Bool {
        phase != .cancelled && !isTakenOver && !isConcluding
    }
    var cursor: PicoScriptCursor {
        PicoScriptCursor(phase: phase, slideNumber: phase == .slides ? script.slides[slideIndex].number : nil, chunkIndex: chunkIndex)
    }
    init(script: PicoPresentationScript) throws { try script.validate(); self.script = script }

    mutating func nextAction() -> PicoScriptAction? {
        guard phase != .cancelled, !isTakenOver, !isPaused, answerID == nil, pending == nil, requestedPage == nil else { return nil }
        if waitingForReply {
            guard !waitingNoticeSent else { return nil }
            waitingNoticeSent = true; return .waitForReply
        }
        while true {
            switch phase {
            case .opening:
                if chunkIndex < script.opening.count { return speech(script.opening[chunkIndex]) }
                phase = .shareIntro; chunkIndex = 0
            case .shareIntro:
                if chunkIndex < script.shareIntro.count { return speech(script.shareIntro[chunkIndex]) }
                phase = .awaitingShare; chunkIndex = 0
            case .awaitingShare:
                guard !sharingRequested else { return nil }
                sharingRequested = true; return .requestShare(page: 1)
            case .slides:
                let slide = script.slides[slideIndex]
                guard isSharing else { return nil }
                if chunkIndex >= slide.chunks.count {
                    chunkIndex = 0
                    if slideIndex + 1 < script.slides.count { slideIndex += 1 }
                    else { phase = .closing }
                    continue
                }
                if visibleSlide != slide.number { requestedPage = slide.number; return .showSlide(page: slide.number) }
                return speech(slide.chunks[chunkIndex])
            case .closing:
                let last = script.slides.last!.number
                if !closingPreservesVisibleSlide, visibleSlide != last { requestedPage = last; return .showSlide(page: last) }
                if chunkIndex < script.closing.count { return speech(script.closing[chunkIndex]) }
                phase = .freeChat; chunkIndex = 0
            case .freeChat:
                guard !finishedNoticeSent else { return nil }
                finishedNoticeSent = true; return .finished
            case .cancelled: return nil
            }
        }
    }
    private mutating func speech(_ chunk: PicoScriptChunk) -> PicoScriptAction {
        let value = PicoScriptSpeech(id: UUID(), generation: generation, chunkID: chunk.id, text: chunk.text,
            phase: phase, slideNumber: phase == .slides ? script.slides[slideIndex].number : nil, needsTransition: needsTransition)
        pending = value
        return .speak(value)
    }
    @discardableResult mutating func playbackCompleted(id: UUID, generation token: UUID) -> Bool {
        guard token == generation, !isTakenOver, !isPaused, let value = pending, value.id == id else { return false }
        if value.isReplyTimeoutTransition {
            guard waitingForReply, !waitingForExplicitContinue, replyWait != nil else { return false }
            waitingForReply = false; waitingForExplicitContinue = false; waitingNoticeSent = false; replyWait = nil
            pending = nil; needsTransition = false
            return true
        }
        let chunks: [PicoScriptChunk]
        switch phase {
        case .opening: chunks = script.opening
        case .shareIntro: chunks = script.shareIntro
        case .slides: chunks = script.slides[slideIndex].chunks
        case .closing: chunks = script.closing
        default: return false
        }
        guard chunkIndex < chunks.count, chunks[chunkIndex].id == value.chunkID else { return false }
        // An explicit wrap-up finishes into free conversation; it must not acquire a
        // new scripted wait or start another sharing/navigation sequence.
        waitingForReply = chunks[chunkIndex].waitForReply && !conclusionRequested && !(phase == .closing && closingPreservesVisibleSlide)
        waitingForExplicitContinue = waitingForReply && chunks[chunkIndex].waitForExplicitContinue
        replyWait = waitingForReply ? makeReplyWait(chunks[chunkIndex]) : nil
        waitingNoticeSent = false; chunkIndex += 1; pending = nil; needsTransition = false
        return true
    }
    @discardableResult mutating func shareConfirmed(page: Int, generation token: UUID) -> Bool {
        guard token == generation, phase == .awaitingShare, sharingRequested, page == 1, !isPaused, !isTakenOver else { return false }
        isSharing = true; visibleSlide = 1; sharingRequested = false
        phase = .slides; slideIndex = 0; chunkIndex = 0
        return true
    }
    @discardableResult mutating func slideShown(page: Int, generation token: UUID) -> Bool {
        guard token == generation, phase != .cancelled, !isTakenOver, requestedPage == page else { return false }
        visibleSlide = page; requestedPage = nil; return true
    }
    mutating func guestReplyReceived() {
        guard phase != .cancelled, !isTakenOver, waitingForReply, !waitingForExplicitContinue else { return }
        waitingForReply = false; waitingForExplicitContinue = false; waitingNoticeSent = false; replyWait = nil
    }
    /// Ordinary Q&A has its own playback token and cannot commit the presentation cursor.
    @discardableResult mutating func beginAnswer() -> UUID {
        let id = UUID()
        guard phase != .cancelled, !isTakenOver else { return id }
        if pending != nil { interrupt() }
        if phase == .slides || phase == .closing { needsTransition = true }
        answerID = id; return id
    }
    @discardableResult mutating func answerPlaybackCompleted(id: UUID) -> Bool {
        guard answerID == id, !isTakenOver, phase != .cancelled else { return false }
        answerID = nil; return true
    }
    mutating func interrupt() {
        guard phase != .cancelled, !isTakenOver else { return }
        if pending != nil { needsTransition = true }
        generation = UUID(); pending = nil; requestedPage = nil; answerID = nil
        sharingRequested = false
        // Speech which merely answers a requested greeting is not a paused agenda chunk.
        if !waitingForReply { isPaused = phase != .freeChat }
    }
    @discardableResult mutating func resume(continuePastReplyWait: Bool = false) -> UUID {
        guard phase != .cancelled else { return generation }
        if pending != nil { needsTransition = true }
        generation = UUID(); pending = nil; requestedPage = nil; sharingRequested = false
        // A deliberate "continue" releases a scripted greeting/question wait. A connection
        // recovery must keep that wait until a guest actually replies or explicitly continues.
        if continuePastReplyWait { waitingForReply = false; waitingForExplicitContinue = false; waitingNoticeSent = false; answerID = nil; replyWait = nil }
        isTakenOver = false; isPaused = false
        return generation
    }
    /// Explicitly skip to the configured closing section, or speak the legacy closing.
    /// Skipped chunks remain unplayed; an unshared deck is never opened by wrap-up.
    @discardableResult mutating func requestConclude() -> Bool {
        guard canConclude else { return false }
        generation = UUID(); pending = nil; requestedPage = nil; answerID = nil
        sharingRequested = false; waitingForReply = false; waitingForExplicitContinue = false; waitingNoticeSent = false; replyWait = nil
        isPaused = false; needsTransition = false; closingPreservesVisibleSlide = true
        conclusionRequested = true; chunkIndex = 0
        if isSharing, let start = script.closingStartSlide {
            phase = .slides; slideIndex = start - 1
        } else {
            // An early wrap-up must never start sharing or operate an unbound deck.
            phase = .closing
        }
        return true
    }
    /// The caller supplies the silence clock. The transition is a separate scoped utterance;
    /// only its actual playback releases the wait, without committing another script chunk.
    @discardableResult mutating func requestReplyTimeoutTransition() -> PicoScriptSpeech? {
        guard phase != .cancelled, phase != .freeChat, !isTakenOver, !isPaused,
              waitingForReply, !waitingForExplicitContinue, let replyWait, replyWait.timeoutSeconds != nil,
              pending == nil, answerID == nil, requestedPage == nil else { return nil }
        let value = PicoScriptSpeech(id: UUID(), generation: generation,
            chunkID: "reply-timeout-" + replyWait.chunkID, text: replyWait.transition,
            phase: phase, slideNumber: phase == .slides ? script.slides[slideIndex].number : nil,
            needsTransition: false, isReplyTimeoutTransition: true)
        pending = value
        return value
    }
    private func makeReplyWait(_ chunk: PicoScriptChunk) -> PicoScriptReplyWait {
        let language = script.language.lowercased().split(separator: "-").first.map(String.init) ?? "en"
        let defaults = ["zh": "那我先往下介绍，你随时可以打断我。", "en": "I'll keep going. Feel free to jump in.",
                        "ja": "では、このまま続けますね。いつでも声をかけてください。",
                        "es": "Voy a seguir. Puedes interrumpirme cuando quieras.",
                        "de": "Dann mache ich weiter. Du kannst mich jederzeit unterbrechen."]
        return PicoScriptReplyWait(chunkID: chunk.id, timeoutSeconds: chunk.replyTimeoutSeconds,
            transition: chunk.replyTimeoutTransition ?? defaults[language] ?? defaults["en"]!)
    }
    /// Guest navigation is a review request, never permission to skip unfinished main speech.
    @discardableResult mutating func jumpToSlide(_ number: Int) throws -> PicoScriptAction {
        guard phase != .cancelled, !isTakenOver, isSharing,
              (1...script.totalDeckSlides).contains(number) else {
            throw PicoPresentationScriptError.invalid("当前无法回看这一页；请先确认共享，并选择文档中存在的页码。")
        }
        if pending != nil { needsTransition = true }
        generation = UUID(); pending = nil; requestedPage = number; sharingRequested = false
        if phase != .freeChat { isPaused = true }
        return .showSlide(page: number)
    }
    mutating func takeOver() {
        guard phase != .cancelled else { return }
        if pending != nil { needsTransition = true }
        generation = UUID(); pending = nil; requestedPage = nil; answerID = nil
        sharingRequested = false; isTakenOver = true; isPaused = true
    }
    mutating func cancel() {
        generation = UUID(); pending = nil; requestedPage = nil; answerID = nil
        sharingRequested = false; isPaused = true; phase = .cancelled
    }
}
