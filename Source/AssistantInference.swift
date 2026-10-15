import Foundation

struct AssistantInferenceResult {
    let text: String
    let engine: String
}

private actor AssistantBackendCompatibility {
    static let shared = AssistantBackendCompatibility()
    private var directModels: Set<String> = []
    func needsDirect(_ model: String) -> Bool { directModels.contains(model) }
    func remember(_ model: String) { directModels.insert(model) }
}

enum AssistantInference {
    static func answer(model: String, prompt: String) async throws -> AssistantInferenceResult {
        guard prompt.utf8.count <= 200_000 else { throw CodexLocalError.tooLarge }
        if await AssistantBackendCompatibility.shared.needsDirect(model) { return try await direct(model: model, prompt: prompt) }
        do {
            let text = try await CodexLocal.answer(model: model, prompt: prompt)
            return AssistantInferenceResult(text: text, engine: "Codex + LM Studio · Este Mac")
        } catch is CancellationError { throw CancellationError() }
        catch let error as CodexLocalError {
            // Some local chat templates reject the multiple instruction messages in Responses.
            // Context/timeout errors should remain actionable instead of retrying a large request.
            guard error == .failed || error == .missing else { throw error }
            try Task.checkCancellation()
            let result = try await direct(model: model, prompt: prompt)
            await AssistantBackendCompatibility.shared.remember(model)
            return result
        }
    }
    static func direct(model: String, prompt: String) async throws -> AssistantInferenceResult {
        guard prompt.utf8.count <= 200_000 else { throw CodexLocalError.tooLarge }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "max_tokens": 4096,
            "messages": [["role": "system", "content": CodexLocal.instructions], ["role": "user", "content": prompt]]
        ])
        let (data, response) = try await LocalNetwork.session.data(for: request)
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { throw CodexLocalError.failed }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodexLocalError.failed }
        return AssistantInferenceResult(text: content, engine: "LM Studio directo · Este Mac (compatibilidad del modelo)")
    }
}
