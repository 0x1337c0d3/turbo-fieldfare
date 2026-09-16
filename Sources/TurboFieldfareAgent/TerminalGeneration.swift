import Foundation

/// Terminal-only input and progress presentation. ACP never constructs this.
final class TerminalGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var hasText = false
    private var waitingForSecondCtrlC = false
    private var originalTermios = termios()
    private var originalFlags: Int32 = 0
    private var keyboard: DispatchSourceRead?
    private var spinner: Task<Void, Never>?
    private let cancellation: AgentCancellation

    init(cancellation: AgentCancellation) {
        self.cancellation = cancellation
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else { return }
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
        raw.c_cc.16 = 1
        raw.c_cc.17 = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        originalFlags = fcntl(STDIN_FILENO, F_GETFL, 0)
        _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags | O_NONBLOCK)
        let keyboard = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
        keyboard.setEventHandler { [weak self] in self?.readKeys() }
        self.keyboard = keyboard
        keyboard.resume()
        spinner = Task { [weak self] in
            let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            var index = 0
            while let self, !Task.isCancelled {
                let drawn = self.lock.withLock {
                    guard self.active, !self.hasText else { return false }
                    terminalPrint("\r\u{001B}[34m\(frames[index % frames.count]) Thinking...\u{001B}[0m\u{001B}[K", terminator: "")
                    return true
                }
                if !drawn { break }
                index += 1
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
            }
        }
    }

    private func readKeys() {
        while let byte = nextByte() {
            if byte == 3 {
                let exitNow = lock.withLock {
                    let previous = waitingForSecondCtrlC
                    waitingForSecondCtrlC = true
                    active = false
                    return previous
                }
                if exitNow { restore(); exit(1) }
                terminalPrint("\n[Press ctrl-c again to exit]")
                cancellation.cancel()
            } else if byte == 27 {
                cancellation.cancel()
                lock.withLock { active = false }
                terminalPrint("\n[Generation Stopped (ESC)]")
            } else {
                lock.withLock { waitingForSecondCtrlC = false }
            }
        }
    }

    private func nextByte() -> UInt8? {
        lock.withLock {
            guard keyboard != nil else { return nil }
            var byte: UInt8 = 0
            return read(STDIN_FILENO, &byte, 1) > 0 ? byte : nil
        }
    }

    func text(_ text: String) {
        lock.withLock {
            if !hasText, keyboard != nil { terminalPrint("\r\u{001B}[K", terminator: "") }
            hasText = true
            terminalPrint(TerminalText.safe(text), terminator: "")
        }
    }

    func finish() async {
        lock.withLock { active = false }
        spinner?.cancel()
        await spinner?.value
        lock.withLock {
            if hasText { terminalPrint("") }
            else if keyboard != nil { terminalPrint("\r\u{001B}[K", terminator: "") }
        }
    }

    func restore() {
        lock.withLock {
            guard let keyboard else { return }
            keyboard.cancel()
            self.keyboard = nil
            _ = fcntl(STDIN_FILENO, F_SETFL, originalFlags)
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        }
    }
}
