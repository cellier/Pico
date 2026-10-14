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
var missing=false
let recognition = CloudRecognition(credentials: { throw URLError(.userAuthenticationRequired) })
recognition.transcribe(URL(fileURLWithPath:"/no-audio")){result in if case .failure = result {missing=true}}
let deadline = Date().addingTimeInterval(2)
while !missing && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
precondition(missing)
print("PASS: bilingual request, product vocabulary, exact transcript, malformed response and missing credentials")
}}
