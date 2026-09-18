import Foundation
import TurboFieldfare

public enum RouteTarget: String, Sendable {
  case local
  case cloud
}

struct HybridRouter: Sendable {
  let backendKind: AgentBackendKind
  let pccPolicy: PCCPolicy
  let localRuntime: AgentRuntime?
  let cloudClient: OpenAIClient?

  init(
    backendKind: AgentBackendKind = .apple,
    pccPolicy: PCCPolicy = .auto,
    localRuntime: AgentRuntime? = nil,
    cloudClient: OpenAIClient? = nil
  ) {
    self.backendKind = backendKind
    self.pccPolicy = pccPolicy
    self.localRuntime = localRuntime
    self.cloudClient = cloudClient
  }

  public func decide(messages: [GFTokenizer.Message]) async throws -> RouteTarget {
    // PCC Policy Overrides
    switch pccPolicy {
    case .disable:
      return .local
    case .require:
      return .cloud
    case .auto:
      break
    }

    // If using Gemma without cloud client, stay local
    if backendKind == .gemma && cloudClient == nil {
      return .local
    }

    let spinnerTask = Task {
      let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
      var index = 0
      while !Task.isCancelled {
        AgentTerminal.write(
          "\r\u{001B}[34m\(frames[index % frames.count]) Routing...\u{001B}[0m\u{001B}[K")
        index += 1
        do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
      }
      AgentTerminal.write("\r\u{001B}[K")
    }

    let target: RouteTarget
    do {
      // Tier 1: Heuristics
      if let heuristic = checkHeuristics(messages: messages) {
        target = heuristic
      } else {
        // Tier 2: Local Classifier
        target = try await askLocalClassifier(messages: messages)
      }
    }

    spinnerTask.cancel()
    _ = await spinnerTask.value
    return target
  }

  public func checkHeuristics(messages: [GFTokenizer.Message]) -> RouteTarget? {
    let text = messages.last?.content ?? ""
    let textLower = text.lowercased()

    // Massive Context (> 64k chars) offloads to cloud
    if text.count > 64_000 { return .cloud }

    let cloudKeywords = [
      "search the web", "generate image", "summarize 100",
      "complex reasoning", "write an essay", "prove mathematically",
      "deep analysis", "refactor entire architecture",
    ]
    for kw in cloudKeywords {
      if textLower.contains(kw) { return .cloud }
    }

    let localKeywords = [
      "format this string", "what time is it", "ping", "hello", "hi",
      "ls", "cat", "pwd", "git status",
    ]
    for kw in localKeywords {
      if textLower.contains(kw) { return .local }
    }

    return nil
  }

  private func askLocalClassifier(messages: [GFTokenizer.Message]) async throws -> RouteTarget {
    guard let localRuntime else { return .local }

    let classifierPrompt = """
      You are a routing agent. Decide if the user's request requires a powerful cloud model (complex reasoning, heavy coding) or can be handled locally (simple questions, summaries, text formatting).
      Output exactly one word: LOCAL or CLOUD.
      """

    let routingMessages =
      [
        GFTokenizer.Message(
          role: .system, content: classifierPrompt, toolCalls: [], toolCallID: nil, name: nil)
      ] + messages

    // Run a fast, 5-token inference on the local model
    let (content, _) = try await localRuntime.generateLocally(
      messages: routingMessages,
      tools: nil,
      interaction: nil,
      maxNewTokensOverride: 5,
      silent: true
    )

    return content.uppercased().contains("CLOUD") ? .cloud : .local
  }
}
