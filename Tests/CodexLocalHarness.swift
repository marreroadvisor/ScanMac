import Foundation

@main struct CodexLocalHarness {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let model = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "openai/gpt-oss-20b"
        let args = CodexLocal.arguments(executable: URL(fileURLWithPath: "/test/codex"), model: model, directory: root, instructionsURL: root.appendingPathComponent("instructions.txt"), output: root.appendingPathComponent("answer.txt"))
        precondition(args.contains("--oss") && args.contains("lmstudio") && args.contains("--ignore-user-config") && args.contains("--ephemeral"))
        precondition(args.contains("features.plugins=false") && args.contains("features.shell_tool=false"))
        precondition(CodexLocal.networkPolicy.contains("deny network*") && CodexLocal.networkPolicy.contains("localhost:1234"))
        let result = try await CodexLocal.answer(model: model, prompt: "Responde solo con LOCAL_CODEX_OK. No uses herramientas.", runtimeRoot: root)
        precondition(result.contains("LOCAL_CODEX_OK"), result)
        print("PASS real local Codex response: \(result)")
        do {
            _ = try await CodexLocal.answer(model: model, prompt: "Prueba de tiempo límite", runtimeRoot: root, timeout: 0)
            preconditionFailure("Missing timeout")
        } catch CodexLocalError.timedOut { print("PASS timeout") }
        let task = Task { try await CodexLocal.answer(model: model, prompt: "Prueba de cancelación", runtimeRoot: root) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Missing cancellation") }
        catch is CancellationError { print("PASS cancellation") }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("request-") }
        precondition(leftovers.isEmpty, "Request data was not removed")
        print("PASS request cleanup and local-only configuration")
    }
}
