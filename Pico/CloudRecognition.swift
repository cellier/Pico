import Foundation

enum RecognitionProtocol {
    static let model = "qwen-audio-3.1-asr-flash"
    static func request(audio: Data, endpoint: URL, key: String) throws -> URLRequest {
        guard audio.count > 44, audio.count < 2_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        let words = ["Pico", "Telos", "Zoom", "Zoom Slides", "PowerPoint", "Figma", "Copilot", "DeepSeek", "百炼"]
        let body: [String: Any] = ["model": model, "input": ["messages": [
            ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64," + audio.base64EncodedString()]]]]
        ]], "parameters": ["format": "wav", "sample_rate": "16000", "language_hints": ["zh", "en"],
                              "vocabulary": Dictionary(uniqueKeysWithValues: words.map { ($0, 3) })]]
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    static func text(_ data: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? [String: Any], let text = output["text"] as? String else { throw URLError(.cannotParseResponse) }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= 3000 else { throw URLError(.dataLengthExceedsMaximum) }
        return result
    }
}

final class CloudRecognition: NSObject, URLSessionTaskDelegate {
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var generation = UUID()
    private let credentials: () throws -> BailianCredentials.Account
    init(credentials: @escaping () throws -> BailianCredentials.Account = { try BailianCredentials.load() }) {
        self.credentials = credentials
        super.init()
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; session?.invalidateAndCancel(); session = nil }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func transcribe(_ file: URL, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let token = generation
        let readCredentials = credentials
        // Security and file reads must not stall Pico's release gesture or animation.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared = Result<URLRequest, Error> {
                let account = try readCredentials()
                guard let host = account.config.endpoint?.host,
                      let endpoint = URL(string: "https://" + host + "/api/v1/services/aigc/multimodal-generation/generation") else {
                    throw URLError(.userAuthenticationRequired)
                }
                return try RecognitionProtocol.request(audio: Data(contentsOf: file), endpoint: endpoint, key: account.apiKey)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch prepared {
                case .success(let request): self.start(request, token: token, completion: completion)
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }
    private func start(_ request: URLRequest, token: UUID, completion: @escaping (Result<String, Error>) -> Void) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 40
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            task = session.dataTask(with: request) { [weak self] data, response, error in
                let result: Result<String, Error>
                if let error { result = .failure(error) }
                else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    result = .failure(NSError(domain: "PicoASR", code: http.statusCode))
                } else { result = Result { try RecognitionProtocol.text(data ?? Data()) } }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.task = nil; self.session?.finishTasksAndInvalidate(); self.session = nil
                    completion(result)
                }
            }
            task?.resume()
    }
}
