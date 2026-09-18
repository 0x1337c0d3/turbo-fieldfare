import Foundation
import TurboFieldfare
import XCTest

@testable import TurboFieldfareAgent

final class InferenceBackendTests: XCTestCase, @unchecked Sendable {
  func testBackendParsing() throws {
    let configApple = try AgentConfig(arguments: ["--backend", "apple"])
    XCTAssertEqual(configApple.backend, .apple)

    let configGemma = try AgentConfig(arguments: [
      "--backend", "gemma", "--model", "scratch/test.gturbo",
    ])
    XCTAssertEqual(configGemma.backend, .gemma)

    let configOpenAI = try AgentConfig(arguments: ["--backend", "openai"])
    XCTAssertEqual(configOpenAI.backend, .openai)
  }

  func testInvalidBackendThrowsError() {
    XCTAssertThrowsError(try AgentConfig(arguments: ["--backend", "nonexistent"])) { error in
      guard case AgentConfigError.invalidBackend(let val) = error else {
        XCTFail("Expected AgentConfigError.invalidBackend, got \(error)")
        return
      }
      XCTAssertEqual(val, "nonexistent")
    }
  }

  func testPCCPolicyParsing() throws {
    let configAuto = try AgentConfig(arguments: ["--pcc", "auto"])
    XCTAssertEqual(configAuto.pccPolicy, .auto)

    let configDisable = try AgentConfig(arguments: ["--pcc", "disable"])
    XCTAssertEqual(configDisable.pccPolicy, .disable)

    let configRequire = try AgentConfig(arguments: ["--pcc", "require"])
    XCTAssertEqual(configRequire.pccPolicy, .require)
  }

  func testInvalidPCCPolicyThrowsError() {
    XCTAssertThrowsError(try AgentConfig(arguments: ["--pcc", "invalid_policy"])) { error in
      guard case AgentConfigError.invalidPCCPolicy(let val) = error else {
        XCTFail("Expected AgentConfigError.invalidPCCPolicy, got \(error)")
        return
      }
      XCTAssertEqual(val, "invalid_policy")
    }
  }

  func testDefaultBackendBehavior() throws {
    // When model is explicitly passed without --backend, it should default to .gemma
    let configWithModel = try AgentConfig(arguments: ["--model", "custom/model.gturbo"])
    XCTAssertEqual(configWithModel.backend, .gemma)
  }

  func testAppleBackendCapabilities() {
    let backendAuto = AppleFoundationModelBackend(pccPolicy: .auto, systemPrompt: "test")
    XCTAssertTrue(backendAuto.capabilities.supportsTools)
    XCTAssertTrue(backendAuto.capabilities.supportsStreaming)
    XCTAssertEqual(backendAuto.capabilities.maxContextLength, 131_072)
    XCTAssertTrue(backendAuto.capabilities.isOnDevice)
    XCTAssertTrue(backendAuto.capabilities.isPrivateCloudCompute)

    let backendDisable = AppleFoundationModelBackend(pccPolicy: .disable, systemPrompt: "test")
    XCTAssertTrue(backendDisable.capabilities.isOnDevice)
    XCTAssertFalse(backendDisable.capabilities.isPrivateCloudCompute)

    let backendRequire = AppleFoundationModelBackend(pccPolicy: .require, systemPrompt: "test")
    XCTAssertFalse(backendRequire.capabilities.isOnDevice)
    XCTAssertTrue(backendRequire.capabilities.isPrivateCloudCompute)
  }

  func testMCPJSONSchemaBridgeConversion() {
    let bridge = MCPJSONSchemaBridge()

    let schema: JSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "command": .object([
          "type": .string("string"),
          "description": .string("The shell command to run"),
        ]),
        "timeout": .object([
          "type": .string("integer"),
          "description": .string("Timeout in seconds"),
        ]),
        "verbose": .object([
          "type": .string("boolean")
        ]),
        "flags": .object([
          "type": .string("array"),
          "items": .object([
            "type": .string("string")
          ]),
        ]),
        "metadata": .object([
          "type": .string("null")
        ]),
      ]),
      "required": .array([.string("command")]),
    ])

    let converted = bridge.convertSchema(parameters: schema)

    XCTAssertEqual(converted["type"] as? String, "object")

    let properties = converted["properties"] as? [String: Any]
    XCTAssertNotNil(properties)

    let cmdProp = properties?["command"] as? [String: Any]
    XCTAssertEqual(cmdProp?["type"] as? String, "string")
    XCTAssertEqual(cmdProp?["description"] as? String, "The shell command to run")

    let timeoutProp = properties?["timeout"] as? [String: Any]
    XCTAssertEqual(timeoutProp?["type"] as? String, "integer")

    let verboseProp = properties?["verbose"] as? [String: Any]
    XCTAssertEqual(verboseProp?["type"] as? String, "boolean")

    let flagsProp = properties?["flags"] as? [String: Any]
    XCTAssertEqual(flagsProp?["type"] as? String, "array")
    let itemsProp = flagsProp?["items"] as? [String: Any]
    XCTAssertEqual(itemsProp?["type"] as? String, "string")

    let required = converted["required"] as? [Any]
    XCTAssertEqual(required?.count, 1)
    XCTAssertEqual(required?.first as? String, "command")
  }

  func testHybridRouterPCCPolicyOverrides() async throws {
    let routerDisable = HybridRouter(backendKind: .apple, pccPolicy: .disable)
    let messages = [
      GFTokenizer.Message(
        role: .user,
        content: "write an essay on quantum mechanics with deep analysis and complex reasoning",
        toolCalls: [], toolCallID: nil, name: nil)
    ]
    let targetDisable = try await routerDisable.decide(messages: messages)
    XCTAssertEqual(targetDisable, .local)

    let routerRequire = HybridRouter(backendKind: .apple, pccPolicy: .require)
    let simpleMessages = [
      GFTokenizer.Message(role: .user, content: "ping", toolCalls: [], toolCallID: nil, name: nil)
    ]
    let targetRequire = try await routerRequire.decide(messages: simpleMessages)
    XCTAssertEqual(targetRequire, .cloud)
  }

  func testHybridRouterHeuristics() {
    let router = HybridRouter(backendKind: .apple, pccPolicy: .auto)

    // Short local query
    let localMsg = [
      GFTokenizer.Message(role: .user, content: "ping", toolCalls: [], toolCallID: nil, name: nil)
    ]
    XCTAssertEqual(router.checkHeuristics(messages: localMsg), .local)

    // Cloud query by keyword
    let cloudMsg = [
      GFTokenizer.Message(
        role: .user, content: "Please do some complex reasoning on this", toolCalls: [],
        toolCallID: nil, name: nil)
    ]
    XCTAssertEqual(router.checkHeuristics(messages: cloudMsg), .cloud)

    // Large context (>64k)
    let largeString = String(repeating: "A", count: 65_000)
    let massiveMsg = [
      GFTokenizer.Message(
        role: .user, content: largeString, toolCalls: [], toolCallID: nil, name: nil)
    ]
    XCTAssertEqual(router.checkHeuristics(messages: massiveMsg), .cloud)
  }
}
