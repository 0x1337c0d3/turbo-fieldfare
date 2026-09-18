import TurboFieldfare

/// Shared conversation loop for the interactive session and delegated tasks.
enum ConversationTurn {
  static func run(
    messages: inout [GFTokenizer.Message],
    maximumRounds: Int = 32,
    generate: ([GFTokenizer.Message]) async throws -> (content: String, calls: [ParsedToolCall]),
    execute: (ParsedToolCall) async -> String
  ) async throws -> String {
    var emptyContentRetries = 0
    let totalRounds = max(0, maximumRounds)
    for round in 0..<totalRounds {
      try Task.checkCancellation()
      let (content, calls) = try await generate(messages)
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if calls.isEmpty {
        if trimmed.isEmpty && emptyContentRetries < 2 {
          emptyContentRetries += 1
          messages.append(
            GFTokenizer.Message(
              role: .assistant, content: nil,
              toolCalls: [], toolCallID: nil, name: nil))
          messages.append(
            GFTokenizer.Message(
              role: .user,
              content:
                "You completed your internal analysis, but did not emit any tool calls or content. You MUST create the requested deliverable file now using write_file (implementing your best-effort solution if an optimal one cannot be proven), run it, and report your results. Do not stop without creating the deliverable file.",
              toolCalls: [], toolCallID: nil, name: nil))
          continue
        }
        messages.append(
          GFTokenizer.Message(
            role: .assistant, content: content.isEmpty ? nil : content,
            toolCalls: [], toolCallID: nil, name: nil))
        return content
      }
      emptyContentRetries = 0
      messages.append(
        GFTokenizer.Message(
          role: .assistant, content: content.isEmpty ? nil : content,
          toolCalls: calls.map { .init(id: $0.id, name: $0.name, arguments: $0.arguments) },
          toolCallID: nil, name: nil))
      let remainingRounds = totalRounds - (round + 1)
      for (index, call) in calls.enumerated() {
        var result = await execute(call)
        if index == calls.count - 1 && remainingRounds > 0 && remainingRounds <= 4 {
          let urgency =
            remainingRounds == 1
            ? "[CRITICAL Turn Budget Notice: This is your LAST allowed tool round. You MUST call write_file now to create the final deliverable file and complete the requested task.]"
            : "[Turn Budget Notice: \(remainingRounds) round\(remainingRounds == 1 ? "" : "s") remaining before forced termination. Finish scratchpad exploration immediately and write your final deliverable files (`write_file`) now.]"
          result += "\n\n" + urgency
        }
        messages.append(
          GFTokenizer.Message(
            role: .tool, content: result, toolCalls: [],
            toolCallID: call.id, name: call.name))
      }
      if remainingRounds == 0 {
        // One final pass to allow the model to provide its summary/conclusion
        let (finalContent, _) = try await generate(messages)
        let finalTrimmed = finalContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = finalTrimmed.isEmpty ? "Task completed." : finalContent
        messages.append(
          GFTokenizer.Message(
            role: .assistant, content: resolved,
            toolCalls: [], toolCallID: nil, name: nil))
        return resolved
      }
    }
    throw TurnError.roundLimit
  }

  enum TurnError: Error { case roundLimit }
}

extension ParsedToolCall {
  func stringArgument(_ key: String) -> String? {
    guard case .object(let arguments) = arguments,
      case .string(let value) = arguments[key]
    else { return nil }
    return value
  }

  func intArgument(_ key: String) -> Int? {
    guard case .object(let arguments) = arguments else { return nil }
    if case .integer(let value) = arguments[key] { return Int(value) }
    if case .number(let value) = arguments[key] { return Int(value) }
    return nil
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
