import Foundation
import Darwin

/// Serializes footer cursor movements with streamed output and the thinking spinner.
enum AgentTerminal {
    private static let lock = NSRecursiveLock()

    static func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        Swift.print(text, terminator: "")
        fflush(stdout)
    }
}

func terminalPrint(_ text: String = "", terminator: String = "\n") {
    AgentTerminal.write(text + terminator)
}

struct AgentStatusSnapshot {
    var phase = "Ready"
    var tokensPerSecond: Double?
    var memoryBytes: UInt64?
    var contextTokens = 0
    var maxContext = 0

    func text(width: Int) -> String {
        let rate = tokensPerSecond.flatMap { $0.isFinite && $0 >= 0 ? String(format: "%.1f", $0) : nil } ?? "--"
        let memory = memoryBytes.map { String(format: "%.2f GiB", Double($0) / 1_073_741_824) } ?? "--"
        let text = " \(phase) | \(rate) tok/s | RAM \(memory) | ctx \(contextTokens)/\(maxContext)"
        // Leave the last column unused to avoid automatic line wrapping.
        return String(text.prefix(max(0, width - 1)))
    }
}

/// Reserves the last terminal row so readline wrapping and streamed output
/// scroll above the status line. No cursor controls are emitted to pipes.
final class AgentStatusLine {
    var snapshot = AgentStatusSnapshot()
    private var active = false
    private var rows = 0
    private var lastDraw = -Double.infinity
    private var firstTokenTime: Double?

    private var terminalSize: (rows: Int, columns: Int)? {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1,
              ProcessInfo.processInfo.environment["TERM"] != "dumb" else { return nil }
        var size = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0,
              size.ws_row >= 3, size.ws_col >= 2 else { return nil }
        return (Int(size.ws_row), Int(size.ws_col))
    }

    func start(maxContext: Int) {
        snapshot.maxContext = maxContext
        guard terminalSize != nil else { return }
        // exit(1), used by the agent's double-Ctrl-C handler, bypasses defer.
        atexit {
            AgentTerminal.write("\u{001B}[r\u{001B}[0m\n")
        }
        active = true
        refresh(force: true)
    }

    func stop() {
        guard active else { return }
        active = false
        // Restore the full scrolling region and leave a clean shell prompt row.
        AgentTerminal.write("\u{001B}[r\u{001B}[\(rows);1H\u{001B}[2K")
    }

    func preparePrompt() {
        snapshot.phase = "Ready"
        refresh(force: true)
        if active {
            AgentTerminal.write("\u{001B}[\(rows - 1);1H\u{001B}[2K")
        }
    }

    func beginGeneration(contextTokens: Int) {
        snapshot.phase = "Prefill"
        snapshot.contextTokens = contextTokens
        snapshot.tokensPerSecond = nil
        firstTokenTime = nil
        refresh(force: true)
    }

    func prefill(done: Int) {
        snapshot.contextTokens = done
        refresh()
    }

    func token(count: Int, contextTokens: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        if firstTokenTime == nil { firstTokenTime = now }
        snapshot.phase = "Decoding"
        snapshot.contextTokens = contextTokens
        // First token includes prefill: use subsequent token intervals for live rate.
        if count > 1, let start = firstTokenTime, now > start {
            snapshot.tokensPerSecond = Double(count - 1) / (now - start)
        }
        refresh()
    }

    func finish(tokens: Int, decodeSeconds: Double, contextTokens: Int) {
        snapshot.phase = "Ready"
        snapshot.tokensPerSecond = decodeSeconds > 0 ? Double(tokens) / decodeSeconds : nil
        snapshot.contextTokens = contextTokens
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard active, let size = terminalSize else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastDraw >= 0.25 || rows != size.rows else { return }
        lastDraw = now
        snapshot.memoryBytes = Self.processFootprint()
        var output = ""
        if rows != size.rows {
            rows = size.rows
            output += "\u{001B}[1;\(rows - 1)r\u{001B}[\(rows - 1);1H"
        }
        output += "\u{001B}7\u{001B}[\(rows);1H\u{001B}[2K\u{001B}[90m"
        output += snapshot.text(width: size.columns)
        output += "\u{001B}[0m\u{001B}8"
        AgentTerminal.write(output)
    }

    private static func processFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }
}
