import Foundation
import XCTest
import TurboFieldfare
@testable import TurboFieldfareAgent

final class MCPToolSchemaTests: XCTestCase, @unchecked Sendable {
    private func tool(_ schema: String, name: String = "mcp_probe") throws -> GFTokenizer.FunctionDefinition {
        .init(name: name, description: "Probe MCP schema rendering",
              parameters: try JSONDecoder().decode(JSONValue.self, from: Data(schema.utf8)))
    }

    func testMCPNullableAndBareObjectSchemasRender() async throws {
        let fm = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["TURBO_FIELDFARE_TOKENIZER_DIR"],
            fm.currentDirectoryPath + "/scratch/gemma4.gturbo/tokenizer",
            fm.homeDirectoryForCurrentUser.path + "/Library/Application Support/TurboFieldfare/gemma4.gturbo/tokenizer"
        ].compactMap { $0 }
        guard let folder = candidates.first(where: { fm.fileExists(atPath: $0 + "/tokenizer.json") }) else {
            throw XCTSkip("Requires local tokenizer files only; no model weights or download needed")
        }
        let tokenizer = try await GFTokenizer.load(from: URL(fileURLWithPath: folder))
        let raw = try tool(#"""
        {"type":"object","properties":{
          "filter":{"type":["string","null"],"description":"Optional filter"},
          "options":{"type":"object","additionalProperties":false,"title":"Options"},
          "limit":{"anyOf":[{"type":"integer"},{"type":"null"}],"default":null}
        }}
        """#)
        let messages = [GFTokenizer.Message(role: .user, content: "what bugcrowd mcp tools are available?", toolCalls: [], toolCallID: nil, name: nil)]
        XCTAssertThrowsError(try tokenizer.encodeToolChat(messages: messages, tools: [raw])) { error in
            XCTAssertTrue(String(describing: error).contains("upper filter requires string"))
        }
        let adapted = ToolRegistry.adaptedMCPTools([raw]) { XCTFail($0) }
        XCTAssertEqual(adapted.count, 1)
        let ids = try tokenizer.encodeToolChat(messages: messages, tools: ToolRegistry.baseDefinitions + adapted)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertTrue(tokenizer.decode(ids, skipSpecialTokens: false).contains("mcp_probe"))
    }

    func testUnsupportedSchemaIsReportedWithoutRemovingOtherTools() throws {
        let unsupported = try tool(#"{"type":"object","properties":{"value":{"anyOf":[{"type":"string"},{"type":"integer"}]}}}"#, name: "unsupported")
        let supported = try tool(#"{"type":"object"}"#, name: "supported")
        var errors: [String] = []
        let result = ToolRegistry.adaptedMCPTools([unsupported, supported]) { errors.append($0) }
        XCTAssertEqual(result.map(\.name), ["supported"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("unsupported"))
        XCTAssertEqual(result.first?.parameters, .object(["type": .string("object"), "properties": .object([:])]))
    }
}
