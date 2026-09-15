import Foundation
import TurboFieldfare

class AgentSession {
    let runtime: AgentRuntime
    var messages: [GFTokenizer.Message]

    init(runtime: AgentRuntime) {
        self.runtime = runtime
        self.messages = [
            GFTokenizer.Message(role: .system, content: runtime.config.systemPrompt, toolCalls: [], toolCallID: nil, name: nil)
        ]
    }

    func startRepl() async throws {
        while true {
            print("")
            printSeparator()
            let prompt = "\u{01}\u{001B}[32m\u{02}> \u{01}\u{001B}[0m\u{02}"
            guard let userInput = ReadlineWrapper.read(prompt: prompt) else { break }
            printSeparator()
            
            if userInput.isEmpty { continue }
            if userInput == "/exit" || userInput == "/quit" { break }

            if userInput.hasPrefix("!") {
                let cmdStr = String(userInput.dropFirst()).trimmingCharacters(in: .whitespaces)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", cmdStr]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                printColor("\n● Shell: \(cmdStr)\n", color: "green")
                try? process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                var outputStr = String(data: data, encoding: .utf8) ?? ""
                if outputStr.isEmpty { outputStr = "(No output)" }

                let displayRes = outputStr.count > 2000 ? String(outputStr.prefix(2000)) + "... (truncated)" : outputStr
                printColor("   \(displayRes)\n", color: "gray")

                let contextStr = "[User Executed Shell Command]: \(cmdStr)\n[Output]:\n\(displayRes)"
                messages.append(GFTokenizer.Message(role: .user, content: contextStr, toolCalls: [], toolCallID: nil, name: nil))
                continue
            }

            var finalInput = userInput
            if userInput.hasPrefix("/") {
                let parts = userInput.split(separator: " ", maxSplits: 1)
                if let command = parts.first {
                    let cmdName = String(command.dropFirst())
                    let args = parts.count > 1 ? String(parts[1]) : ""

                    let skillPath = "docs/agent/skills/\(cmdName).md"
                    if let skillContent = try? String(contentsOfFile: skillPath, encoding: .utf8) {
                        printColor("[Loaded skill /\(cmdName) from \(skillPath)]\n", color: "blue")
                        finalInput = "[Skill: \(cmdName)]\n\(skillContent)\n\nUser Request:\n\(args)"
                    } else {
                        printColor("Warning: Skill '/\(cmdName)' not found at \(skillPath)\n", color: "yellow")
                        continue
                    }
                }
            }

            messages.append(GFTokenizer.Message(role: .user, content: finalInput, toolCalls: [], toolCallID: nil, name: nil))

            var turnActive = true
            while turnActive {
                do {
                    let (content, calls) = try await runtime.generate(messages: messages)
                    var hCalls: [GFTokenizer.HistoricalToolCall] = []
                    for call in calls {
                        hCalls.append(GFTokenizer.HistoricalToolCall(id: call.id, name: call.name, arguments: call.arguments))
                    }
                    messages.append(GFTokenizer.Message(role: .assistant, content: content.isEmpty ? nil : content, toolCalls: hCalls, toolCallID: nil, name: nil))

                    if !calls.isEmpty {
                        for call in calls {
                            var argString = ""
                            if case .object(let map) = call.arguments {
                                if let c = map["command"], case .string(let s) = c { argString = s.replacingOccurrences(of: "\n", with: " ") }
                                else if let p = map["path"], case .string(let s) = p { argString = s }
                                else if let q = map["query"], case .string(let s) = q { argString = s }
                                else if let pr = map["prompt"], case .string(let s) = pr { argString = s }
                                else if let url = map["url"], case .string(let s) = url { argString = s }
                                else { argString = map.keys.joined(separator: ", ") }
                                if argString.count > 60 { argString = String(argString.prefix(60)) + "..." }
                            }
                            printColor("\n● \(call.name)(\(argString))\n", color: "green")
                            let resultStr = await ToolRegistry.execute(call: call, runtime: runtime)
                            printColor("   \(resultStr.prefix(300))\(resultStr.count > 300 ? "..." : "")\n", color: "yellow")
                            messages.append(GFTokenizer.Message(role: .tool, content: resultStr, toolCalls: [], toolCallID: call.id, name: call.name))
                        }
                    } else {
                        turnActive = false
                    }
                } catch {
                    printColor("\n[Error: \(error)]\n", color: "yellow")
                    // Pop the offending message so the user can continue
                    if !messages.isEmpty { messages.removeLast() }
                    turnActive = false
                }
                }
            }
        }
    }
