import Foundation

@MainActor enum PicoGreetingHandoffTests {
    static func run() async throws {
        let greetingAnswers = [
            "还行吧", "还行。", "挺好", "还不错", "今天还好", "今天还不错。",
            "不忙", "我不忙。", "嗯，还行吧。", "I'm good", "I'm fine.",
            "Not bad.", "I'm not busy."
        ]
        for text in greetingAnswers {
            precondition(PicoMeetingController.isSimpleGreetingAnswer(text),
                         "a complete greeting answer should use the single application-owned handoff: \(text)")
        }

        // Matching an entire utterance matters: a greeting can prefix a genuine question,
        // a pause, or another request which must retain its ordinary conversation turn.
        let substantiveTurns = [
            "", " ", "今天还好，你呢？", "还行，Pico 能帮我做什么？",
            "还不错，不过你能先解释一下吗？", "不忙，为什么要共享？",
            "挺好，先别讲。", "我很忙，暂停一下。", "我不忙，但先别继续。",
            "还行吧，等一下。", "你说的是‘还行吧’吗？", "如果我说不忙，你会怎么做？",
            "I'm good, how are you?", "I'm fine, but what can Pico do?",
            "Not bad, please pause.", "I'm not busy, but don't start yet.",
            "I'm not fine.", "I'm busy.", "Fine, can I ask a question?"
        ]
        for text in substantiveTurns {
            precondition(!PicoMeetingController.isSimpleGreetingAnswer(text),
                         "questions, mixed requests and quoted examples must not lose their ordinary answer: \(text)")
        }

        try await PicoMeetingController.verifyGreetingHandoff()
        print("PASS: simple greeting handoff uses one scoped transition; real questions, pauses, late ASR and unrelated live turns retain their conversation boundaries")
    }
}
