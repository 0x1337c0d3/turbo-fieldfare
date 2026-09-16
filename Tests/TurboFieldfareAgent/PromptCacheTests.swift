import XCTest
import TurboFieldfare
@testable import TurboFieldfareAgent

final class PromptCacheTests: XCTestCase {
    private enum RewindError: Error { case overwritten }

    func testDivergentFollowupRewindsBeforeResuming() {
        let committed = (0..<4706).map(Int32.init)
        var prompt = Array(committed.prefix(4644))
        prompt.append(contentsOf: [-1, -2])
        var position = 4706
        let start = AgentPromptCache.start(prompt: prompt, committed: committed, position: position) {
            position = $0
        }
        guard case .resume(let count) = start else { return XCTFail("Expected prefix reuse") }
        XCTAssertEqual(count, 4644)
        XCTAssertEqual(position, count)
    }

    func testUnavailableRewindRebuildsCache() {
        let start = AgentPromptCache.start(prompt: [1, 2, 9], committed: [1, 2, 3, 4], position: 4) { _ in
            throw RewindError.overwritten
        }
        guard case .reset = start else { return XCTFail("Must replay after failed rewind") }
    }

    func testExactCommittedPrefixDoesNotRewind() {
        // A generated boundary token need not have been committed to KV.
        let start = AgentPromptCache.start(prompt: [1, 2, 3, 4], committed: [1, 2], position: 2) { _ in
            XCTFail("No rewind needed")
        }
        guard case .resume(let count) = start else { return XCTFail("Expected continuation") }
        XCTAssertEqual(count, 2)
    }

    func testUnknownOrStaleKVStateResets() {
        for committed: [Int32] in [[], [1, 2, 3]] {
            let start = AgentPromptCache.start(prompt: [1, 2, 4], committed: committed, position: 2) { _ in
                XCTFail("Must not rewind unverified state")
            }
            guard case .reset = start else { return XCTFail("Must reset stale record") }
        }
    }

    func testIdenticalOrShorterPromptRetainsTokenForPrefill() {
        for prompt: [Int32] in [[1, 2, 3], [1, 2]] {
            var rewound: Int?
            let start = AgentPromptCache.start(prompt: prompt, committed: [1, 2, 3], position: 3) { rewound = $0 }
            guard case .resume(let count) = start else { return XCTFail("Expected rewind") }
            XCTAssertEqual(count, prompt.count - 1)
            XCTAssertEqual(rewound, count)
        }
    }

    func testUnrelatedPromptResets() {
        let start = AgentPromptCache.start(prompt: [9, 8], committed: [1, 2], position: 2) { _ in
            XCTFail("No shared prefix")
        }
        guard case .reset = start else { return XCTFail("Expected reset") }
    }
}
