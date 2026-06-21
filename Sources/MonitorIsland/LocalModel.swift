import Foundation

// Local-model name discovery via the LM Studio OpenAI-compatible server.
enum LocalModel {
    // GET http://localhost:1234/v1/models with a short timeout; return the first id.
    static func lmStudioModelName(timeout: TimeInterval = 0.3) -> String? {
        guard let url = URL(string: "http://localhost:1234/v1/models") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: String? = nil
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            // OpenAI/LM Studio shape: {"data":[{"id":...}]}.
            if let arr = obj["data"] as? [[String: Any]], let id = arr.first?["id"] as? String {
                result = cleanName(id)
            // llama.cpp/Ollama shape: {"models":[{"model"/"name":...}]}.
            } else if let arr = obj["models"] as? [[String: Any]],
                      let id = (arr.first?["model"] ?? arr.first?["name"]) as? String {
                result = cleanName(id)
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.2)
        return result
    }

    static func cleanName(_ id: String) -> String {
        var s = (id as NSString).lastPathComponent
        for suffix in [".gguf", ".mlx"] { if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) } }
        return s
    }
}
