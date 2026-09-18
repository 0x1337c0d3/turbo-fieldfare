import Foundation
import TurboFieldfare

public struct BackendCapabilities: Sendable, Equatable {
  public let name: String
  public let supportsTools: Bool
  public let supportsStreaming: Bool
  public let maxContextLength: Int
  public let isOnDevice: Bool
  public let isPrivateCloudCompute: Bool

  public init(
    name: String,
    supportsTools: Bool = true,
    supportsStreaming: Bool = true,
    maxContextLength: Int = 131_072,
    isOnDevice: Bool = true,
    isPrivateCloudCompute: Bool = false
  ) {
    self.name = name
    self.supportsTools = supportsTools
    self.supportsStreaming = supportsStreaming
    self.maxContextLength = maxContextLength
    self.isOnDevice = isOnDevice
    self.isPrivateCloudCompute = isPrivateCloudCompute
  }
}

protocol InferenceBackend: Sendable {
  var capabilities: BackendCapabilities { get }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]?,
    interaction: AgentInteraction?
  ) async throws -> (content: String, calls: [ParsedToolCall])
}
