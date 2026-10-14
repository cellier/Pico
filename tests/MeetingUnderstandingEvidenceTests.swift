import Foundation

enum MeetingUnderstandingEvidenceTests {
    static func run() throws {
        var excluded = TranscriptSegment(startTime: 139.925, endTime: 141.685, speakerSource: .me,
                                         text: "Residual Pico audio must not become an owner promise.", isFinal: true)
        excluded.excludedFromEvidence = true
        let legacy = TranscriptSegment(startTime: 150, endTime: 152, speakerSource: .me,
                                       text: "I will send the reviewed draft.", isFinal: true)
        var allowed = TranscriptSegment(startTime: 160, endTime: 162, speakerSource: .others,
                                        text: "Please send the reviewed draft.", isFinal: true)
        allowed.excludedFromEvidence = false
        var session = MeetingSession(title: "Evidence boundary", locale: "mixed", processID: 0)
        session.transcript = [excluded, legacy, allowed]
        func evidence(_ segment: TranscriptSegment) -> TranscriptEvidence {
            .init(segmentID: segment.id, startTime: segment.startTime, endTime: segment.endTime, text: segment.text)
        }
        precondition(!MeetingUnderstanding.verified(evidence(excluded), in: session), "transition-contaminated speech cannot support any evidence reference")
        precondition(MeetingUnderstanding.verified(evidence(legacy), in: session), "missing flags must preserve old final evidence")
        precondition(MeetingUnderstanding.verified(evidence(allowed), in: session), "an explicit false flag must remain eligible")
        let data = try MeetingUnderstanding.analysisInput(session)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let transcript = object["transcript"] as! [[String: Any]]
        precondition(transcript.count == 2 && !String(decoding: data, as: UTF8.self).contains(excluded.text), "excluded speech must not be transmitted in the analysis payload")
        precondition(session.transcript.count == 3 && session.transcript[0].text == excluded.text && session.transcript[0].excludedFromEvidence == true,
                     "the complete raw transcript must remain unchanged")
        var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        legacyObject.removeValue(forKey: "excludedFromEvidence")
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        precondition(decoded.excludedFromEvidence == nil && decoded.text == legacy.text, "old records without the flag must decode unchanged")
        print("PASS: excluded transition speech blocked from analysis payload and evidence; raw transcript and legacy records preserved")
    }
}
