import Foundation
import ApplicationServices

@main struct ZoomSlidesDriverTests {
    static func main() async throws {
        try await run()
        print("PASS: Zoom Slides driver parsing and controlled operation regressions")
    }
    static func run() async throws {
        // Model CFEqual-equivalent wrappers with deliberate hash collisions. A UI
        // accessibility structure is a graph: children may repeat or point upward.
        final class GraphNode {
            let identity: Int
            var children: [GraphNode] = []
            init(_ identity: Int) { self.identity = identity }
        }
        let graphRoot = GraphNode(0), left = GraphNode(1), right = GraphNode(2), sharedNode = GraphNode(3), sharedWrapper = GraphNode(3)
        graphRoot.children = [left, right, left]
        left.children = [sharedNode, graphRoot]
        right.children = [sharedWrapper, sharedNode]
        sharedNode.children = [left, sharedNode]
        sharedWrapper.children = [right]
        var seen = ZoomSlidesIdentitySet<GraphNode>(hash: { _ in 7 }, equal: { $0.identity == $1.identity })
        var graphQueue = [graphRoot], firstParents: [Int: Int] = [:], graphCursor = 0
        _ = seen.insert(graphRoot)
        while graphCursor < graphQueue.count {
            let current = graphQueue[graphCursor]; graphCursor += 1
            for child in current.children where seen.insert(child) { graphQueue.append(child); firstParents[child.identity] = current.identity }
        }
        precondition(seen.count == 4 && graphQueue.map(\.identity) == [0, 1, 2, 3], "dedup must handle cycles, shared children, equivalent wrappers and hash collisions")
        precondition(firstParents[3] == 1, "the first parent path must be retained")
        for _ in 0..<2000 { precondition(!seen.insert(sharedWrapper)) }
        precondition(seen.count == 4)

        let target = ZoomSlidesDriver.Target(url: URL(string: "https://dg01slides.zoom.us/p/synthetic-deck/60000?from=slides")!, title: "Synthetic Meeting Presentation", totalSlides: 6)
        precondition(target.documentID == "synthetic-deck")
        for url in ["http://dg01slides.zoom.us/p/deck/60000", "https://zoom.us.attacker.test/p/deck/60000", "https://slides.zoom.us.attacker.test/p/deck/60000", "https://user:pass@dg01slides.zoom.us/p/deck/60000", "https://dg01slides.zoom.us/not-a-deck/60000"] {
            precondition(ZoomSlidesDriver.documentID(URL(string: url)!) == nil, "invalid or credential-bearing targets must be rejected")
        }
        for (label, current, total) in [("Slide 1 / 6", 1, 6), ("Slide 6 of 6", 6, 6), ("第 2 页 / 6 页", 2, 6)] {
            let counter = ZoomSlidesDriver.slideCounter(label)
            precondition(counter?.current == current && counter?.total == total)
        }
        for label in ["1 / 6", "Participants 1 of 6", "Slide 0 / 6", "Slide 7 / 6", "Slide 2 / 0", "Slide 60000", "meeting 1 / 6"] {
            precondition(ZoomSlidesDriver.slideCounter(label) == nil, "unlabelled or impossible counters are not page evidence")
        }
        let first = ZoomSlidesAXNode(id: "observed-now", role: "AXButton", title: " next ")
        precondition(first.named(["Next"]) && !first.named(["Previous"]))
        precondition(!ZoomSlidesAXNode(id: "unrelated", role: "AXButton", title: "next meeting").named(["next"]), "substring matches must not navigate the wrong control")
        for label in ["Share screen window", "Select a window or an application that you want to share", "Select a window or application"] {
            precondition(ZoomSlidesDriver.isSharePicker(label), "picker semantics must work in either AXTitle or AXDescription")
        }
        precondition(!ZoomSlidesDriver.isSharePicker("My Notes"))
        precondition(ZoomSlidesDriver.windowKind(title: "", description: "Select a window or an application", identifier: "") == "share-picker")
        precondition(ZoomSlidesDriver.windowKind(title: "Zoom Meeting", description: "", identifier: "zm.meeting.window.main") == "main-meeting")
        for title in ["Zoom Workplace", "My Notes", "Meeting info", "Share - unrelated document", ""] {
            precondition(ZoomSlidesDriver.windowKind(title: title, description: "", identifier: "unrelated-window") == nil, "unknown windows must not inherit share-picker classification")
        }
        precondition(ZoomSlidesDriver.windowKind(title: "", description: "", identifier: "zm.meeting.window.leave") == nil, "the Slides-only transport must not include exit dialogs")
        precondition(ZoomSlidesDriver.windowKind(title: "", description: "", identifier: "zm.meeting.window.leave", includeExitDialogs: true) == "meeting-exit-dialog", "the exit driver profile must retain its observed dialog")
        precondition(ZoomSlidesDriver.windowKind(title: "", description: "", identifier: "zm.meeting.window.leavemeeting-unknown", includeExitDialogs: true) == nil)
        precondition(ZoomSlidesDriver.singleReadOrder(["AXTitle", "AXRole", "AXChildren", "AXValue", "AXRole"]) == ["AXRole", "AXChildren", "AXTitle", "AXValue"], "batch fallback must establish role/children before optional fields without duplicate reads")
        precondition(ZoomSlidesDriver.singleReadOrder(["AXTitle", "AXIdentifier"]) == ["AXRole", "AXTitle", "AXIdentifier"], "header fallback still reads an explicit role first")
        let context = ZoomSlidesDriver.readContextLabel(windowType: "main-meeting", node: 42, parentRole: "AXGroup")
        precondition(context.contains("main-meeting") && context.contains("42") && context.contains("AXGroup"))
        let scrubbed = ZoomSlidesDriver.readContextLabel(windowType: "private content", node: -10, parentRole: "private document text")
        precondition(!scrubbed.contains("private") && scrubbed.contains("unknown"), "diagnostic locations must contain only safe types, counters and roles")
        let hitDiagnostic = ZoomSlidesDriver.hitTestDiagnostic(pid: 123, bundle: "local.original.sprout", hitRole: "AXWindow", targetRole: "AXButton")
        precondition(hitDiagnostic.contains("123") && hitDiagnostic.contains("local.original.sprout") && hitDiagnostic.contains("AXWindow") && hitDiagnostic.contains("AXButton"))
        let unsafeHit = ZoomSlidesDriver.hitTestDiagnostic(pid: nil, bundle: "private window title\nsecret", hitRole: "private document text", targetRole: "AXButton")
        precondition(!unsafeHit.contains("private") && !unsafeHit.contains("secret") && unsafeHit.contains("unknown"), "hit diagnostics must not expose app content or unsanitized fields")
        precondition(ZoomSlidesDriver.permitsMissingAttribute("AXHelp", error: .attributeUnsupported))
        precondition(ZoomSlidesDriver.permitsMissingAttribute("AXValue", error: .illegalArgument))
        precondition(ZoomSlidesDriver.permitsMissingAttribute("AXIdentifier", error: .illegalArgument))
        precondition(ZoomSlidesDriver.permitsMissingAttribute("AXHelp", error: .notImplemented))
        precondition(ZoomSlidesDriver.permitsMissingAttribute("AXIdentifier", error: .failure))
        precondition(ZoomSlidesDriver.permitsMissingAttribute("AXChildren", error: .noValue), "leaf nodes may omit children")
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXRole", error: .noValue), "missing roles cannot authorize semantic actions")
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXChildren", error: .cannotComplete), "communication failures are not leaf nodes")
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXChildren", error: .illegalArgument))
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXURL", error: .illegalArgument), "document URL proof cannot be silently discarded")
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXHelp", error: .cannotComplete), "do not swallow all optional-field communication errors")
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXValue", error: .apiDisabled), "permission errors must never be swallowed")
        precondition(AXError.failure.rawValue == -25200 && AXError.attributeUnsupported.rawValue == -25205, "generic failure must not be mislabeled as unsupported")
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXDescription", error: .failure), "descriptor failures remain strict outside the separate evidence/role policy")
        for advertised in [Optional<[String]>.none, ["AXRole", "AXChildren", "AXTitle", "AXDescription"]] {
            precondition(ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: "AXTextArea", windowType: "share-picker", supportedAttributes: advertised), "observed picker AXTextArea.Description -25200 may omit only this non-action descriptor after single-read failure")
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXTitle", error: .failure, role: "AXTextArea", windowType: "share-picker", supportedAttributes: advertised), "the observed exception must not silently expand to every descriptor")
        }
        for role in ["AXButton", "AXCell", "AXRow", "AXWindow", "AXWebArea", "AXHeading", "AXGroup", "unknown"] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: role, windowType: "share-picker", supportedAttributes: ["AXDescription"]), "errors on action, identity or container proof must remain failures")
        }
        for kind in ["main-meeting", "share-permissions", "permission-probe", "meeting-exit-dialog", "unknown"] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: "AXTextArea", windowType: kind, supportedAttributes: nil), "the observed picker exception cannot authorize another window context")
        }
        precondition(ZoomSlidesDriver.permitsMissingDescriptor("AXTitle", error: .failure, role: "AXImage", windowType: "main-meeting", supportedAttributes: ["AXRole", "AXDescription"]), "a successful public names query independently proves a missing optional descriptor")
        for error in [AXError.apiDisabled, .cannotComplete, .invalidUIElement] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: error, role: "AXTextArea", windowType: "share-picker", supportedAttributes: []), "permission, stale-object and messaging failures cannot be discarded using optional metadata")
        }
        for attribute in ["AXRole", "AXChildren", "AXURL", "AXEnabled", "AXSelected", "AXIdentifier", "AXValue"] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor(attribute, error: .failure, role: "AXTextArea", windowType: "share-picker", supportedAttributes: []), "descriptor recovery must not weaken tree, document, control or state evidence")
        }
        precondition(ZoomSlidesDriver.permitsUnimplementedLeafChildren(role: "AXStaticText", singleError: .failure, countError: .failure))
        precondition(ZoomSlidesDriver.permitsUnimplementedLeafChildren(role: "AXButton", singleError: .notImplemented, countError: .failure))
        for role in ["AXWindow", "AXWebArea", "AXGroup", "AXUnknown", ""] {
            precondition(!ZoomSlidesDriver.permitsUnimplementedLeafChildren(role: role, singleError: .failure, countError: .failure), "container/unknown failures must not hide children")
        }
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement] {
            precondition(!ZoomSlidesDriver.permitsUnimplementedLeafChildren(role: "AXImage", singleError: error, countError: .failure))
            precondition(!ZoomSlidesDriver.permitsUnimplementedLeafChildren(role: "AXImage", singleError: .failure, countError: error))
        }
        for error in [AXError.actionUnsupported, .notImplemented, .failure] { precondition(ZoomSlidesDriver.permitsClickFallback(error)) }
        for error in [AXError.apiDisabled, .cannotComplete, .invalidUIElement, .illegalArgument, .attributeUnsupported] {
            precondition(!ZoomSlidesDriver.permitsClickFallback(error), "do not turn permission, stale-element or communication failures into mouse clicks")
        }
        for action in [ZoomSlidesAXAction.press("share"), .select("doc-row")] {
            precondition(ZoomSlidesDriver.uncertainActionNeedsReadback(action, error: .cannotComplete))
            precondition(!ZoomSlidesDriver.permitsClickFallback(.cannotComplete), "uncertain dispatch must await readback instead of issuing a second click")
            precondition(!ZoomSlidesDriver.uncertainActionNeedsReadback(action, error: .apiDisabled))
        }
        for action in [ZoomSlidesAXAction.key("switch", 124), .setValue("field", "test")] {
            precondition(!ZoomSlidesDriver.uncertainActionNeedsReadback(action, error: .cannotComplete), "uncertain key/focus operations must still reject")
        }
        for error in [AXError.cannotComplete, .failure, .notImplemented] { precondition(ZoomSlidesDriver.permitsWindowReadRetry(error), "modal read failures may receive bounded read-only retries") }
        for error in [AXError.apiDisabled, .invalidUIElement, .illegalArgument] { precondition(!ZoomSlidesDriver.permitsWindowReadRetry(error), "window retries must not conceal permission or invalid-object errors") }
        var snapshotAttempts = 0
        let rebuilt = try ZoomSlidesSnapshotReader.read(deadline: Date().addingTimeInterval(1), cancelled: {}) { () throws -> String in
            snapshotAttempts += 1
            if snapshotAttempts < 3 { throw ZoomSlidesSnapshotReadIssue(failure: .unavailable("AXMultipleAttributes AXError -25204"), code: .cannotComplete) }
            return "complete snapshot"
        }
        precondition(rebuilt == "complete snapshot" && snapshotAttempts == 3, "a transient node read must rebuild and return only a complete later snapshot")
        var staleSnapshots = 0
        let replaced = try ZoomSlidesSnapshotReader.read(deadline: Date().addingTimeInterval(1), cancelled: {}) { () throws -> String in
            staleSnapshots += 1
            if staleSnapshots == 1 { throw ZoomSlidesSnapshotReadIssue(failure: .unavailable("AXMultipleAttributes AXError -25202"), code: .invalidUIElement) }
            return "fresh handles only"
        }
        precondition(replaced == "fresh handles only" && staleSnapshots == 2, "invalid UI objects must rebuild the complete snapshot rather than reuse stale handles")
        precondition(!ZoomSlidesDriver.permitsClickFallback(.invalidUIElement), "read-only stale-object recovery must not enable click fallback")
        precondition(!ZoomSlidesDriver.permitsSnapshotReadRetry(.apiDisabled))
        var roleFailures = 0
        do {
            _ = try ZoomSlidesSnapshotReader.read(deadline: Date().addingTimeInterval(1), cancelled: {}) { () throws -> String in
                roleFailures += 1; throw ZoomSlidesSnapshotReadIssue(failure: .unavailable("AXRole AXError -25200"), code: .failure)
            }
            preconditionFailure("critical role failure must not be ignored")
        } catch {}
        precondition(roleFailures == 1, "only transient cannotComplete/invalidUIElement can rebuild a snapshot; role failure must remain an error")
        var cancelChecks = 0, cancelledReads = 0
        do {
            _ = try ZoomSlidesSnapshotReader.read(deadline: Date().addingTimeInterval(1), cancelled: {
                cancelChecks += 1; if cancelChecks > 1 { throw ZoomSlidesDriver.Failure.cancelled }
            }) { () throws -> String in
                cancelledReads += 1; throw ZoomSlidesSnapshotReadIssue(failure: .unavailable("transient"), code: .cannotComplete)
            }
            preconditionFailure("cancel must stop a pending read retry")
        } catch let error as ZoomSlidesDriver.Failure { precondition(error == .cancelled) }
        precondition(cancelledReads == 1)
        var expiredReads = 0
        do {
            _ = try ZoomSlidesSnapshotReader.read(deadline: Date().addingTimeInterval(-1), cancelled: {}) { expiredReads += 1; return "not allowed" }
            preconditionFailure("an expired snapshot deadline must reject")
        } catch {}
        precondition(expiredReads == 0, "read retries share the original deadline")
        let meeting = ZoomSlidesAXWindow(id: "meeting-a", title: "Dedicated test", nodes: [
            .init(id: "meeting-root", role: "AXWindow", identifier: "zm.meeting.window.main"),
            .init(id: "leave", role: "AXButton", title: "Leave"),
            .init(id: "mic", role: "AXButton", title: "Mute my audio"),
            .init(id: "people", role: "AXButton", title: "Participants")])
        let state = ZoomSlidesAXState(pid: 42, windows: [meeting])
        let bound = try ZoomSlidesDriver.bindMeeting(state, title: "Dedicated test", previous: nil)
        precondition(bound.pid == 42 && bound.meetingWindow == "meeting-a")
        try expectFailure(.meetingChanged) { _ = try ZoomSlidesDriver.bindMeeting(.init(pid: 43, windows: [meeting]), title: nil, previous: bound) }
        var secondMeeting = meeting; secondMeeting.id = "meeting-b"
        try expectFailure(.ambiguousMeeting) { _ = try ZoomSlidesDriver.bindMeeting(.init(pid: 42, windows: [meeting, secondMeeting]), title: nil, previous: nil) }
        try expectFailure(.meetingChanged) { _ = try ZoomSlidesDriver.bindMeeting(.init(pid: 42, windows: [secondMeeting]), title: nil, previous: bound) }
        var incomplete = state; incomplete.complete = false
        do { _ = try ZoomSlidesDriver.bindMeeting(incomplete, title: nil, previous: nil); preconditionFailure("incomplete trees cannot authorize actions") } catch {}
        let next = ZoomSlidesAXWindow(id: "slides", title: "Slides", nodes: [first, .init(id: "text", role: "AXStaticText", title: "next")])
        let nextControl = try ZoomSlidesDriver.uniqueNode(in: [next], roles: ["AXButton"], names: ["next"])
        precondition(nextControl.id == "observed-now")
        var duplicate = next; duplicate.nodes.append(.init(id: "another-next", role: "AXButton", title: "next"))
        do { _ = try ZoomSlidesDriver.uniqueNode(in: [duplicate], roles: ["AXButton"], names: ["next"]); preconditionFailure("ambiguous buttons must not be clicked") } catch {}
        let fake = FakeZoomSlidesAXTransport()
        let driver = ZoomSlidesDriver(transport: fake, timeout: 1, pollInterval: 1_000_000)
        let ready = try await driver.preflight(target: target)
        precondition(ready.sharing == .inactive && fake.actions.isEmpty, "preflight must never share")
        let shared = try await driver.startSharing(target: target)
        precondition(shared.sharing == .active && shared.currentSlide == 1 && shared.totalSlides == 6 && shared.documentID == target.documentID)
        precondition(fake.presentOnly && !fake.persistentAccess, "share only Present and remove persistent access before confirmation")
        precondition(fake.actions.contains(.key("switch", 124)) && fake.actions.contains(.select("doc-row")))
        precondition(fake.readBudgets.allSatisfy { $0 <= 1.01 }, "each snapshot keeps its own short deadline despite the longer overall sharing budget")
        let sixth = try await driver.goToSlide(6)
        precondition(sixth.currentSlide == 6 && fake.nextPresses == 5)
        precondition(fake.hiddenEditorPage == 1, "hidden editor page must not be treated as the visible slideshow page")
        let second = try await driver.goToSlide(2)
        precondition(second.currentSlide == 2 && fake.previousPresses == 4)
        let actions = fake.actions
        _ = try await driver.startSharing(target: target)
        precondition(fake.actions == actions, "sharing the current target again must be idempotent")
        driver.cancel()
        let stillShared = try await driver.readStatus()
        precondition(stillShared.currentSlide == 2 && stillShared.sharing == .active, "cancellation must retain the shared slide")
        fake.reportedDocumentID = "another-deck"
        try await expectFailure(.documentMismatch) { _ = try await driver.readStatus() }
        fake.reportedDocumentID = target.documentID!
        fake.reportedMeetingID = "another-meeting"
        try await expectFailure(.meetingChanged) { _ = try await driver.readStatus() }

        let stalled = FakeZoomSlidesAXTransport(); stalled.stage = .presenting; stalled.noPageProgress = true
        let bounded = ZoomSlidesDriver(transport: stalled, timeout: 0.04, pollInterval: 1_000_000, operationBudget: 0.04)
        _ = try await bounded.preflight(target: target)
        do { _ = try await bounded.goToSlide(2); preconditionFailure("unchanged pages must time out") }
        catch let error as ZoomSlidesDriver.Failure { if case .timedOut = error {} else { throw error } }
        precondition(stalled.nextPresses == 1, "do not repeatedly click next while waiting for read-back")

        let held = FakeZoomSlidesAXTransport(); held.stage = .presenting; held.noPageProgress = true
        let cancellable = ZoomSlidesDriver(transport: held, timeout: 1, pollInterval: 1_000_000)
        _ = try await cancellable.preflight(target: target)
        let pending = Task { try await cancellable.goToSlide(3) }
        while held.nextPresses == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        try await expectFailure(.busy) { _ = try await cancellable.readStatus() }
        cancellable.cancel()
        try await expectFailure(.cancelled) { _ = try await pending.value }
        precondition(held.nextPresses == 1, "cancel must prevent all later navigation")
        held.noPageProgress = false
        let afterCancel = try await cancellable.goToSlide(2)
        precondition(afterCancel.currentSlide == 2, "a later explicit operation gets a fresh cancellation token")
        let changed = FakeZoomSlidesAXTransport(); changed.stage = .presenting; changed.jumpTwoPages = true
        let manual = ZoomSlidesDriver(transport: changed, timeout: 1, pollInterval: 1_000_000)
        _ = try await manual.preflight(target: target)
        do { _ = try await manual.goToSlide(6); preconditionFailure("unexpected page movement must stop") } catch {}
        precondition(changed.nextPresses == 1)
        let duplicateFile = FakeZoomSlidesAXTransport(); duplicateFile.duplicateFiles = true; duplicateFile.selectedFile = true
        let duplicateDriver = ZoomSlidesDriver(transport: duplicateFile, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        do { _ = try await duplicateDriver.startSharing(target: target); preconditionFailure("same-title documents must not be shared based only on the selected footer") } catch {}
        precondition(!duplicateFile.actions.contains(.press("file-share")) && duplicateFile.fileReads == 1, "duplicate candidates must fail immediately rather than enter the empty-list loading grace")
        let loadingFiles = FakeZoomSlidesAXTransport(); loadingFiles.emptyFileReads = 3
        let loadingDriver = ZoomSlidesDriver(transport: loadingFiles, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        let loaded = try await loadingDriver.startSharing(target: target)
        precondition(loaded.sharing == .active && loaded.documentID == target.documentID && loadingFiles.fileReads > 3,
                     "selected Files tab may precede its target row; bounded read-back must permit genuine loading")
        precondition(loadingFiles.actions.filter { $0 == .press("share") }.count == 1 && loadingFiles.actions.filter { $0 == .press("file-share") }.count == 1,
                     "waiting for list rows must not reopen or resubmit sharing")
        let absentFile = FakeZoomSlidesAXTransport(); absentFile.emptyFileReads = Int.max; absentFile.selectedFile = true
        let absentDriver = ZoomSlidesDriver(transport: absentFile, timeout: 0.03, pollInterval: 1_000_000, operationBudget: 0.03)
        do { _ = try await absentDriver.startSharing(target: target); preconditionFailure("a footer with no unique target row cannot establish file identity") } catch {}
        precondition(absentFile.fileReads > 1 && !absentFile.actions.contains(.press("file-share")), "missing candidates wait only within the original deadline and never use a same-title footer as fallback")
        let outsideRecent = FakeZoomSlidesAXTransport(); outsideRecent.emptyFileReads = Int.max
        let recentDriver = ZoomSlidesDriver(transport: outsideRecent, timeout: 1, pollInterval: 5_000_000, operationBudget: 3)
        do { _ = try await recentDriver.startSharing(target: target); preconditionFailure("a missing target must not wait for the whole sharing budget") }
        catch let error as ZoomSlidesDriver.Failure {
            if case .unavailable(let message) = error { precondition(message.contains("Zoom 近期文件列表中尚未显示目标幻灯片")) }
            else { throw error }
        }
        precondition(!outsideRecent.actions.contains(.press("file-share")), "the two-second grace cannot invent a file absent from the exposed recent list")
        let cancelledFiles = FakeZoomSlidesAXTransport(); cancelledFiles.emptyFileReads = Int.max
        let cancelledFilesDriver = ZoomSlidesDriver(transport: cancelledFiles, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        let awaitingRows = Task { try await cancelledFilesDriver.startSharing(target: target) }
        while cancelledFiles.fileReads == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        cancelledFilesDriver.cancel()
        try await expectFailure(.cancelled) { _ = try await awaitingRows.value }
        precondition(!cancelledFiles.actions.contains(.press("file-share")), "cancellation must stop the loading grace before any file mutation")
        let independentlyActive = FakeZoomSlidesAXTransport(); independentlyActive.emptyFileReads = Int.max; independentlyActive.presentAfterFileReads = 2
        let activeDriver = ZoomSlidesDriver(transport: independentlyActive, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        let activeDuringLoad = try await activeDriver.startSharing(target: target)
        precondition(activeDuringLoad.sharing == .active && activeDuringLoad.currentSlide == 1 && activeDuringLoad.documentID == target.documentID && !independentlyActive.actions.contains(.press("file-share")),
                     "a fresh same-meeting snapshot with exact live document and audience page proof may confirm sharing without repeating picker actions")
        let wrongActive = FakeZoomSlidesAXTransport(); wrongActive.emptyFileReads = Int.max; wrongActive.presentAfterFileReads = 1; wrongActive.reportedDocumentID = "other-deck"
        let wrongActiveDriver = ZoomSlidesDriver(transport: wrongActive, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        try await expectFailure(.documentMismatch) { _ = try await wrongActiveDriver.startSharing(target: target) }
        precondition(!wrongActive.actions.contains(.press("file-share")), "read-only loading recovery must not accept a different live deck")
        let transitionedDespiteErrors = FakeZoomSlidesAXTransport()
        transitionedDespiteErrors.keepPickerDuringPermissions = true
        transitionedDespiteErrors.failAfterEffect = [.press("share"), .press("file-share"), .press("present"), .press("persistent"), .press("confirm")]
        let postconditionDriver = ZoomSlidesDriver(transport: transitionedDespiteErrors, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        let confirmedTransitions = try await postconditionDriver.startSharing(target: target)
        precondition(confirmedTransitions.sharing == .active && confirmedTransitions.currentSlide == 1 && transitionedDespiteErrors.presentOnly && !transitionedDespiteErrors.persistentAccess,
                     "a failed AX reply after an owned modal transition may recover only from its actual semantic postcondition")
        for action in transitionedDespiteErrors.failAfterEffect {
            precondition(transitionedDespiteErrors.actions.filter { $0 == action }.count == 1, "semantic read-back must never dispatch the old modal button a second time")
        }
        for failedAction in [ZoomSlidesAXAction.press("share"), .press("file-share"), .press("present"), .press("persistent"), .press("confirm")] {
            let unchanged = FakeZoomSlidesAXTransport(); unchanged.failWithoutEffect = [failedAction]
            let unchangedDriver = ZoomSlidesDriver(transport: unchanged, timeout: 0.04, pollInterval: 1_000_000, operationBudget: 0.04)
            do { _ = try await unchangedDriver.startSharing(target: target); preconditionFailure("an AX failure without that action's postcondition cannot count as success") }
            catch let error as ZoomSlidesDriver.Failure { precondition(error == .unavailable("Synthetic AXPress failure"), "retain the original action failure when semantic proof never arrives") }
            precondition(unchanged.actions.filter { $0 == failedAction }.count == 1 && unchanged.stage != .presenting)
        }
        let incompletePermission = FakeZoomSlidesAXTransport(); incompletePermission.failAfterEffect = [.press("file-share")]; incompletePermission.incompletePermissionPane = true
        let incompletePermissionDriver = ZoomSlidesDriver(transport: incompletePermission, timeout: 0.04, pollInterval: 1_000_000, operationBudget: 0.04)
        do { _ = try await incompletePermissionDriver.startSharing(target: target); preconditionFailure("the permission question alone is not the footer postcondition") }
        catch let error as ZoomSlidesDriver.Failure { precondition(error == .unavailable("Synthetic AXPress failure")) }
        precondition(!incompletePermission.actions.contains(.press("present")) && !incompletePermission.actions.contains(.press("confirm")))
        let changedAfterConfirm = FakeZoomSlidesAXTransport(); changedAfterConfirm.failAfterEffect = [.press("confirm")]; changedAfterConfirm.reportedDocumentID = "different-deck"
        let changedAfterConfirmDriver = ZoomSlidesDriver(transport: changedAfterConfirm, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        try await expectFailure(.documentMismatch) { _ = try await changedAfterConfirmDriver.startSharing(target: target) }
        precondition(changedAfterConfirm.actions.filter { $0 == .press("confirm") }.count == 1)
        let cancelledAfterFooter = FakeZoomSlidesAXTransport(); cancelledAfterFooter.failAfterEffect = [.press("file-share")]
        let cancelledAfterFooterDriver = ZoomSlidesDriver(transport: cancelledAfterFooter, timeout: 1, pollInterval: 1_000_000, operationBudget: 1)
        cancelledAfterFooter.onAction = { action in if action == .press("file-share") { cancelledAfterFooterDriver.cancel() } }
        try await expectFailure(.cancelled) { _ = try await cancelledAfterFooterDriver.startSharing(target: target) }
        precondition(!cancelledAfterFooter.actions.contains(.press("present")) && !cancelledAfterFooter.actions.contains(.press("confirm")), "cancellation wins even when the expected permission modal is already visible")
        let noTransition = FakeZoomSlidesAXTransport(); noTransition.shareDoesNothing = true
        let uncertain = ZoomSlidesDriver(transport: noTransition, timeout: 0.04, pollInterval: 1_000_000, operationBudget: 0.04)
        do { _ = try await uncertain.startSharing(target: target); preconditionFailure("dispatched press alone is not sharing success") }
        catch let error as ZoomSlidesDriver.Failure { if case .timedOut = error {} else { throw error } }
        precondition(noTransition.actions.filter { $0 == .press("share") }.count == 1, "an unconfirmed dispatched press must never be repeated")
    }
    static func expectFailure(_ failure: ZoomSlidesDriver.Failure, _ operation: () throws -> Void) throws {
        do { try operation(); preconditionFailure("expected \(failure)") }
        catch let actual as ZoomSlidesDriver.Failure { precondition(actual == failure) }
    }
    static func expectFailure(_ failure: ZoomSlidesDriver.Failure, _ operation: () async throws -> Void) async throws {
        do { try await operation(); preconditionFailure("expected \(failure)") }
        catch let actual as ZoomSlidesDriver.Failure { precondition(actual == failure) }
    }
}

/// All snapshots and actions below are in-memory fixtures. No AX, event posting, meeting,
/// browser, credential, permission dialog or model is touched by this test executable.
private final class FakeZoomSlidesAXTransport: ZoomSlidesAXTransport, @unchecked Sendable {
    enum Stage { case meeting, pickerScreens, pickerFiles, permissions, presenting }
    var stage = Stage.meeting
    var actions: [ZoomSlidesAXAction] = []
    var presentOnly = false, persistentAccess = true, selectedFile = false
    var page = 1, nextPresses = 0, previousPresses = 0
    var noPageProgress = false, jumpTwoPages = false
    var shareDoesNothing = false
    var hiddenEditorPage = 1
    var duplicateFiles = false
    var emptyFileReads = 0, fileReads = 0
    var presentAfterFileReads: Int?
    var failAfterEffect: [ZoomSlidesAXAction] = [], failWithoutEffect: [ZoomSlidesAXAction] = []
    var keepPickerDuringPermissions = false, incompletePermissionPane = false
    var onAction: ((ZoomSlidesAXAction) -> Void)?
    var readBudgets: [TimeInterval] = []
    var reportedDocumentID = "synthetic-deck", reportedMeetingID = "dedicated-test"
    private let title = "Synthetic Meeting Presentation"
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState {
        try cancelled()
        readBudgets.append(deadline.timeIntervalSinceNow)
        if stage == .pickerFiles, let presentAfterFileReads, fileReads >= presentAfterFileReads { stage = .presenting }
        var meeting = ZoomSlidesAXWindow(id: "main-window", title: "Zoom Meeting", nodes: [
            .init(id: "main", role: "AXWindow", identifier: "zm.meeting.window.main"),
            .init(id: "leave", role: "AXButton", description: "End", identifier: "idleave"),
            .init(id: "mic", role: "AXButton", description: "Unmute my audio"),
            .init(id: "participants", role: "AXButton", description: "Open participants panel, closed, 1 participants"),
            .init(id: "share", role: "AXButton", description: "Share", identifier: "idshare")])
        var windows = [meeting]
        switch stage {
        case .meeting: break
        case .pickerScreens, .pickerFiles:
            var picker = ZoomSlidesAXWindow(id: "picker", title: "Select a window or an application that you want to share", nodes: [
                .init(id: "picker-root", role: "AXWindow", description: "Share screen window"),
                .init(id: "switch", role: "AXTabGroup", description: "Switch", value: stage == .pickerScreens ? "Screens, 1 of 3" : "Files, 2 of 3")])
            if stage == .pickerFiles {
                fileReads += 1
                if fileReads > emptyFileReads {
                    picker.nodes += [.init(id: "doc-row", role: "AXRow"), .init(id: "doc-cell", role: "AXCell", description: "Slides, \(title), test owner, 7 minutes ago, 1 of 50", parentID: "doc-row")]
                    if duplicateFiles { picker.nodes += [.init(id: "doc-row-2", role: "AXRow"), .init(id: "doc-cell-2", role: "AXCell", description: "Slides, \(title), another owner, 3 minutes ago, 2 of 50", parentID: "doc-row-2")] }
                }
                if selectedFile { picker.nodes.append(.init(id: "file-share", role: "AXButton", title: "Share - " + title)) }
            }
            windows.append(picker)
        case .permissions:
            if keepPickerDuringPermissions { windows.append(.init(id: "picker", title: "Share screen window", nodes: [.init(id: "picker-root", role: "AXWindow"), .init(id: "close", role: "AXButton", title: "close")])) }
            windows.append(.init(id: "permissions", title: "", nodes: [
                .init(id: "prompt", role: "AXStaticText", value: "How do you want to share?"),
                .init(id: "present", role: "AXButton", description: "Present, Present with private speaker notes. Participant can only view slides., " + (presentOnly ? "checked" : "not checked"), checked: !presentOnly),
                .init(id: "persistent", role: "AXCheckBox", title: "Allow persistent access to verified meeting participants after closing the presentation", checked: persistentAccess),
                .init(id: "confirm", role: "AXButton", description: incompletePermissionPane ? "Unrelated button" : "Share presentation")]))
        case .presenting:
            meeting.nodes += [
                .init(id: "web", role: "AXWebArea", description: title + " - Zoom Slides", url: "https://dg01slides.zoom.us/p/\(reportedDocumentID)/60000?presentOnly=true&mainMeetingID=\(reportedMeetingID)"),
                .init(id: "editor-counter", role: "AXStaticText", value: "Slide \(hiddenEditorPage) / 6", parentID: "web"),
                .init(id: "slideshow", role: "AXGroup", description: "Zoom AI Slides Slideshow - \(page)/6", parentID: "web"),
                .init(id: "counter", role: "AXButton", title: "\(page) / 6", parentID: "slideshow"),
                .init(id: "stop", role: "AXButton", title: "Stop sharing", parentID: "web"),
                .init(id: "hidden-next", role: "AXButton", title: "next", parentID: "web"),
                .init(id: "next", role: "AXButton", title: "next", enabled: page < 6, parentID: "slideshow"),
                .init(id: "previous", role: "AXButton", title: "previous", enabled: page > 1, parentID: "slideshow")]
            windows = [meeting, .init(id: "notes", title: "My Notes", nodes: [.init(id: "wrong-next", role: "AXButton", title: "next")])]
        }
        return .init(pid: 42, windows: windows)
    }
    func perform(_ action: ZoomSlidesAXAction, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws {
        try cancelled(); precondition(pid == 42); actions.append(action)
        if failWithoutEffect.contains(action) { throw ZoomSlidesDriver.Failure.unavailable("Synthetic AXPress failure") }
        switch action {
        case .press("share"): if !shareDoesNothing { stage = .pickerScreens }
        case .key("switch", 124): stage = .pickerFiles
        case .select("doc-row"): selectedFile = true
        case .press("file-share"): stage = .permissions
        case .press("present"): presentOnly = true
        case .press("persistent"): persistentAccess = false
        case .press("confirm"): precondition(presentOnly && !persistentAccess); stage = .presenting
        case .press("next"): nextPresses += 1; if !noPageProgress { page += jumpTwoPages ? 2 : 1 }
        case .press("previous"): previousPresses += 1; if !noPageProgress { page -= 1 }
        default: preconditionFailure("unexpected or non-scoped action: \(action)")
        }
        onAction?(action)
        if failAfterEffect.contains(action) { throw ZoomSlidesDriver.Failure.unavailable("Synthetic AXPress failure") }
    }
}
