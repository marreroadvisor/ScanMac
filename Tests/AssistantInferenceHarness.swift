import Foundation
@main struct InferenceTest {
    static func main() async throws {
        let result = try await AssistantInference.answer(model: "atlas-35b", prompt: "TASK: Translate the following source into Spanish. Return only the translated sentence. DOCUMENT: The blue folder contains three pages.")
        precondition(result.text.localizedCaseInsensitiveContains("carpeta") && result.text.localizedCaseInsensitiveContains("tres"), result.text)
        print("PASS local translation: \(result.text) — \(result.engine)")
        let markdown = try await AssistantInference.direct(model: "atlas-35b", prompt: "Convert only this source to a Markdown table with columns Item and Quantity: apples 3, pears 2. Do not add facts.")
        precondition(markdown.text.contains("|") && markdown.text.contains("3") && markdown.text.contains("2"), markdown.text)
        print("PASS local Markdown table")
    }
}
