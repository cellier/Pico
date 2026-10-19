import Foundation
import Combine

@MainActor enum PicoScriptControllerTests {
    static func run() throws {
        try PicoMeetingController.verifyScriptedRecovery()
        try PicoMeetingController.verifyPausedScriptAnswer()
        try PicoMeetingController.verifySilentResumeCallbackOrdering()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-script-controller-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = PicoMeetingController(dataDir: directory) { _ in }
        var preparationChanges = 0
        let observation = controller.objectWillChange.sink { preparationChanges += 1 }
        controller.preparation.draft.present = true
        precondition(preparationChanges > 0, "preparation changes must immediately refresh parent controls")
        withExtendedLifetime(observation) {}
        let script = PicoPresentationScript(deckURL: "https://slides.zoom.us/p/synthetic/10000", title: "Synthetic",
            opening: [.init(text: "Synthetic greeting.")], slides: [.init(number: 1, title: "Synthetic page", chunks: [.init(text: "Synthetic fact.")])])
        try verifyLateSilentResume(script: script, directory: directory)
        try controller.scripted.configure(script); controller.scripted.start()
        controller.handlePresentationInput("我能问一个问题吗？")
        precondition(controller.scripted.waitingForQuestion)
        controller.handlePresentationInput("嗯，可以啊。")
        precondition(controller.scripted.waitingForQuestion, "acknowledgements must not release a permission-only hold")
        controller.handlePresentationInput("我想问，你为什么这么做？")
        precondition(!controller.scripted.waitingForQuestion && !controller.scripted.isPaused)
        controller.handlePresentationInput("我有一个问题。")
        precondition(controller.scripted.waitingForQuestion)
        controller.handlePresentationInput("我想问，支持哪些语言？")
        precondition(!controller.scripted.waitingForQuestion, "a question outside a small keyword list must still release the hold")
        controller.handlePresentationInput("不要继续，等一下。")
        precondition(controller.scripted.isPaused)
        controller.handlePresentationInput("你是什么？")
        precondition(controller.scripted.isPaused, "a substantive question must not revoke an explicit pause")
        controller.handlePresentationInput("那你继续介绍吧。")
        precondition(!controller.scripted.isPaused)
        let closing = controller.applyPresentationControl("conclude")
        precondition(closing.contains("\"scripted_closing\":true") && controller.scripted.currentPhase == .closing)
        let closingCursor = controller.scripted.cursor
        _ = controller.applyPresentationControl("conclude")
        precondition(controller.scripted.cursor == closingCursor, "a duplicate wrap-up must not restart the closing")
        controller.scripted.cancel(); controller.shutdown()

        let legacy = Data(#"{"background":"Saved background","goal":"Saved goal","present":true,"materials":[],"outline":"One\nTwo"}"#.utf8)
        var preparation = try JSONDecoder().decode(PicoMeetingPreparation.self, from: legacy)
        precondition(preparation.presentationScript == nil && preparation.sections.count == 2)
        preparation.presentationScript = script
        let restored = try JSONDecoder().decode(PicoMeetingPreparation.self, from: JSONEncoder().encode(preparation))
        precondition(restored.presentationScript == script && restored.goal == "Saved goal")
        precondition(restored.context.contains("Synthetic fact.") && restored.context.contains("only an application-scoped turn"))
        precondition(!restored.context.contains("Synthetic greeting."), "Q&A references must not include opening speech or stage commands")
        precondition(PicoMeetingController.isSimpleContinuation("哦不忙你继续。"))
        precondition(PicoMeetingController.isSimpleContinuation("我不忙，你继续吧。"))
        precondition(!PicoMeetingController.isSimpleContinuation("不要继续"))
        precondition(!PicoMeetingController.isSimpleContinuation("为什么要继续讲这个？"))
        print("PASS: controller distinguishes permission-only interruption, actual questions, explicit pause and resume; old preparations round-trip with new script")
    }

    private static func verifyLateSilentResume(script: PicoPresentationScript, directory: URL) throws {
        let controller = PicoMeetingController(dataDir: directory.appendingPathComponent("late-silent-resume")) { _ in }
        defer { controller.scripted.cancel(); controller.shutdown() }
        func startAfterAppliedResume() throws {
            try controller.scripted.configure(script); controller.scripted.start()
            let applied = controller.applyPresentationControl("resume")
            precondition(applied.contains("\"applied\":true"))
        }
        let mistranscribed = "不好你继续"
        precondition(!PicoMeetingController.isSimpleContinuation(mistranscribed), "fixture must reproduce an ASR transcript outside the local continuation whitelist")
        try startAfterAppliedResume()
        controller.handlePresentationInput(mistranscribed)
        precondition(controller.scripted.waitingForAnswerPlayback, "without an exact completed-control marker, ordinary guest input must still wait for its real answer")

        try startAfterAppliedResume()
        let cursor = controller.scripted.cursor
        controller.handlePresentationInput(mistranscribed, silentResumeCompleted: true)
        precondition(!controller.scripted.waitingForAnswerPlayback && !controller.scripted.waitingForQuestion && !controller.scripted.isPaused,
                     "late ASR for an already applied silent resume must not invent an answer playback barrier that can never complete")
        precondition(controller.scripted.cursor == cursor, "the control transcript must not commit or skip any unheard script chunk")

        for text in ["不要继续，等一下。", "先别讲了。", "pause please"] {
            try startAfterAppliedResume()
            controller.handlePresentationInput(text, silentResumeCompleted: true)
            precondition(controller.scripted.isPaused && !controller.scripted.waitingForQuestion,
                         "an explicit pause must override a completed-resume marker")
        }
        for text in ["我能问一个问题吗？", "我打断你一下，可以吗？", "Can I ask a question?"] {
            try startAfterAppliedResume()
            controller.handlePresentationInput(text, silentResumeCompleted: true)
            precondition(controller.scripted.waitingForQuestion, "permission to ask is a real hold even when a silent-resume marker is present")
            controller.handlePresentationInput("嗯，可以啊。")
            precondition(controller.scripted.waitingForQuestion, "a permission hold still waits for the substantive question")
        }
        try startAfterAppliedResume()
        controller.handlePresentationInput("我想问，支持哪些语言？")
        precondition(controller.scripted.waitingForAnswerPlayback, "unmarked genuine questions must retain normal Q&A playback gating")

        let outline = PicoMeetingController(dataDir: directory.appendingPathComponent("outline-silent-resume")) { _ in }
        defer { outline.shutdown() }
        _ = outline.applyPresentationControl("pause")
        outline.handlePresentationInput(mistranscribed, silentResumeCompleted: true)
        precondition(!outline.presentationPaused, "the legacy outline must also preserve an applied silent resume despite late ASR variation")
        outline.handlePresentationInput("不要继续，等一下。", silentResumeCompleted: true)
        precondition(outline.presentationPaused, "legacy outline pause must override the marker")
        _ = outline.applyPresentationControl("resume")
        outline.handlePresentationInput("我能问一个问题吗？", silentResumeCompleted: true)
        precondition(outline.presentationPaused, "legacy outline permission hold must override the marker")
        print("PASS: exact silent-resume markers reject phantom Q&A waits while explicit pause, permission holds and real questions keep priority")
    }
}
