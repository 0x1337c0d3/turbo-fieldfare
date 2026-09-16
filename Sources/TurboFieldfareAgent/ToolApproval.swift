import Foundation
import Darwin
import TurboFieldfare

/// Model output is a proposal, never authorization to act on the user's machine.
enum ToolApproval {
    static func request(_ call: ParsedToolCall) -> Bool {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return false }
        guard let arguments = try? JSONEncoder().encode(call.arguments),
              let object = try? JSONSerialization.jsonObject(with: arguments),
              let formatted = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: formatted, encoding: .utf8) else { return false }
        printColor("\n[Tool approval] \(call.name)\n\(text)\nAllow this call? [y/N] ", color: "yellow")
        return accepts(Swift.readLine())
    }

    static func accepts(_ answer: String?) -> Bool {
        guard let answer else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

/// Retain text layout but render control bytes visibly, including split escape sequences.
enum TerminalText {
    static func safe(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if scalar == "\n" || scalar == "\t" { return String(scalar) }
            if scalar.value < 32 || (127...159).contains(scalar.value)
                || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                return String(format: "\\u{%04X}", scalar.value)
            }
            return String(scalar)
        }.joined()
    }
}
