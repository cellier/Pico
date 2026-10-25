import Foundation
import ApplicationServices

@main struct ZoomSlidesDriverTests {
    static func main() async throws {
        try await run()
        print("PASS: Zoom Slides driver parsing and controlled operation regressions")
    }
    static func run() async throws {
        try attributeCollectionFixtures()
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
        try await attributeCollectionActionFixtures(target: target)
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
        precondition(!ZoomSlidesDriver.permitsMissingAttribute("AXDescription", error: .failure), "failed descriptors require a separate semantic-evidence policy")
        for error in [AXError.failure, .notImplemented, .illegalArgument] {
            for role in ["AXTextArea", "AXStaticText", "AXUnknown", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXImage"] {
                for advertised in [Optional<[String]>.none, ["AXRole", "AXChildren", "AXTitle", "AXDescription"]] {
                    precondition(ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: error, role: role, supportedAttributes: advertised, childrenRead: true, identityRead: true), "passive metadata recovery depends on field responsibilities, not the enclosing window")
                    precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXTitle", error: error, role: role, supportedAttributes: advertised, childrenRead: true, identityRead: true), "a primary semantic title cannot be discarded using the passive-description policy")
                }
                for (children, identity, identifier, hasURL, presentation) in [(false, true, "", false, false), (true, false, "", false, false), (true, true, "identity", false, false), (true, true, "", true, false), (true, true, "", false, true)] {
                    precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: error, role: role, supportedAttributes: ["AXDescription"], childrenRead: children, identityRead: identity, identifier: identifier, hasURL: hasURL, presentationContent: presentation), "unread structure, identity and live document proof remain strict")
                }
            }
            for role in ["AXButton", "AXCell", "AXRow", "AXWindow", "AXWebArea", "AXHeading", "AXCheckBox", "AXRadioButton", "AXTextField", "unknown"] {
                precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: error, role: role, supportedAttributes: ["AXDescription"], childrenRead: true, identityRead: true), "hiding a control or proof label must not turn ambiguous evidence into a unique candidate")
            }
        }
        precondition(ZoomSlidesDriver.permitsMissingDescriptor("AXTitle", error: .failure, role: "AXImage", supportedAttributes: ["AXRole", "AXDescription"]), "a successful public names query independently proves a missing descriptor")
        for error in [AXError.apiDisabled, .cannotComplete, .invalidUIElement] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: error, role: "AXTextArea", supportedAttributes: [], childrenRead: true, identityRead: true), "permission, stale-object and messaging failures cannot be discarded using optional metadata")
        }
        for attribute in ["AXRole", "AXChildren", "AXURL", "AXEnabled", "AXSelected", "AXIdentifier", "AXValue"] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor(attribute, error: .failure, role: "AXTextArea", supportedAttributes: [], childrenRead: true, identityRead: true), "descriptor recovery must not weaken tree, document, control or state evidence")
        }
        for windowType in ["share-picker", "permission-probe", "share-permissions"] {
            for role in ["AXTextArea", "AXList"] {
                for identityRead in [false, true] {
                    precondition(ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: role, supportedAttributes: ["AXDescription"], childrenRead: true, identityRead: identityRead, identifier: "opaque-zoom-metadata-id", windowType: windowType), "supplemental share-flow metadata must not depend on an empty or readable opaque identifier")
                }
                for identity in ["MeetingTopBarInfoButton", "zm.meeting.window.main", "zm.meeting.window.leave", "zm.meeting.window.leave.confirm"] {
                    precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: role, supportedAttributes: ["AXDescription"], childrenRead: true, identityRead: true, identifier: identity, windowType: windowType), "known meeting identity/exit proof cannot become optional metadata")
                }
                for (children, hasURL, presentation) in [(false, false, false), (true, true, false), (true, false, true)] {
                    precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: role, supportedAttributes: ["AXDescription"], childrenRead: children, identityRead: false, identifier: "opaque-zoom-metadata-id", hasURL: hasURL, presentationContent: presentation, windowType: windowType), "share-flow metadata recovery must not weaken structure or document evidence")
                }
            }
            for role in ["AXButton", "AXCell", "AXRow", "AXRadioButton", "AXCheckBox", "AXWindow", "AXWebArea"] {
                precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: role, supportedAttributes: ["AXDescription"], childrenRead: true, identityRead: false, windowType: windowType), "the sharing metadata exception must not include controls, candidate rows or document/window proof")
            }
        }
        for windowType in ["main-meeting", "meeting-exit-dialog", "unknown"] {
            precondition(!ZoomSlidesDriver.permitsMissingDescriptor("AXDescription", error: .failure, role: "AXList", supportedAttributes: ["AXDescription"], childrenRead: true, identityRead: true, identifier: "", windowType: windowType), "AXList descriptor recovery must stay confined to sharing metadata contexts")
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

        for openingReportsFailure in [false, true] {
            let fourTabs = FakeZoomSlidesAXTransport(); fourTabs.fourTabPicker = true
            if openingReportsFailure { fourTabs.failAfterEffect = [.press("share")] }
            let modernDriver = ZoomSlidesDriver(transport: fourTabs, timeout: 1, pollInterval: 1_000_000, operationBudget: 3)
            let modernShared = try await modernDriver.startSharing(target: target)
            precondition(modernShared.sharing == .active && modernShared.currentSlide == 1 && modernShared.totalSlides == 6 && modernShared.documentID == target.documentID,
                         "four-tab sharing must reach independently verified target document and audience page proof")
            precondition(fourTabs.actions == [.press("share"), .press("files-outer"), .select("doc-row"), .press("file-share"), .press("present"), .press("persistent"), .press("confirm")],
                         "the observed four-tab layout must press only outer Files, select the unique target and retain permission checks; an after-effect opening failure must not cause a second Share click")
            let modernReadback = try await modernDriver.readStatus()
            precondition(modernReadback.sharing == .active && modernReadback.documentID == target.documentID && modernReadback.currentSlide == 1)
            precondition(fourTabs.presentOnly && !fourTabs.persistentAccess,
                         "adapting the picker tabs must not change Present-only or persistent access safeguards")
        }

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
    /// Real public-AX decoding and BFS, backed only by deterministic in-memory
    /// replies. These do not open a meeting or contact the placeholder AX PIDs.
    static func attributeCollectionFixtures() throws {
        precondition(AXError.failure.rawValue == -25200)
        for singlePath in [false, true] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let state = try fixture.collect()
            precondition(state.complete && state.windows.count == 1)
            let nodes = state.windows[0].nodes
            precondition(nodes.count == 7 && nodes.filter { $0.role == "AXUnknown" }.count == 1,
                         "the affected structural node must remain in the complete snapshot")
            let unknown = nodes.first { $0.role == "AXUnknown" }!
            let child = nodes.first { $0.title == "Next" }!
            precondition(unknown.description.isEmpty && child.parentID == unknown.id,
                         "omitting a failed optional description must retain its actual descendants")
            precondition(ZoomSlidesDriver.isMeeting(state.windows[0]), "existing semantic meeting proof must survive")
            precondition(fixture.reads.contains("2:single:AXDescription") && fixture.reads.contains("2:names"))
            precondition(fixture.advertisedDescription, "fixture must reproduce Zoom advertising the failing descriptor")
            precondition(fixture.reads.firstIndex(of: "2:single:AXDescription")! > fixture.reads.firstIndex(of: "2:batch")!)
            if singlePath {
                for prerequisite in ["AXChildren", "AXIdentifier", "AXURL"] {
                    precondition(fixture.reads.firstIndex(of: "2:single:" + prerequisite)! < fixture.reads.firstIndex(of: "2:single:AXDescription")!,
                                 "the single fallback must establish structure and identity before descriptor recovery")
                }
            }
            // Standard absent identity evidence is valid; a tolerated generic
            // identity failure is not proof that the object has no identity.
            let noIdentity = AttributeCollectionFixture(singlePath: singlePath)
            noIdentity.fields[2].removeValue(forKey: "AXIdentifier")
            noIdentity.fields[2].removeValue(forKey: "AXURL")
            let withoutIdentity = try noIdentity.collect()
            precondition(withoutIdentity.windows[0].nodes.count == 7)
            let recoveredChildren = AttributeCollectionFixture(singlePath: singlePath)
            recoveredChildren.failures[2]?["AXChildren"] = .failure
            let recovered = try recoveredChildren.collect()
            precondition(recovered.windows[0].nodes.count == 7,
                         "a successful public children count/array recovery is structural evidence")
            precondition(recoveredChildren.reads.contains("2:count") && recoveredChildren.reads.contains("2:values"))
            for name in ["AXRole", "AXChildren", "AXURL", "AXEnabled", "AXSelected", "AXTitle"] {
                let broken = AttributeCollectionFixture(singlePath: singlePath)
                broken.failures[2]?[name] = .failure
                if name == "AXChildren" { broken.countError = .failure }
                try broken.expectReadFailure(attribute: name, code: .failure)
            }
            for name in ["AXRole", "AXChildren", "AXURL", "AXIdentifier", "AXEnabled", "AXSelected", "AXDescription"] {
                for error in [AXError.apiDisabled, .cannotComplete, .invalidUIElement] {
                    let broken = AttributeCollectionFixture(singlePath: singlePath)
                    broken.failures[2]?[name] = error
                    try broken.expectReadFailure(attribute: name, code: error)
                }
            }
            let identityFailure = AttributeCollectionFixture(singlePath: singlePath)
            identityFailure.failures[2]?["AXIdentifier"] = .failure
            try identityFailure.expectReadFailure(attribute: "AXDescription", code: .failure)
            for (field, value) in [("AXIdentifier", "MeetingTopBarInfoButton"), ("AXURL", "https://slides.zoom.us/p/test/60000")] {
                let identified = AttributeCollectionFixture(singlePath: singlePath)
                identified.fields[2][field] = value
                try identified.expectReadFailure(attribute: "AXDescription", code: .failure)
            }
            for role in ["AXButton", "AXCell", "AXRow", "AXWebArea", "AXWindow", "AXHeading", "AXCheckBox", "AXRadioButton", "AXTextField"] {
                let otherRole = AttributeCollectionFixture(singlePath: singlePath)
                otherRole.fields[2]["AXRole"] = role
                try otherRole.expectReadFailure(attribute: "AXDescription", code: .failure)
            }
            let otherParent = AttributeCollectionFixture(singlePath: singlePath)
            otherParent.fields[1]["AXRole"] = "AXGroup"
            let otherParentState = try otherParent.collect()
            precondition(otherParentState.windows[0].nodes.count == 7, "a passive node remains passive under a different layout parent")
            let otherWindow = AttributeCollectionFixture(singlePath: singlePath)
            otherWindow.fields[0]["AXTitle"] = "Share screen window"
            otherWindow.fields[0]["AXIdentifier"] = "picker"
            let otherWindowState = try otherWindow.collect()
            precondition(otherWindowState.windows[0].nodes.count == 7, "passive metadata recovery does not depend on the window kind")
            for role in ["AXTextArea", "AXStaticText", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXImage"] {
                let passive = AttributeCollectionFixture(singlePath: singlePath)
                passive.fields[2]["AXRole"] = role
                let passiveState = try passive.collect()
                precondition(passiveState.windows[0].nodes.count == 7, "passive description failures must retain all descendants")
            }
            let documentContent = AttributeCollectionFixture(singlePath: singlePath)
            documentContent.fields[1]["AXRole"] = "AXWebArea"
            try documentContent.expectReadFailure(attribute: "AXDescription", code: .failure)
            let nestedDocumentContent = AttributeCollectionFixture(singlePath: singlePath)
            nestedDocumentContent.fields[1]["AXRole"] = "AXWebArea"
            let layout = nestedDocumentContent.handles.count
            nestedDocumentContent.handles.append(AXUIElementCreateApplication(pid_t(900_000 + layout)))
            nestedDocumentContent.fields.append(["AXRole": "AXGroup", "AXChildren": [nestedDocumentContent.handles[2]]])
            nestedDocumentContent.fields[1]["AXChildren"] = [nestedDocumentContent.handles[layout]]
            try nestedDocumentContent.expectReadFailure(attribute: "AXDescription", code: .failure)
            let header = AttributeCollectionFixture(singlePath: singlePath)
            header.failures[0] = ["AXDescription": .failure]
            try header.expectReadFailure(attribute: "AXDescription", code: .failure)
            let malformedIdentity = AttributeCollectionFixture(singlePath: singlePath)
            malformedIdentity.fields[2]["AXIdentifier"] = NSNumber(value: 42)
            try malformedIdentity.expectReadFailure(attribute: "AXIdentifier", code: .illegalArgument)
            try permissionProbeFixtures(singlePath: singlePath)
            try listDescriptorFixtures(singlePath: singlePath)
            try sharingTextFixtures(singlePath: singlePath)
            let cancelled = AttributeCollectionFixture(singlePath: singlePath)
            var stop = false
            cancelled.onNames = { stop = true }
            do {
                _ = try cancelled.collect(cancelled: { if stop { throw ZoomSlidesDriver.Failure.cancelled } })
                preconditionFailure("cancellation must discard a partial snapshot")
            } catch let error as ZoomSlidesDriver.Failure { precondition(error == .cancelled) }
            precondition(!cancelled.reads.contains("6:batch"), "cancellation must prevent descendant reads")
            let expired = AttributeCollectionFixture(singlePath: singlePath)
            do { _ = try expired.collect(deadline: Date().addingTimeInterval(-1)); preconditionFailure("expired read accepted") }
            catch let error as ZoomSlidesDriver.Failure { if case .timedOut = error {} else { throw error } }
            precondition(expired.reads.isEmpty)
        }
    }
    static func listDescriptorFixtures(singlePath: Bool) throws {
        for question in [false, true] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let indices = fixture.addUntitledListWindow(question: question)
            let state = try fixture.collect()
            precondition(state.complete && state.windows.count == (question ? 2 : 1))
            precondition(fixture.reads.contains("\(indices.list):single:AXDescription") && fixture.reads.contains("\(indices.list):names"),
                         "reproduce the real permission-probe node 2 AXList public descriptor failure, including advertised AXDescription")
            precondition(fixture.reads.contains("\(indices.child):batch"), "a failed supplemental list description must never hide its child subtree")
            if question {
                let nodes = state.windows[1].nodes
                let list = nodes.first { $0.role == "AXList" }!
                precondition(list.description.isEmpty && nodes.contains { $0.parentID == list.id && $0.value == "How do you want to share?" },
                             "the permission question must come from preserved successfully read child text, not inferred missing metadata")
            }
        }
        for role in ["AXButton", "AXCell", "AXRow"] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let indices = fixture.addUntitledListWindow(question: true)
            fixture.fields[indices.list]["AXRole"] = role
            try fixture.expectReadFailure(attribute: "AXDescription", code: .failure)
        }
        let brokenTree = AttributeCollectionFixture(singlePath: singlePath)
        let brokenList = brokenTree.addUntitledListWindow(question: true).list
        brokenTree.failures[brokenList]?["AXChildren"] = .failure; brokenTree.countError = .failure
        try brokenTree.expectReadFailure(attribute: "AXChildren", code: .failure)
        let linked = AttributeCollectionFixture(singlePath: singlePath)
        let linkedList = linked.addUntitledListWindow(question: true).list
        linked.fields[linkedList]["AXURL"] = "https://slides.zoom.us/p/identity/60000"
        try linked.expectReadFailure(attribute: "AXDescription", code: .failure)
        let unreadURL = AttributeCollectionFixture(singlePath: singlePath)
        let unreadList = unreadURL.addUntitledListWindow(question: true).list
        unreadURL.failures[unreadList]?["AXURL"] = .failure
        try unreadURL.expectReadFailure(attribute: "AXURL", code: .failure)
        let exit = AttributeCollectionFixture(singlePath: singlePath)
        _ = exit.addUntitledListWindow(question: true)
        exit.fields[exit.windows.last!]["AXIdentifier"] = "zm.meeting.window.leave"
        do { _ = try exit.collect(includeExitDialogs: true); preconditionFailure("an exit-dialog list must not inherit sharing metadata recovery") }
        catch let issue as ZoomSlidesSnapshotReadIssue {
            precondition(issue.code == .failure && issue.failure.localizedDescription.contains("AXDescription") && issue.failure.localizedDescription.contains("windowType meeting-exit-dialog"))
        }
    }
    static func permissionProbeFixtures(singlePath: Bool) throws {
        for code in [AXError.failure, .notImplemented, .illegalArgument] {
            for childrenAbsent in [false, true] {
                for question in [false, true] {
                    let fixture = AttributeCollectionFixture(singlePath: singlePath)
                    let text = fixture.addUntitledWindow(question: question, descriptorError: code)
                    if childrenAbsent { fixture.fields[text].removeValue(forKey: "AXChildren") }
                    let state = try fixture.collect()
                    precondition(state.complete && state.windows.count == (question ? 2 : 1), "missing passive metadata must neither abort an unrelated popover nor invent a permission question")
                    precondition(ZoomSlidesDriver.isMeeting(state.windows[0]))
                    precondition(fixture.reads.contains("\(text):single:AXDescription") && fixture.reads.contains("\(text):names"), "reproduce the failed public single read even when Zoom advertises AXDescription")
                    if question {
                        precondition(state.windows[1].nodes.contains { $0.role == "AXTextArea" && $0.value == "How do you want to share?" }, "only successfully read exact question text may classify the permission pane")
                    }
                }
            }
        }
        // Batch null, standard noValue and standard unsupported leaf children all
        // establish an empty leaf; generic tree errors do not establish absence.
        for absence in [AXError.noValue, .attributeUnsupported] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let text = fixture.addUntitledWindow(question: false)
            fixture.failures[text]?["AXChildren"] = absence
            fixture.failures[text]?["AXIdentifier"] = absence
            fixture.failures[text]?["AXURL"] = absence
            let state = try fixture.collect()
            precondition(state.complete && state.windows.count == 1)
        }
        for name in ["AXRole", "AXChildren", "AXURL", "AXIdentifier", "AXDescription"] {
            for error in [AXError.apiDisabled, .cannotComplete, .invalidUIElement] {
                let fixture = AttributeCollectionFixture(singlePath: singlePath)
                let text = fixture.addUntitledWindow(question: false)
                fixture.failures[text]?[name] = error
                do { _ = try fixture.collect(); preconditionFailure("permission or messaging error was swallowed in permission-probe") }
                catch let issue as ZoomSlidesSnapshotReadIssue {
                    precondition(issue.code == error && issue.failure.localizedDescription.contains(name))
                    precondition(issue.failure.localizedDescription.contains("windowType permission-probe，node 2，parentRole AXWindow"), "cover the exact reported failing location")
                }
            }
        }
        let identity = AttributeCollectionFixture(singlePath: singlePath)
        let identifiedText = identity.addUntitledWindow(question: false)
        identity.fields[identifiedText]["AXIdentifier"] = "opaque-text-identifier"
        let identifiedState = try identity.collect()
        precondition(identifiedState.windows.count == 1, "an opaque text identifier does not turn an unrelated popover into a permission pane")
        let linkedIdentity = AttributeCollectionFixture(singlePath: singlePath)
        let linkedText = linkedIdentity.addUntitledWindow(question: false)
        linkedIdentity.fields[linkedText]["AXURL"] = "https://slides.zoom.us/p/identity/60000"
        try linkedIdentity.expectReadFailure(attribute: "AXDescription", code: .failure)
        let uncertainIdentity = AttributeCollectionFixture(singlePath: singlePath)
        let text = uncertainIdentity.addUntitledWindow(question: false)
        uncertainIdentity.failures[text]?["AXIdentifier"] = .failure
        let uncertainState = try uncertainIdentity.collect()
        precondition(uncertainState.windows.count == 1, "an optional identifier failure must not make unrelated supplemental text fatal")
        let uncertainChildren = AttributeCollectionFixture(singlePath: singlePath)
        let child = uncertainChildren.addUntitledWindow(question: false)
        uncertainChildren.failures[child]?["AXChildren"] = .failure
        uncertainChildren.countError = .failure
        try uncertainChildren.expectReadFailure(attribute: "AXChildren", code: .failure)
        let uncertainURL = AttributeCollectionFixture(singlePath: singlePath)
        let linked = uncertainURL.addUntitledWindow(question: false)
        uncertainURL.failures[linked]?["AXURL"] = .failure
        try uncertainURL.expectReadFailure(attribute: "AXURL", code: .failure)
    }
    static func sharingTextFixtures(singlePath: Bool) throws {
        for identifierMode in ["opaque", "generic-failure", "absent"] {
            for childrenAbsent in [false, true] {
                for emptyURL in [false, true] {
                    let fixture = AttributeCollectionFixture(singlePath: singlePath)
                    let picker = fixture.addSharePicker()
                    switch identifierMode {
                    case "generic-failure": fixture.failures[picker.text]?["AXIdentifier"] = .failure
                    case "absent": fixture.fields[picker.text].removeValue(forKey: "AXIdentifier")
                    default: break
                    }
                    if childrenAbsent { fixture.fields[picker.text].removeValue(forKey: "AXChildren") }
                    if emptyURL {
                        fixture.fields[picker.text]["AXURL"] = ""
                        fixture.failures[picker.text]?.removeValue(forKey: "AXURL")
                    }
                    let state = try fixture.collect()
                    let window = state.windows.first { $0.title == "Share screen window" }!
                    let text = window.nodes.first { $0.role == "AXTextArea" }!
                    let parent = window.nodes.first { $0.id == text.parentID }!
                    precondition(state.complete && parent.role == "AXGroup" && text.description.isEmpty)
                    precondition(text.title == "Share picker help" && text.value == "Choose a file to present", "successful primary text must survive supplemental-description recovery")
                    precondition(text.identifier == (identifierMode == "opaque" ? "opaque-zoom-share-text" : ""), "keep a successful opaque identity without inventing one after a failed read")
                    if emptyURL { precondition(text.url == "", "exercise an actual successful empty URL, independently of standard unsupported URL reads") }
                    if !childrenAbsent {
                        precondition(window.nodes.contains { $0.parentID == text.id && $0.value == "Selecting a file does not begin sharing" }, "the observed AXTextArea has one actual child; the failed metadata must not hide it")
                    }
                    precondition(window.nodes.contains { $0.role == "AXCell" && $0.description.hasPrefix("Slides, Synthetic Meeting Presentation,") }, "a repaired text node must retain the complete target-file subtree")
                }
            }
        }
        for field in ["AXURL", "AXChildren"] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let picker = fixture.addSharePicker()
            fixture.failures[picker.text]?[field] = .failure
            if field == "AXChildren" { fixture.countError = .failure }
            try fixture.expectReadFailure(attribute: field, code: .failure)
        }
        for role in ["AXButton", "AXRow", "AXCell", "AXWebArea"] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let picker = fixture.addSharePicker()
            fixture.fields[picker.text]["AXRole"] = role
            try fixture.expectReadFailure(attribute: "AXDescription", code: .failure)
        }
        for url in ["https://slides.zoom.us/p/other/60000" as Any, NSNumber(value: 42)] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let picker = fixture.addSharePicker()
            fixture.fields[picker.text]["AXURL"] = url
            fixture.failures[picker.text]?.removeValue(forKey: "AXURL")
            try fixture.expectReadFailure(attribute: "AXDescription", code: .failure)
        }
        let presentation = AttributeCollectionFixture(singlePath: singlePath)
        let picker = presentation.addSharePicker()
        presentation.fields[picker.group]["AXRole"] = "AXWebArea"
        try presentation.expectReadFailure(attribute: "AXDescription", code: .failure)
        for identity in ["MeetingTopBarInfoButton", "zm.meeting.window.main", "zm.meeting.window.leave.confirm"] {
            let fixture = AttributeCollectionFixture(singlePath: singlePath)
            let picker = fixture.addSharePicker()
            fixture.fields[picker.text]["AXIdentifier"] = identity
            try fixture.expectReadFailure(attribute: "AXDescription", code: .failure)
        }
        let exitProfile = AttributeCollectionFixture(singlePath: singlePath)
        let exitPicker = exitProfile.addSharePicker()
        exitProfile.failures[exitPicker.text]?["AXIdentifier"] = .failure
        let exitState = try exitProfile.collect(includeExitDialogs: true)
        precondition(exitState.complete && exitState.windows.contains { $0.title == "Share screen window" && $0.nodes.contains { $0.value == "Selecting a file does not begin sharing" } }, "the exit profile must retain all sharing help children despite the same optional metadata failure")
        let unrelatedExitPopover = AttributeCollectionFixture(singlePath: singlePath)
        let popoverText = unrelatedExitPopover.addUntitledWindow(question: false)
        unrelatedExitPopover.failures[popoverText]?["AXIdentifier"] = .failure
        let popoverState = try unrelatedExitPopover.collect(includeExitDialogs: true)
        precondition(popoverState.complete && popoverState.windows.count == 1, "an unrelated help popover must not prevent leaving the bound meeting")
        let strictExit = AttributeCollectionFixture(singlePath: singlePath)
        let hostText = strictExit.addSharePicker()
        strictExit.fields[hostText.window]["AXTitle"] = ""
        strictExit.fields[hostText.window]["AXIdentifier"] = "zm.meeting.window.leave"
        strictExit.failures[hostText.text]?["AXIdentifier"] = .failure
        do {
            _ = try strictExit.collect(includeExitDialogs: true)
            preconditionFailure("actual exit-dialog and host-handoff text must remain strict")
        } catch let issue as ZoomSlidesSnapshotReadIssue {
            precondition(issue.code == .failure && issue.failure.localizedDescription.contains("AXDescription"))
        }
    }
    static func attributeCollectionActionFixtures(target: ZoomSlidesDriver.Target) async throws {
        for duplicateRows in [false, true] {
            let transport = CollectedPickerTransport(duplicateRows: duplicateRows)
            let driver = ZoomSlidesDriver(transport: transport, timeout: 0.05, pollInterval: 1_000_000, operationBudget: 0.2)
            _ = try await driver.preflight(target: target)
            if duplicateRows {
                do { _ = try await driver.startSharing(target: target); preconditionFailure("duplicate collected rows must not authorize sharing") }
                catch let failure as ZoomSlidesDriver.Failure { if case .unavailable = failure {} else { throw failure } }
                precondition(transport.base.actions == [.press("share"), .key("switch", 124)], "duplicate target rows must dispatch neither row selection nor a footer share")
            } else {
                let snapshot = try await driver.startSharing(target: target)
                precondition(snapshot.sharing == .active && snapshot.currentSlide == 1)
                precondition(transport.base.actions.contains(.select("doc-row")) && transport.base.actions.contains(.press("file-share")), "the actual repaired collector snapshot must retain the correct target row and selected footer")
            }
        }
        for question in [false, true] {
            let fixture = AttributeCollectionFixture(singlePath: false)
            _ = fixture.addUntitledWindow(question: question)
            let transport = CollectedSnapshotTransport(state: try fixture.collect())
            let driver = ZoomSlidesDriver(transport: transport, timeout: 0.03, pollInterval: 1_000_000, operationBudget: 0.03)
            _ = try await driver.preflight(target: target)
            do { _ = try await driver.startSharing(target: target); preconditionFailure("incomplete or unrelated UI cannot authorize sharing") }
            catch let failure as ZoomSlidesDriver.Failure { if case .unavailable = failure {} else { throw failure } }
            precondition(transport.actions.isEmpty, "neither an unrecognized popover nor an incomplete permission question can cause any click")
        }
        // Two action controls with identical successful primary labels remain
        // ambiguous. A failed secondary description cannot hide either candidate.
        let ambiguous = AttributeCollectionFixture(singlePath: false)
        ambiguous.fields[2]["AXRole"] = "AXButton"
        ambiguous.fields[2]["AXTitle"] = "Share"
        ambiguous.fields[6]["AXTitle"] = "Share"
        try ambiguous.expectReadFailure(attribute: "AXDescription", code: .failure)
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
    var fourTabPicker = false
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
                .init(id: "picker-root", role: "AXWindow", description: "Share screen window")])
            if fourTabPicker {
                picker.nodes.append(.init(id: "four-tabs", role: "AXTabGroup", parentID: "picker-root"))
                for (index, label) in ["Screens", "Windows", "Files", "Other"].enumerated() {
                    let prefix = label.lowercased(), description = "\(label) Tab, \(index + 1) of 4"
                    let selected = stage == .pickerScreens ? index == 0 : index == 2
                    picker.nodes.append(.init(id: prefix + "-outer", role: "AXRadioButton", description: description,
                                              value: selected ? "on" : "off", parentID: "four-tabs"))
                    picker.nodes.append(.init(id: prefix + "-inner", role: "AXRadioButton", description: description,
                                              value: selected ? "on" : "off", parentID: prefix + "-outer"))
                }
            } else {
                picker.nodes.append(.init(id: "switch", role: "AXTabGroup", description: "Switch", value: stage == .pickerScreens ? "Screens, 1 of 3" : "Files, 2 of 3"))
            }
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
        case .press("files-outer"):
            precondition(fourTabPicker && stage == .pickerScreens); stage = .pickerFiles
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

/// Placeholder handles are only identities. All data and errors, including the
/// SDK's actual .axError AXValue representation, come from this injected client.
private final class AttributeCollectionFixture {
    var handles = (0..<7).map { AXUIElementCreateApplication(pid_t(900_000 + $0)) }
    var windows = [0]
    var fields: [[String: Any]]
    var failures: [Int: [String: AXError]] = [2: ["AXDescription": .failure]]
    var reads: [String] = []
    var advertisedDescription = false
    var countError: AXError?
    var onNames: (() -> Void)?
    let singlePath: Bool
    init(singlePath: Bool) {
        self.singlePath = singlePath
        fields = [
            ["AXRole": "AXWindow", "AXTitle": "Zoom Meeting", "AXIdentifier": "zm.meeting.window.main"],
            ["AXRole": "AXScrollArea"],
            ["AXRole": "AXUnknown", "AXIdentifier": ""],
            ["AXRole": "AXButton", "AXTitle": "Leave"],
            ["AXRole": "AXButton", "AXTitle": "Mute my audio"],
            ["AXRole": "AXButton", "AXTitle": "Participants"],
            ["AXRole": "AXButton", "AXTitle": "Next"]]
        for index in fields.indices { fields[index]["AXChildren"] = [AXUIElement]() }
        fields[0]["AXChildren"] = [handles[1], handles[3], handles[4], handles[5]]
        fields[1]["AXChildren"] = [handles[2]]
        fields[2]["AXChildren"] = [handles[6]]
    }
    func index(_ element: AXUIElement) -> Int { handles.firstIndex { CFEqual($0, element) }! }
    @discardableResult func addUntitledWindow(question: Bool, descriptorError: AXError = .failure) -> Int {
        let window = handles.count, text = window + 1
        handles.append(AXUIElementCreateApplication(pid_t(900_000 + window)))
        handles.append(AXUIElementCreateApplication(pid_t(900_000 + text)))
        fields.append(["AXRole": "AXWindow", "AXTitle": "", "AXIdentifier": "unrelated-popover", "AXChildren": [handles[text]]])
        fields.append(["AXRole": "AXTextArea", "AXValue": question ? "How do you want to share?" : "Unrelated notes", "AXChildren": [AXUIElement]()])
        failures[text] = ["AXDescription": descriptorError]
        windows.append(window)
        return text
    }
    func addUntitledListWindow(question: Bool) -> (list: Int, child: Int) {
        let list = addUntitledWindow(question: false)
        fields[list]["AXRole"] = "AXList"
        fields[list]["AXIdentifier"] = "opaque-zoom-list"
        fields[list].removeValue(forKey: "AXValue")
        let child = handles.count
        handles.append(AXUIElementCreateApplication(pid_t(900_000 + child)))
        fields.append(["AXRole": "AXStaticText", "AXValue": question ? "How do you want to share?" : "Unrelated list entry", "AXChildren": [AXUIElement]()])
        fields[list]["AXChildren"] = [handles[child]]
        return (list, child)
    }
    /// Matches the real share-picker failure: AXGroup > AXTextArea, one child,
    /// advertised failing AXDescription and an unsupported AXURL. Tests also fail
    /// the advertised AXIdentifier, exactly as in the captured live read.
    func addSharePicker(files: Bool = true, selected: Bool = false, duplicateRows: Bool = false) -> (window: Int, group: Int, text: Int) {
        func append(_ values: [String: Any]) -> Int {
            let index = handles.count
            handles.append(AXUIElementCreateApplication(pid_t(900_000 + index)))
            fields.append(values)
            return index
        }
        let window = append(["AXRole": "AXWindow", "AXTitle": "Share screen window"])
        let group = append(["AXRole": "AXGroup"])
        let text = append(["AXRole": "AXTextArea", "AXTitle": "Share picker help", "AXValue": "Choose a file to present", "AXIdentifier": "opaque-zoom-share-text"])
        let child = append(["AXRole": "AXStaticText", "AXValue": "Selecting a file does not begin sharing", "AXChildren": [AXUIElement]()])
        let tab = append(["AXRole": "AXTabGroup", "AXDescription": "Switch", "AXValue": files ? "Files, 2 of 3" : "Screens, 1 of 3", "AXChildren": [AXUIElement]()])
        fields[window]["AXChildren"] = [handles[group], handles[tab]]
        fields[group]["AXChildren"] = [handles[text]]
        fields[text]["AXChildren"] = [handles[child]]
        failures[text] = ["AXDescription": .failure, "AXURL": .attributeUnsupported]
        if files {
            for ordinal in 0..<(duplicateRows ? 2 : 1) {
                let row = append(["AXRole": "AXRow"])
                let cell = append(["AXRole": "AXCell", "AXDescription": "Slides, Synthetic Meeting Presentation, owner \(ordinal), 7 minutes ago, \(ordinal + 1) of 50", "AXChildren": [AXUIElement]()])
                fields[row]["AXChildren"] = [handles[cell]]
                fields[window]["AXChildren"] = (fields[window]["AXChildren"] as! [AXUIElement]) + [handles[row]]
            }
            if selected {
                let footer = append(["AXRole": "AXButton", "AXTitle": "Share - Synthetic Meeting Presentation", "AXChildren": [AXUIElement]()])
                fields[window]["AXChildren"] = (fields[window]["AXChildren"] as! [AXUIElement]) + [handles[footer]]
            }
        }
        windows.append(window)
        return (window, group, text)
    }
    func encoded(_ error: AXError) -> AXValue {
        var code = error
        return AXValueCreate(.axError, &code)!
    }
    var client: ZoomSlidesAXReadClient {
        ZoomSlidesAXReadClient(multiple: { [self] element, names in
            let index = self.index(element); reads.append("\(index):batch")
            if singlePath { return (.cannotComplete, nil) }
            let result: [Any] = names.map { name in
                if let error = failures[index]?[name] { return encoded(error) }
                return fields[index][name] ?? kCFNull!
            }
            return (.success, result as CFArray)
        }, single: { [self] element, name in
            let index = self.index(element); reads.append("\(index):single:\(name)")
            if let error = failures[index]?[name] { return (error, nil) }
            guard let value = fields[index][name] else { return (.noValue, nil) }
            return (.success, value as CFTypeRef)
        }, names: { [self] element in
            let index = self.index(element); reads.append("\(index):names")
            let names = Array(Set(fields[index].keys).union(failures[index]?.keys.map { $0 } ?? []))
            advertisedDescription = names.contains("AXDescription")
            onNames?()
            return (.success, names as CFArray)
        }, count: { [self] element, name in
            let index = self.index(element); reads.append("\(index):count")
            if let countError { return (countError, 0) }
            return (.success, (fields[index][name] as? [AXUIElement])?.count ?? 0)
        }, values: { [self] element, name, count in
            let index = self.index(element); reads.append("\(index):values")
            let children = fields[index][name] as! [AXUIElement]
            precondition(children.count == count)
            return (.success, children as CFArray)
        }, timeout: { _, _ in })
    }
    func collect(deadline: Date = Date().addingTimeInterval(2), includeExitDialogs: Bool = false, cancelled: @escaping () throws -> Void = {}) throws -> ZoomSlidesAXState {
        try ZoomSlidesSystemAXTransport(includeExitDialogs: includeExitDialogs, readClient: client).collectWindows(windows.map { handles[$0] }, pid: 42, deadline: deadline, cancelled: cancelled)
    }
    func expectReadFailure(attribute: String, code: AXError) throws {
        do { _ = try collect(); preconditionFailure("expected failure for \(attribute)") }
        catch let issue as ZoomSlidesSnapshotReadIssue {
            precondition(issue.code == code && issue.failure.localizedDescription.contains(attribute),
                         "the real collector must preserve the failed field and SDK error")
        }
    }
}

/// Only the picker is replaced, using the real attribute collector with the
/// captured failure pattern. Dispatch remains an in-memory state machine.
private final class CollectedPickerTransport: ZoomSlidesAXTransport, @unchecked Sendable {
    let base = FakeZoomSlidesAXTransport()
    let duplicateRows: Bool
    private var pickerNodes: [ZoomSlidesAXNode] = []
    init(duplicateRows: Bool) { self.duplicateRows = duplicateRows }
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState {
        var state = try base.read(pid: pid, deadline: deadline, cancelled: cancelled)
        guard base.stage == .pickerScreens || base.stage == .pickerFiles else { return state }
        let fixture = AttributeCollectionFixture(singlePath: base.stage == .pickerFiles)
        let picker = fixture.addSharePicker(files: base.stage == .pickerFiles, selected: base.selectedFile, duplicateRows: duplicateRows)
        fixture.failures[picker.text]?["AXIdentifier"] = .failure
        var collected = try fixture.collect().windows.first { $0.title == "Share screen window" }!
        collected.id = "picker"
        pickerNodes = collected.nodes
        state.windows.removeAll { $0.id == "picker" }
        state.windows.append(collected)
        return state
    }
    func perform(_ action: ZoomSlidesAXAction, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws {
        let translated: ZoomSlidesAXAction
        switch action {
        case .select(let id) where pickerNodes.contains(where: { $0.id == id && $0.role == "AXRow" }): translated = .select("doc-row")
        case .key(let id, let key) where pickerNodes.contains(where: { $0.id == id && $0.role == "AXTabGroup" }): translated = .key("switch", key)
        case .press(let id) where pickerNodes.contains(where: { $0.id == id && $0.role == "AXButton" && $0.title == "Share - Synthetic Meeting Presentation" }): translated = .press("file-share")
        default: translated = action
        }
        try base.perform(translated, pid: pid, deadline: deadline, cancelled: cancelled)
    }
}

/// Runs actor-level semantic/action guards against the real collector's result.
/// Dispatch is recorded only; no accessibility action or remote process is used.
private final class CollectedSnapshotTransport: ZoomSlidesAXTransport, @unchecked Sendable {
    let state: ZoomSlidesAXState
    var actions: [ZoomSlidesAXAction] = []
    init(state: ZoomSlidesAXState) { self.state = state }
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState { try cancelled(); return state }
    func perform(_ action: ZoomSlidesAXAction, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws {
        try cancelled(); actions.append(action)
        throw ZoomSlidesDriver.Failure.unavailable("Synthetic snapshot must not dispatch actions")
    }
}
