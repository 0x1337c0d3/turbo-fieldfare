import XCTest
import TurboFieldfare
@testable import TurboFieldfareAgent

final class ConversationTurnTests: XCTestCase, @unchecked Sendable {
    private func call(_ name: String, id: String) -> ParsedToolCall {
        .init(id: id, name: name, arguments: .object([:]), argumentsJSON: "{}")
    }

    func testMultipleToolCallsAreRecordedBeforeNextGeneration() async throws {
        var messages = [GFTokenizer.Message(role: .user, content: "request", toolCalls: [], toolCallID: nil, name: nil)]
        var generated = 0
        var executed: [String] = []
        let calls = [call("first", id: "1"), call("second", id: "2")]
        let result = try await ConversationTurn.run(messages: &messages, generate: { history in
            generated += 1
            if generated == 1 { return ("", calls) }
            XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool, .tool])
            XCTAssertNil(history[1].content)
            XCTAssertEqual(history[1].toolCalls.map(\.id), ["1", "2"])
            XCTAssertEqual(history[2].toolCallID, "1")
            XCTAssertEqual(history[3].content, "result second")
            return ("done", [])
        }, execute: { call in
            executed.append(call.name)
            return "result " + call.name
        })
        XCTAssertEqual(result, "done")
        XCTAssertEqual(executed, ["first", "second"])
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.content, "done")
    }

    func testGenerationFailurePropagatesWithoutInventingAssistantMessage() async {
        enum Failure: Error { case expected }
        var messages: [GFTokenizer.Message] = []
        do {
            _ = try await ConversationTurn.run(messages: &messages, generate: { _ in throw Failure.expected }, execute: { _ in
                XCTFail("No tools should execute")
                return ""
            })
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue(error is Failure)
            XCTAssertTrue(messages.isEmpty)
        }
    }

    func testToolSummaryUsesPreferredArgumentAndCapsLength() {
        let call = ParsedToolCall(id: "1", name: "shell", arguments: .object([
            "command": .string("first\n" + String(repeating: "x", count: 80)),
            "path": .string("ignored")
        ]), argumentsJSON: "{}")
        XCTAssertTrue(call.argumentSummary.hasPrefix("first "))
        XCTAssertEqual(call.argumentSummary.count, 63)
        XCTAssertTrue(call.argumentSummary.hasSuffix("..."))
    }

    func testShellDrainsMoreThanAPipeBufferAndIncludesStderr() throws {
        let output = try ShellCommand.run("/usr/bin/printf 'stderr-marker' >&2; /usr/bin/yes x | /usr/bin/head -c 131072")
        XCTAssertTrue(output.hasPrefix("stderr-marker"))
        XCTAssertEqual(output.utf8.count, 131085)
    }
}
