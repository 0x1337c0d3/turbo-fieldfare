import TurboFieldfare

/// Shared conversation loop for the interactive session and delegated tasks.
enum ConversationTurn {
    static func run(
        messages: inout [GFTokenizer.Message],
        maximumRounds: Int = 32,
        generate: ([GFTokenizer.Message]) async throws -> (content: String, calls: [ParsedToolCall]),
        execute: (ParsedToolCall) async -> String
    ) async throws -> String {
        for _ in 0..<max(0, maximumRounds) {
            try Task.checkCancellation()
            let (content, calls) = try await generate(messages)
            messages.append(GFTokenizer.Message(
                role: .assistant, content: content.isEmpty ? nil : content,
                toolCalls: calls.map { .init(id: $0.id, name: $0.name, arguments: $0.arguments) },
                toolCallID: nil, name: nil))
            guard !calls.isEmpty else { return content }
            for call in calls {
                let result = await execute(call)
                messages.append(GFTokenizer.Message(
                    role: .tool, content: result, toolCalls: [],
                    toolCallID: call.id, name: call.name))
            }
        }
        throw TurnError.roundLimit
    }

    enum TurnError: Error { case roundLimit }
}

extension ParsedToolCall {
    func stringArgument(_ key: String) -> String? {
        guard case .object(let arguments) = arguments,
              case .string(let value) = arguments[key] else { return nil }
        return value
    }

    var argumentSummary: String {
        guard case .object(let arguments) = arguments else { return "" }
        let preferred = ["command", "path", "query", "prompt", "url"]
            .compactMap { stringArgument($0) }.first
        let text = (preferred ?? arguments.keys.sorted().joined(separator: ", "))
            .replacingOccurrences(of: "\n", with: " ")
        return text.count > 60 ? String(text.prefix(60)) + "..." : text
    }
}
