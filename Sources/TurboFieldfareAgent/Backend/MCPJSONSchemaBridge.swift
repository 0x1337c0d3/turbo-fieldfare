import Foundation
import TurboFieldfare

public struct MCPJSONSchemaBridge: Sendable {
  public init() {}

  /// Converts a TurboFieldfare FunctionDefinition into a schema description
  public func convertSchema(parameters: JSONValue) -> [String: Any] {
    return parameters.toDictionary()
  }

  public func bridge(definition: GFTokenizer.FunctionDefinition) -> FoundationModels.DynamicFunction
  {
    let schemaDict = convertSchema(parameters: definition.parameters)
    return FoundationModels.DynamicFunction(
      name: definition.name,
      description: definition.description,
      parametersSchema: schemaDict
    )
  }

  public func decodeCall(invocation: FoundationModels.DynamicFunctionInvocation) -> ParsedToolCall {
    let rawJSON = invocation.argumentsJSONString
    let jsonValue =
      (try? JSONDecoder().decode(JSONValue.self, from: rawJSON.data(using: .utf8) ?? Data()))
      ?? .object([:])
    return ParsedToolCall(
      id: invocation.id,
      name: invocation.name,
      arguments: jsonValue,
      argumentsJSON: rawJSON
    )
  }

  public func convertMessages(_ messages: [GFTokenizer.Message]) -> [FoundationModels.ChatMessage] {
    return messages.compactMap { msg in
      switch msg.role {
      case .user:
        return FoundationModels.ChatMessage.user(msg.content ?? "")
      case .assistant:
        return FoundationModels.ChatMessage.assistant(msg.content ?? "")
      case .tool:
        return FoundationModels.ChatMessage.toolResponse(
          id: msg.toolCallID ?? "", content: msg.content ?? "")
      case .system, .developer:
        return nil  // Handled via session instructions
      }
    }
  }
}

extension JSONValue {
  public func toDictionary() -> [String: Any] {
    guard case .object(let dict) = self else { return [:] }
    var result: [String: Any] = [:]
    for (k, v) in dict {
      result[k] = v.toAny()
    }
    return result
  }

  public func toAny() -> Any {
    switch self {
    case .string(let s): return s
    case .integer(let i): return i
    case .unsignedInteger(let u): return u
    case .decimal(let d): return d
    case .number(let n): return n
    case .bool(let b): return b
    case .null: return NSNull()
    case .array(let arr): return arr.map { $0.toAny() }
    case .object(let dict):
      var res: [String: Any] = [:]
      for (k, v) in dict { res[k] = v.toAny() }
      return res
    }
  }
}
