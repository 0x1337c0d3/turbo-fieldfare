import Foundation
import TurboFieldfare

public enum OpenAIBackendError: Error, CustomStringConvertible {
  case missingConfiguration(String)

  public var description: String {
    switch self {
    case .missingConfiguration(let msg): return msg
    }
  }
}

final class OpenAICompatibleBackend: InferenceBackend, @unchecked Sendable {
  let capabilities: BackendCapabilities
  let client: OpenAIClient

  init(client: OpenAIClient? = OpenAIClient()) throws {
    guard let client else {
      throw OpenAIBackendError.missingConfiguration(
        "OpenAI configuration not found in ~/.config/TurboFieldfareAgent/settings.json or OPENAI_API_KEY environment variable is unset."
      )
    }
    self.client = client
    self.capabilities = BackendCapabilities(
      name: "OpenAI Compatible Cloud",
      supportsTools: true,
      supportsStreaming: false,
      maxContextLength: 128_000,
      isOnDevice: false,
      isPrivateCloudCompute: false
    )
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]?,
    interaction: AgentInteraction?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let result = try await client.generate(messages: messages, tools: tools)
    if let interaction {
      interaction.text(result.content)
    }
    return result
  }
}
