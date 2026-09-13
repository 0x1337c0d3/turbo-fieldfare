import Foundation
import TurboFieldfare
import TurboFieldfareCLICore

final class AgentState: @unchecked Sendable {
    var content = ""
    var calls: [ParsedToolCall] = []
}

@main
struct AgentCLI {
    static func main() async throws {
        try await run()
    }
    
    nonisolated static func run() async throws {
        var rawArgv = Array(CommandLine.arguments.dropFirst())
        
        var systemPromptPath: String?
        var agentsFilePath: String?
        
        var i = 0
        while i < rawArgv.count {
            if rawArgv[i] == "--system-prompt", i + 1 < rawArgv.count {
                systemPromptPath = rawArgv[i + 1]
                rawArgv.remove(at: i)
                rawArgv.remove(at: i)
            } else if rawArgv[i] == "--agents-file", i + 1 < rawArgv.count {
                agentsFilePath = rawArgv[i + 1]
                rawArgv.remove(at: i)
                rawArgv.remove(at: i)
            } else {
                i += 1
            }
        }
        
        if !rawArgv.contains("--prompt") && !rawArgv.contains("--chat-prompt") && !rawArgv.contains("--messages-file") {
            rawArgv.append("--prompt")
            rawArgv.append("agent")
        }
        let args: Args
        do {
            args = try Args.parse(rawArgv)
        } catch ArgsError.helpRequested {
            print(Args.usage)
            exit(0)
        } catch {
            print("error: \(error)")
            exit(2)
        }
        
        let modelURL = URL(fileURLWithPath: args.model)
        let context = try MetalContext()
        let runtime = try args.resolvedRuntimeConfiguration(forceLogitsHead: true, imagePrompt: false)
        
        printColor("Loading Gemma 4 Agent from \(args.model)...\n", color: "blue")
        
        let model = try Model.load(
            directoryURL: modelURL,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: .fullSha256)
            
        let runner = try RealForwardRunner(
            model: model,
            context: context,
            maxContext: args.maxContext,
            runtimeConfiguration: runtime)
            
        let scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
        let tokenizer = try await GFTokenizer.load(forModelDirectory: modelURL)
        
        var masterSystemPrompt = "You are a native Swift agent. You can execute tools natively.\n"
        if let path = systemPromptPath {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                masterSystemPrompt = content
            } else {
                printColor("Warning: Could not read system prompt at \(path)\n", color: "yellow")
            }
        }
        if let path = agentsFilePath {
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                masterSystemPrompt += "\n\n## Agent Guidelines\n\(content)"
            } else {
                printColor("Warning: Could not read agents file at \(path)\n", color: "yellow")
            }
        }
        
        var messages: [GFTokenizer.Message] = [
            GFTokenizer.Message(role: .system, content: masterSystemPrompt, toolCalls: [], toolCallID: nil, name: nil)
        ]
        
        let tools: [GFTokenizer.FunctionDefinition] = [
            GFTokenizer.FunctionDefinition(
                name: "execute_bash",
                description: "Executes a shell command natively",
                parameters: .object([
                    "command": .object(["type": .string("string")])
                ])
            )
        ]
        
        var previousPromptIds: [Int32] = []
        
        while true {
            printColor("\nAgent> ", color: "green")
            guard let userInput = readLine() else { break }
            if userInput.isEmpty { continue }
            
            if userInput == "/exit" || userInput == "/quit" { break }
            
            messages.append(GFTokenizer.Message(role: .user, content: userInput, toolCalls: [], toolCallID: nil, name: nil))
            
            var turnActive = true
            while turnActive {
                let promptIds = try tokenizer.encodeToolChat(messages: messages, tools: tools)
                var matchCount = 0
                for i in 0..<min(previousPromptIds.count, promptIds.count) {
                    if previousPromptIds[i] == promptIds[i] { matchCount += 1 }
                    else { break }
                }
                
                let start: RawCompletionStart = matchCount > 0 ? .resume(cachedPromptTokens: matchCount) : .reset
                let decoder = StructuredAssistantDecoder(tokenizer: tokenizer, allowedTools: Set(tools.map { $0.name }))
                
                printColor("Generating... ", color: "blue")
                
                let state = AgentState()
                
                _ = try await runRawCompletion(
                    producer: runner,
                    tokenizer: tokenizer,
                    promptIds: promptIds,
                    config: GenerationConfig(
                        maxNewTokens: args.maxNew,
                        temperature: args.temperature,
                        topK: args.topK,
                        topP: args.topP,
                        repetitionPenalty: args.repetitionPenalty,
                        seed: args.seed,
                        stopStrings: args.stops,
                        extraStopTokens: []
                    ),
                    context: context,
                    scratch: scratch,
                    start: start,
                    onProgress: { event in
                        switch event {
                        case .prefill: break
                        case .token(_, let tokenID, let delta):
                            let decoderEvents = (try? decoder.consume(tokenID: tokenID, delta: delta)) ?? []
                            for dev in decoderEvents {
                                switch dev {
                                case .content(let text):
                                    state.content += text
                                    print(text, terminator: "")
                                    fflush(stdout)
                                case .toolCall(let call):
                                    state.calls.append(call)
                                }
                            }
                        case .tail(let text):
                            let decoderEvents = (try? decoder.consumeTail(text)) ?? []
                            for dev in decoderEvents {
                                if case .content(let t) = dev {
                                    state.content += t
                                    print(t, terminator: "")
                                    fflush(stdout)
                                } else if case .toolCall(let call) = dev {
                                    state.calls.append(call)
                                }
                            }
                        }
                    }
                )
                
                _ = try? decoder.finish()
                print("")
                
                var hCalls: [GFTokenizer.HistoricalToolCall] = []
                for call in state.calls {
                    hCalls.append(GFTokenizer.HistoricalToolCall(id: call.id, name: call.name, arguments: call.arguments))
                }
                messages.append(GFTokenizer.Message(role: .assistant, content: state.content.isEmpty ? nil : state.content, toolCalls: hCalls, toolCallID: nil, name: nil))
                
                previousPromptIds = []
                
                if !state.calls.isEmpty {
                    for call in state.calls {
                        printColor("[Executing Tool: \(call.name)]\n", color: "yellow")
                        var resultStr = ""
                        if call.name == "execute_bash" {
                            if case .object(let argsMap) = call.arguments, case .string(let cmd) = argsMap["command"] {
                                let process = Process()
                                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                                process.arguments = ["-c", cmd]
                                let pipe = Pipe()
                                process.standardOutput = pipe
                                process.standardError = pipe
                                do {
                                    try process.run()
                                    process.waitUntilExit()
                                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                                    resultStr = String(data: data, encoding: .utf8) ?? ""
                                } catch {
                                    resultStr = "Error: \(error)"
                                }
                            } else {
                                resultStr = "Error: invalid arguments"
                            }
                        } else {
                            resultStr = "Error: unknown tool"
                        }
                        printColor("\(resultStr)\n", color: "yellow")
                        messages.append(GFTokenizer.Message(role: .tool, content: resultStr, toolCalls: [], toolCallID: call.id, name: call.name))
                    }
                } else {
                    turnActive = false
                }
            }
        }
    }
}

func printColor(_ text: String, color: String) {
    let colorCode: String
    switch color {
    case "green": colorCode = "\u{001B}[32m"
    case "yellow": colorCode = "\u{001B}[33m"
    case "blue": colorCode = "\u{001B}[34m"
    case "reset": colorCode = "\u{001B}[0m"
    default: colorCode = ""
    }
    print("\(colorCode)\(text)\u{001B}[0m", terminator: "")
    fflush(stdout)
}
