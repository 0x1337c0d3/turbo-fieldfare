import XCTest
@testable import TurboFieldfareAgent

final class TerminalTranscriptTests: XCTestCase {
    func testGenerationShortcutsRecognizeEnhancedEncodingsWithoutCancelling() {
        for key in ["\u{0F}", "\u{001B}[111;5u", "\u{001B}[27;5;111~"] {
            XCTAssertEqual(TerminalGenerationKey.decode(Array(key.utf8)), .toggleTools)
        }
        XCTAssertEqual(TerminalGenerationKey.decode([27]), .stop)
        XCTAssertEqual(TerminalGenerationKey.decode([3]), .interrupt)
        XCTAssertEqual(TerminalGenerationKey.decode(Array("\u{001B}[A".utf8)), .ignored)
    }
    private func plain(_ rows: [String]) -> String {
        rows.joined(separator: "\n").replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    func testToggleRestoresAllToolResultsAndRetainsSurroundingText() {
        var transcript = TerminalTranscript()
        transcript.append("Before\n")
        _ = transcript.appendTool("preview\nFULL FIRST RESULT", limit: 7)
        transcript.append("Between\n")
        _ = transcript.appendTool("other\nFULL SECOND RESULT", limit: 5)
        transcript.append("After\n")
        let collapsed = transcript.rows(width: 80)
        XCTAssertFalse(plain(collapsed).contains("FULL"))
        transcript.toggle()
        let expanded = plain(transcript.rows(width: 80))
        XCTAssertTrue(expanded.contains("FULL FIRST RESULT"))
        XCTAssertTrue(expanded.contains("FULL SECOND RESULT"))
        XCTAssertTrue(expanded.contains("Before\n"))
        XCTAssertTrue(expanded.contains("Between\n"))
        XCTAssertTrue(expanded.contains("After\n"))
        transcript.toggle()
        XCTAssertEqual(transcript.rows(width: 80), collapsed)
    }

    func testNewResultsFollowExpansionAndEmptyResultsRemainVisible() {
        var transcript = TerminalTranscript()
        transcript.toggle()
        XCTAssertFalse(transcript.expanded)
        _ = transcript.appendTool("", limit: 0)
        transcript.toggle()
        XCTAssertTrue(transcript.appendTool("complete", limit: 1).contains("complete"))
        XCTAssertTrue(plain(transcript.rows(width: 80)).contains("Ctrl-O collapse"))
    }

    func testExpandedOutputCannotInjectTerminalCommands() {
        var transcript = TerminalTranscript()
        _ = transcript.appendTool("safe\u{001B}[2J\r\u{009B}31m\u{202E}bad", limit: 4)
        transcript.toggle()
        let output = plain(transcript.rows(width: 100))
        XCTAssertTrue(output.contains("\\u{001B}[2J\\u{000D}\\u{009B}31m\\u{202E}bad"))
        XCTAssertFalse(output.contains("\u{001B}[2J"))
    }

    func testWrappingPreservesGraphemesTabsAndColors() {
        setlocale(LC_CTYPE, "en_US.UTF-8")
        let rows = TerminalTranscript.wrap("\u{001B}[33m猫猫ab\te\u{0301}🙂\u{001B}[0m\n", width: 6)
        XCTAssertEqual(plain(rows), "猫猫ab\n  e\u{0301}🙂\n")
        XCTAssertTrue(rows[1].hasPrefix("\u{001B}[33m"))
        XCTAssertEqual(plain(TerminalTranscript.wrap("abcdef", width: 3)), "abc\ndef")
    }

    func testToggleResetsPagingAndDoesNotChangeRetainedData() {
        var transcript = TerminalTranscript()
        _ = transcript.appendTool(String(repeating: "line\n", count: 100), limit: 10)
        transcript.scrollOffset = 99
        transcript.toggle()
        XCTAssertEqual(transcript.scrollOffset, 0)
        XCTAssertEqual(transcript.entries.count, 1)
        XCTAssertEqual(plain(transcript.rows(width: 80)).components(separatedBy: "line").count, 101)
    }
}
