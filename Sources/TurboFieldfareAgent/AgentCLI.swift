import Foundation
import TurboFieldfare
import TurboFieldfareCLICore

// MARK: - Utilities
func printColor(_ text: String, color: String) {
    let colorCode: String
    switch color {
    case "green": colorCode = "\u{001B}[32m"
    case "yellow": colorCode = "\u{001B}[33m"
    case "blue": colorCode = "\u{001B}[34m"
    case "reset": colorCode = "\u{001B}[0m"
    case "gray": colorCode = "\u{001B}[90m"
    default: colorCode = ""
    }
    print("\(colorCode)\(text)\u{001B}[0m", terminator: "")
    fflush(stdout)
}

func getTerminalWidth() -> Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w) == 0 && w.ws_col > 0 {
        return Int(w.ws_col)
    }
    return 80
}

func printSeparator() {
    let width = getTerminalWidth()
    printColor(String(repeating: "─", count: width) + "\n", color: "gray")
}

typealias ReadlineFunc = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
typealias AddHistoryFunc = @convention(c) (UnsafePointer<CChar>?) -> Void
typealias HistoryIOFunc = @convention(c) (UnsafePointer<CChar>?) -> Int32

struct ReadlineWrapper {
    nonisolated(unsafe) static var readline: ReadlineFunc?
    nonisolated(unsafe) static var addHistory: AddHistoryFunc?
    nonisolated(unsafe) static var writeHistory: HistoryIOFunc?

    static var historyFilePath: String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
        let dir = home + "/.cache/TurboFieldfareAgent"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir + "/history.txt"
    }

    nonisolated(unsafe) static var sigintSource: DispatchSourceSignal?
    nonisolated(unsafe) static var ctrlCCount = 0
    nonisolated(unsafe) static var lastCtrlCTime = Date.distantPast

    static func setup() {
        if let handle = dlopen("/usr/lib/libedit.dylib", RTLD_NOW) {
            typealias RlBindFunc = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
            if let sym = dlsym(handle, "rl_variable_bind") {
                let bind = unsafeBitCast(sym, to: RlBindFunc.self)
                _ = bind("editing-mode", "emacs")
            }
            typealias VoidFunc = @convention(c) () -> Void
            if let sym = dlsym(handle, "using_history") {
                let usingHistory = unsafeBitCast(sym, to: VoidFunc.self)
                usingHistory()
            }
            if let sym = dlsym(handle, "readline") {
                readline = unsafeBitCast(sym, to: ReadlineFunc.self)
            }
            if let sym = dlsym(handle, "add_history") {
                addHistory = unsafeBitCast(sym, to: AddHistoryFunc.self)
            }
            if let sym = dlsym(handle, "read_history") {
                let readHistory = unsafeBitCast(sym, to: HistoryIOFunc.self)
                if let path = historyFilePath {
                    _ = readHistory(path)
                }
            }
            if let sym = dlsym(handle, "write_history") {
                writeHistory = unsafeBitCast(sym, to: HistoryIOFunc.self)
            }
        }
        
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource?.setEventHandler {
            if Date().timeIntervalSince(lastCtrlCTime) > 3.0 {
                ctrlCCount = 0
            }
            ctrlCCount += 1
            lastCtrlCTime = Date()
            
            if ctrlCCount >= 2 {
                print("\n[Force Exited by User]")
                exit(1)
            } else {
                print("\n[Press ctrl-c again to exit]")
            }
        }
        sigintSource?.resume()
    }

    static func read(prompt: String) -> String? {
        if readline == nil { setup() }

        if let rl = readline {
            guard let cStr = rl(prompt) else { return nil }
            ctrlCCount = 0 // reset on success
            signal(SIGINT, SIG_IGN)
            defer { free(cStr) }
            
            let str = String(cString: cStr)
            if !str.isEmpty {
                addHistory?(cStr)
                if let path = historyFilePath {
                    _ = writeHistory?(path)
                }
            }
            return str
        } else {
            print(prompt, terminator: "")
            fflush(stdout)
            return Swift.readLine()
        }
    }
}


// MARK: - Main
@main
struct AgentCLI {
    static func main() async throws {
        let config = try AgentConfig()
        let runtime = try await AgentRuntime(config: config)
        let session = AgentSession(runtime: runtime)
        try await session.startRepl()
    }
}
