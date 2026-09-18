import Darwin
import Foundation

/// Retained presentation data, separate from the messages sent to the model.
struct TerminalTranscript {
  enum Entry {
    case text(String)
    case tool(String, Int)
    case thought(String)
  }

  private(set) var entries: [Entry] = []
  private(set) var expanded = false
  var scrollOffset = 0

  var hasTools: Bool {
    entries.contains {
      switch $0 {
      case .tool, .thought: return true
      case .text: return false
      }
    }
  }

  mutating func append(_ text: String) {
    if case .text(var previous) = entries.last {
      entries.removeLast()
      previous += text
      entries.append(.text(previous))
    } else {
      entries.append(.text(text))
    }
  }

  mutating func appendTool(_ result: String, limit: Int) -> String {
    entries.append(.tool(result, max(0, limit)))
    return toolText(result, limit: max(0, limit))
  }

  mutating func appendThought(_ thought: String) -> String {
    entries.append(.thought(thought))
    return thoughtText(thought)
  }

  mutating func toggle() {
    guard hasTools else { return }
    expanded.toggle()
    scrollOffset = 0
  }

  private func toolText(_ result: String, limit: Int) -> String {
    let body = expanded ? result : String(result.prefix(limit))
    let truncated = !expanded && result.count > limit
    let hint = expanded ? " [Ctrl-O collapse]" : " [Ctrl-O expand]"
    return "\u{001B}[33m   \(TerminalText.safe(body))\(truncated ? "..." : "")\(hint)\u{001B}[0m\n"
  }

  private func thoughtText(_ thought: String) -> String {
    let trimmed = thought.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let hint = expanded ? " [Ctrl-O collapse]" : " [Ctrl-O expand]"
    if expanded {
      return "\u{001B}[90m   Thinking:\(hint)\n   "
        + TerminalText.safe(thought).replacingOccurrences(of: "\n", with: "\n   ") + "\u{001B}[0m\n"
    } else {
      let firstLine = trimmed.components(separatedBy: .newlines).first ?? ""
      let preview = String(firstLine.prefix(60))
      let suffix = trimmed.count > preview.count ? "..." : ""
      return "\u{001B}[90m   Thinking: \(TerminalText.safe(preview))\(suffix)\(hint)\u{001B}[0m\n"
    }
  }

  func rows(width: Int) -> [String] {
    let text = entries.map { entry in
      switch entry {
      case .text(let value): return value
      case .tool(let result, let limit): return toolText(result, limit: limit)
      case .thought(let thought): return thoughtText(thought)
      }
    }.joined()
    return Self.wrap(text, width: max(1, width))
  }

  /// Wrap trusted SGR styling and sanitized text without splitting graphemes.
  /// Every row carries its own color so a viewport can begin anywhere.
  static func wrap(_ text: String, width: Int) -> [String] {
    let width = max(1, width)
    var rows: [String] = []
    var row = ""
    var column = 0
    var style = ""
    var index = text.startIndex
    func newline() {
      rows.append(row + "\u{001B}[0m")
      row = style
      column = 0
    }
    func append(_ character: String, cells: Int) {
      if column + cells > width { newline() }
      row += character
      column += cells
    }
    while index < text.endIndex {
      let character = text[index]
      if character == "\u{001B}", let end = text[index...].firstIndex(of: "m") {
        let sequence = String(text[index...end])
        if sequence.dropFirst(2).dropLast().allSatisfy({ $0.isNumber || $0 == ";" }),
          sequence.hasPrefix("\u{001B}[")
        {
          style = sequence == "\u{001B}[0m" ? "" : sequence
          row += sequence
          index = text.index(after: end)
          continue
        }
      }
      if character == "\n" {
        newline()
      } else if character == "\t" {
        for _ in 0..<(8 - column % 8) { append(" ", cells: 1) }
      } else {
        let scalars = character.unicodeScalars
        let cells = scalars.map { max(0, Int(wcwidth(Int32($0.value)))) }.max() ?? 0
        let emoji = scalars.contains { $0.value == 0xFE0F || $0.properties.isEmojiPresentation }
        append(String(character), cells: min(width, emoji ? max(2, cells) : cells))
      }
      index = text.index(after: index)
    }
    rows.append(row + "\u{001B}[0m")
    return rows
  }
}
