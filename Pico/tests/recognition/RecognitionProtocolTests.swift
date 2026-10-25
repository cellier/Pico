import Foundation
func L(_ a: String, _ b: String) -> String { a }
func log(_ text: String) {}
@main struct Tests {static func main() throws {
let request=try RecognitionProtocol.request(audio:Data(repeating:1,count:100),endpoint:URL(string:"https://example.invalid")!,key:"test-key")
let json=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
let parameters=json["parameters"] as! [String:Any]
precondition(parameters["language_hints"] as! [String] == ["zh","en"])
precondition((parameters["vocabulary"] as! [String:Int])["Pico"] == 3)
precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer test-key")
let mixed="Pico，帮我打开 Zoom Slides"
let data=try JSONSerialization.data(withJSONObject:["output":["text":mixed]])
let result=try RecognitionProtocol.text(data);precondition(result==mixed)
for invalid in [Data("{}".utf8),try JSONSerialization.data(withJSONObject:["output":["text":42]])] {
do {_ = try RecognitionProtocol.text(invalid);fatalError("Malformed response accepted")}catch{}}
let requestID = "40e0734d-096f-9ae3-86c1-a8c013287561"
let privateText = "Bearer sk-private-test-key; data:audio/wav;base64,PRIVATEAUDIO; private transcript"
let providerBody = try JSONSerialization.data(withJSONObject: [
    "code": "InvalidParameter", "request_id": requestID, "message": privateText,
    "input": ["transcript": privateText]
])
let providerFailure = RecognitionProtocol.serviceError(status: 400, data: providerBody)
let providerError = providerFailure as NSError
precondition(providerError.domain == "PicoASR" && providerError.code == 400)
precondition(providerError.localizedDescription == "HTTP 400; provider_code=InvalidParameter; request_id=\(requestID)")
precondition(RecognitionProtocol.diagnostic(providerFailure) == providerError.localizedDescription)
precondition(providerError.userInfo.count == 1 && !providerError.description.contains(privateText))
precondition(RecognitionProtocol.diagnostic(URLError(.badURL)) == nil)
precondition(RecognitionProtocol.diagnostic(NSError(domain: "PicoASR", code: 400, userInfo: [NSLocalizedDescriptionKey: privateText])) == nil)
for fields: [String: Any] in [
    ["code": privateText, "request_id": privateText, "message": privateText],
    ["code": "InvalidParameter.sk-secret", "request_id": "sk-12345678-1234-1234-1234-123456789012"],
    ["code": ["InvalidParameter"], "request_id": 42],
    ["code": "InvalidParameter\nBearer sk-secret", "request_id": requestID + "\n"],
    ["message": privateText]
] {
    let error = RecognitionProtocol.serviceError(status: 400, data: try JSONSerialization.data(withJSONObject: fields))
    precondition(error.localizedDescription == "HTTP 400", "Unsafe diagnostic field retained")
}
for invalid in [nil, Data("<html>private upstream failure</html>".utf8), Data(repeating: 65, count: 16_385)] {
    precondition(RecognitionProtocol.serviceError(status: 502, data: invalid).localizedDescription == "HTTP 502")
}
let oversized = try JSONSerialization.data(withJSONObject: ["code": "InvalidParameter", "message": String(repeating: "x", count: 16_385)])
precondition(RecognitionProtocol.serviceError(status: 400, data: oversized).localizedDescription == "HTTP 400")
print("PASS: bounded HTTP diagnostics retain only approved code and UUID; messages, secrets and malformed fields are discarded")
var missing=false
let recognition = CloudRecognition(credentials: { throw URLError(.userAuthenticationRequired) })
recognition.transcribe(URL(fileURLWithPath:"/no-audio")){result in if case .failure = result {missing=true}}
let deadline = Date().addingTimeInterval(2)
while !missing && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
precondition(missing)
print("PASS: bilingual request, product vocabulary, exact transcript, malformed response and missing credentials")
}}
