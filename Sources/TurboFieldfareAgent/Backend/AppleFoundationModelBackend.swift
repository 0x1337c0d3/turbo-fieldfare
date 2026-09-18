import Foundation
import TurboFieldfare

public enum AppleFoundationModelError: Error, CustomStringConvertible {
  case unsupportedPlatform(String)

  public var description: String {
    switch self {
    case .unsupportedPlatform(let msg): return msg
    }
  }
}

public enum FoundationModels {
  public struct DynamicFunction: @unchecked Sendable {
    public let name: String
    public let description: String
    public let parametersSchema: [String: Any]

    public init(name: String, description: String, parametersSchema: [String: Any]) {
      self.name = name
      self.description = description
      self.parametersSchema = parametersSchema
    }
  }

  public struct DynamicFunctionInvocation: Sendable {
    public let id: String
    public let name: String
    public let argumentsJSONString: String

    public init(id: String, name: String, argumentsJSONString: String) {
      self.id = id
      self.name = name
      self.argumentsJSONString = argumentsJSONString
    }
  }

  public enum ChatMessage: Sendable {
    case user(String)
    case assistant(String)
    case toolResponse(id: String, content: String)
  }

  public struct ModelConfiguration: Sendable {
    public enum CloudOffloadPolicy: Sendable {
      case opportunisticPrivateCloudCompute
      case disabled
      case requirePrivateCloudCompute
    }

    public var cloudOffloadPolicy: CloudOffloadPolicy = .opportunisticPrivateCloudCompute

    public init(configure: (inout ModelConfiguration) -> Void) {
      configure(&self)
    }
  }

  public enum StreamChunk: Sendable {
    case textDelta(String)
    case thoughtDelta(String)
    case toolCall(DynamicFunctionInvocation)
  }

  public final class LanguageModelSession: @unchecked Sendable {
    public let configuration: ModelConfiguration
    public let instructions: String

    public init(configuration: ModelConfiguration, instructions: String) throws {
      self.configuration = configuration
      self.instructions = instructions
    }

    public func stream(
      _ turns: [ChatMessage],
      tools: [DynamicFunction] = []
    ) -> AsyncThrowingStream<StreamChunk, Error> {
      return AsyncThrowingStream { continuation in
        continuation.finish()
      }
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
    guard #available(macOS 27.0, *) else {
      throw AppleFoundationModelError.unsupportedPlatform(
        "Apple Foundation Models require macOS 27.0 (Golden Gate) or later."
      )
    }

    let configuration = FoundationModels.ModelConfiguration { config in
      switch pccPolicy {
      case .auto:
        config.cloudOffloadPolicy = .opportunisticPrivateCloudCompute
      case .disable:
        config.cloudOffloadPolicy = .disabled  // AFM 3 Core (On-Device ANE/GPU) only
      case .require:
        config.cloudOffloadPolicy = .requirePrivateCloudCompute  // AFM Cloud Pro via PCC
      }
    }

    let session = try FoundationModels.LanguageModelSession(
      configuration: configuration,
      instructions: systemPrompt
    )

    // Translate tool definitions via MCPJSONSchemaBridge
    let dynamicFunctions = (tools ?? []).map { toolBridge.bridge(definition: $0) }

    // Convert TurboFieldfare messages to FoundationModels conversation history
    let turns = toolBridge.convertMessages(messages)

    var fullText = ""
    var parsedCalls: [ParsedToolCall] = []

    let stream = session.stream(turns, tools: dynamicFunctions)
    for try await chunk in stream {
      if let interaction, interaction.cancellation.isCancelled {
        throw CancellationError()
      }
      switch chunk {
      case .textDelta(let delta):
        fullText += delta
        interaction?.text(delta)
      case .thoughtDelta(let thought):
        if interaction == nil {
          printColor(thought, color: "gray")
        }
      case .toolCall(let invocation):
        let call = toolBridge.decodeCall(invocation: invocation)
        parsedCalls.append(call)
      }
    }

    return (fullText, parsedCalls)
  }
}
