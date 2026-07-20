import Foundation

/// Optional AI post-processing of the raw transcript via a local OpenAI-compatible
/// LLM server. Defaults to Ollama (localhost:11434), which runs as a background
/// service and auto-loads models on demand — so no separate app must be opened.
///
/// Fails safe: any error (server down, timeout, bad response) returns the
/// original text unchanged, so dictation never breaks because AI is unavailable.
enum Corrector {
    /// Ollama's OpenAI-compatible base. (LM Studio would be :1234.)
    static let baseURL = "http://localhost:11434"

    struct Config {
        var endpoint: URL
        var model: String       // model name, e.g. "qwen2.5:7b"; "" = server default
        var timeout: TimeInterval
    }

    static func config(model: String) -> Config {
        Config(
            endpoint: URL(string: "\(baseURL)/v1/chat/completions")!,
            model: model,
            timeout: 20
        )
    }

    /// Preload a model into memory so the first real request is fast. Ollama
    /// keeps it resident for `keepAliveMinutes`. Fire-and-forget; ignores errors.
    static func loadModel(_ model: String, keepAliveMinutes: Int = 30) {
        guard !model.isEmpty else { RuntimeLog.write("loadModel skipped (empty)"); return }
        RuntimeLog.write("loadModel \(model)")
        postGenerate(model: model, keepAlive: "\(keepAliveMinutes)m")
    }

    /// Unload a model from memory immediately (frees several GB). Called when the
    /// user turns AI off, so an unused feature never keeps the model resident.
    static func unloadModel(_ model: String) {
        guard !model.isEmpty else { RuntimeLog.write("unloadModel skipped (empty)"); return }
        RuntimeLog.write("unloadModel \(model)")
        postGenerate(model: model, keepAlive: "0")
    }

    /// Low-level helper: hit /api/generate with an empty prompt just to trigger
    /// a load/unload via keep_alive. Runs on a background queue, ignores result.
    private static func postGenerate(model: String, keepAlive: String) {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return }
        let payload: [String: Any] = ["model": model, "prompt": "", "keep_alive": keepAlive]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 30
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Fetch installed model names from the server. Returns [] on any failure.
    /// Synchronous — call off the main thread.
    static func listModels() -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        let sem = DispatchSemaphore(value: 0)
        var names: [String] = []
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return }
            names = models.compactMap { $0["name"] as? String }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 5)
        return names.sorted()
    }

    /// Synchronous (blocking) reformat via the local LLM using `systemPrompt`.
    /// Call off the main thread. Returns the original text on any failure.
    static func process(_ text: String, systemPrompt: String, config: Config) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !systemPrompt.isEmpty else { return text }

        // Ollama's chat endpoint requires a model name. If none is configured
        // ("Server default"), fall back to the first installed model.
        var modelName = config.model
        if modelName.isEmpty { modelName = listModels().first ?? "" }
        guard !modelName.isEmpty else { return text }

        let body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": trimmed],
            ],
            // Low temperature: this is a formatting task, not creative writing.
            // Randomness here shows up as inconsistent language / translation.
            "temperature": 0.05,
            "stream": false,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return text }

        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = config.timeout

        let sem = DispatchSemaphore(value: 0)
        var result = text

        let task = URLSession.shared.dataTask(with: req) { respData, _, err in
            defer { sem.signal() }
            if err != nil { return }
            guard let respData = respData,
                  let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else { return }
            let cleaned = stripThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { result = cleaned }
        }
        task.resume()
        // wait up to timeout + a small margin; if it hangs, keep the original
        _ = sem.wait(timeout: .now() + config.timeout + 1)
        return result
    }

    /// Remove a leading <think>…</think> block that reasoning models (e.g. Qwen3)
    /// sometimes emit before the actual answer.
    private static func stripThinking(_ s: String) -> String {
        guard let close = s.range(of: "</think>") else { return s }
        return String(s[close.upperBound...])
    }
}
