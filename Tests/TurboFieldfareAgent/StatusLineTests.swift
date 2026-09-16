import XCTest
@testable import TurboFieldfareAgent

final class StatusLineTests: XCTestCase {
    func testMetricsAndUnavailableValues() {
        var snapshot = AgentStatusSnapshot(maxContext: 262144)
        XCTAssertEqual(snapshot.text(width: 100), " Ready | -- tok/s | RAM -- | ctx 0/262144")
        snapshot.tokensPerSecond = 12.34
        snapshot.memoryBytes = 2_684_354_560
        snapshot.contextTokens = 1024
        XCTAssertEqual(snapshot.text(width: 100), " Ready | 12.3 tok/s | RAM 2.50 GiB | ctx 1024/262144")
        snapshot.tokensPerSecond = .infinity
        XCTAssertTrue(snapshot.text(width: 100).contains("-- tok/s"))
    }

    func testNarrowTerminalDoesNotWrap() {
        let snapshot = AgentStatusSnapshot(maxContext: 262144)
        for width in 0...100 {
            XCTAssertLessThanOrEqual(snapshot.text(width: width).count, max(0, width - 1))
        }
    }

    func testGenerationLifecycleRetainsFinalRateAndCommittedContext() {
        let status = AgentStatusLine()
        status.beginGeneration(contextTokens: 100)
        XCTAssertNil(status.snapshot.tokensPerSecond)
        XCTAssertEqual(status.snapshot.phase, "Prefill")
        status.prefill(done: 200)
        status.token(count: 1, contextTokens: 200)
        XCTAssertNil(status.snapshot.tokensPerSecond)
        XCTAssertEqual(status.snapshot.phase, "Decoding")
        status.finish(tokens: 20, decodeSeconds: 2, contextTokens: 219)
        status.preparePrompt()
        XCTAssertEqual(status.snapshot.tokensPerSecond, 10)
        XCTAssertEqual(status.snapshot.contextTokens, 219)
        XCTAssertEqual(status.snapshot.phase, "Ready")
    }
}
