import Foundation
import TurboFieldfare

#if canImport(FoundationModels)
  import FoundationModels
#endif

public enum AppleFoundationModelError: Error, CustomStringConvertible {
  case unsupportedPlatform(String)
  case modelUnavailable(String)
  case generationFailed(String)

  public var description: String {
    switch self {
    case .unsupportedPlatform(let msg): return msg
    case .modelUnavailable(let msg): return msg
    case .generationFailed(let msg): return msg
    }
  }
}

final class AppleFoundationModelBackend: InferenceBackend, @unchecked Sendable {
  let capabilities: BackendCapabilities
  private let pccPolicy: PCCPolicy
  private let systemPrompt: String
  private let toolBridge: MCPJSONSchemaBridge

  init(pccPolicy: PCCPolicy = .auto, systemPrompt: String) {
    self.pccPolicy = pccPolicy
    self.systemPrompt = systemPrompt
    self.toolBridge = MCPJSONSchemaBridge()
    self.capabilities = BackendCapabilities(
      name: "Apple Foundation Models (AFM 3 Core & Cloud Pro PCC)",
      supportsTools: true,
      supportsStreaming: true,
      maxContextLength: 131_072,
      isOnDevice: pccPolicy != .require,
      isPrivateCloudCompute: pccPolicy != .disable
    )
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]?,
    interaction: AgentInteraction?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    #if canImport(FoundationModels)
      guard #available(macOS 27.0, *) else {
        throw AppleFoundationModelError.unsupportedPlatform(
          "Apple Foundation Models require macOS 27.0 (Golden Gate) or later."
        )
      }

      return try await generateWithFoundationModels(
        messages: messages,
        tools: tools,
        interaction: interaction
      )
    #else
      throw AppleFoundationModelError.unsupportedPlatform(
        "FoundationModels framework is not available in this build."
      )
    #endif
  }

  #if canImport(FoundationModels)
    @available(macOS 27.0, *)
    private func generateWithFoundationModels(
      messages: [GFTokenizer.Message],
      tools: [GFTokenizer.FunctionDefinition]?,
      interaction: AgentInteraction?
    ) async throws -> (content: String, calls: [ParsedToolCall]) {
      let model: any LanguageModel
      switch pccPolicy {
      case .disable, .auto:
        guard SystemLanguageModel.default.availability == .available else {
          throw AppleFoundationModelError.modelUnavailable(
            "AFM 3 Core (SystemLanguageModel) is not available on this device."
          )
        }
        model = SystemLanguageModel.default
      case .require:
        let pcc = PrivateCloudComputeLanguageModel()
        guard pcc.availability == .available else {
          throw AppleFoundationModelError.modelUnavailable(
            "AFM Cloud Pro (PrivateCloudComputeLanguageModel) is not available."
          )
        }
        model = pcc
      }

      let activeTools = tools ?? ToolRegistry.definitions
      let toolCatalog = toolBridge.formatToolCatalog(tools: activeTools)
      let basePrompt: String
      if systemPrompt.count > 1500 {
        basePrompt = """
          You are TurboFieldfareAgent, an autonomous software engineering assistant running natively on Apple Silicon.
          You have direct access to tools to inspect, read, create, and test code deliverables in your workspace.
          Always fulfill tasks completely, create requested deliverable files, and verify them.
          """
      } else {
        basePrompt = systemPrompt
      }
      let fullInstructions = """
        \(basePrompt)

        \(toolCatalog)
        """

      let promptText = toolBridge.formatConversationPrompt(messages: messages)

      let session = LanguageModelSession(
        model: model,
        instructions: fullInstructions
      )

      var fullText = ""
      let stream = session.streamResponse(to: promptText)
      for try await snapshot in stream {
        if let interaction, interaction.cancellation.isCancelled {
          throw CancellationError()
        }
        fullText = snapshot.content
      }

      let (cleanContent, calls) = toolBridge.parseToolCalls(from: fullText)
      let effectiveContent: String
      if !calls.isEmpty {
        if cleanContent.contains("Scratchpad Output")
          || cleanContent.contains("Verification:")
          || cleanContent.contains("Tool (")
          || cleanContent.contains("Result:")
        {
          effectiveContent = ""
        } else {
          effectiveContent = cleanContent
        }
      } else {
        effectiveContent = cleanContent
      }

      if let interaction {
        if !effectiveContent.isEmpty {
          interaction.text(effectiveContent)
        }
      } else {
        if !effectiveContent.isEmpty {
          AgentTerminal.output(effectiveContent + "\n")
        }
      }

      return (effectiveContent, calls)
    }
  #endif
}
