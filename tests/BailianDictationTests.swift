import Foundation
@main struct BailianDictationTests {
    static func main() throws {
        let endpoint=DictationBailianAccount(region:"cn-beijing",workspace:"ws-test").endpoint!
        precondition(endpoint.host == "ws-test.cn-beijing.maas.aliyuncs.com")
        precondition(DictationBailianAccount(region:"bad",workspace:"ws-test").endpoint == nil)
        precondition(DictationBailianAccount(region:"cn-beijing",workspace:"bad/host").endpoint == nil)
        let request=try DictationRecognitionProtocol.request(audio:Data(repeating:0,count:3_840_044),endpoint:endpoint,key:"test-key")
        let value=try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any]
        let parameters=value["parameters"] as! [String:Any]
        precondition(parameters["language_hints"] as! [String] == ["zh","en"])
        let text="请打开 Zoom Slides，review 一下这个 PRD。"
        let response=try JSONSerialization.data(withJSONObject:["output":["text":text]])
        let parsed=try DictationRecognitionProtocol.text(response)
        precondition(parsed==text)
        do {_ = try DictationRecognitionProtocol.text(Data("{}".utf8));fatalError("Malformed response") }catch{}
        print("PASS: endpoint validation, full two-minute recording, bilingual hints and unchanged mixed transcript")
    }
}
