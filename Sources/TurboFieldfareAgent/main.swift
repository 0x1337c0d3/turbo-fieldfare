import Foundation
import TurboFieldfare
import TurboFieldfareCLICore

let rawArgv = Array(CommandLine.arguments.dropFirst())
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

func runAgent() async throws {
    let modelURL = URL(fileURLWithPath: args.model)
    let context = try MetalContext()
    let runtime = try args.resolvedRuntimeConfiguration(forceLogitsHead: false, imagePrompt: false)
    
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
    
    var messages: [GFTokenizer.Message] = [
        GFTokenizer.Message(role: .system, content: "You are a native Swift agent. You can execute tools natively.", toolCalls: [], toolCallID: nil, name: nil)
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
        guard let userInput = readLine(), !userInput.isEmpty else { continue }
        
        if userInput == "/exit" || userInput == "/quit" { break }
        
        messages.append(GFTokenizer.Message(role: .user, content: userInput, toolCalls: [], toolCallID: nil, name: nil))
        
        var turnActive = true
        while turnActive {
            // Encode the full message history with tools
            let promptIds = try tokenizer.encodeToolChat(messages: messages, tools: tools)
            
            // Calculate prefix match for KV-cache reuse
            var matchCount = 0
            for i in 0..<min(previousPromptIds.count, promptIds.count) {
                if previousPromptIds[i] == promptIds[i] { matchCount += 1 }
                else { break }
            }
            
            let start: RawCompletionStart = matchCount > 0 ? .resume(cachedPromptTokens: matchCount) : .reset
            
            let decoder = StructuredAssistantDecoder(
                tokenizer: tokenizer,
                allowedTools: Set(tools.map { $0.name })
            )
            
            printColor("Generating... ", color: "blue")
            var currentContent = ""
            var currentCalls: [ParsedToolCall] = []
            
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
                                currentContent += text
                                print(text, terminator: "")
                                fflush(stdout)
                            case .toolCall(let call):
                                currentCalls.append(call)
                            }
                        }
                    case .tail(let text):
                        let decoderEvents = (try? decoder.consumeTail(text)) ?? []
                        for dev in decoderEvents {
                            if case .content(let t) = dev {
                                currentContent += t
                                print(t, terminator: "")
                                fflush(stdout)
                            } else if case .toolCall(let call) = dev {
                                currentCalls.append(call)
                            }
                        }
                    }
                }
            )
            
            _ = try? decoder.finish()
            print("")
            
            // Append assistant response to messages
            var hCalls: [GFTokenizer.HistoricalToolCall] = []
            for call in currentCalls {
                hCalls.append(GFTokenizer.HistoricalToolCall(id: call.id, name: call.name, arguments: call.arguments))
            }
            messages.append(GFTokenizer.Message(role: .assistant, content: currentContent.isEmpty ? nil : currentContent, toolCalls: hCalls, toolCallID: nil, name: nil))
            
            // We just generated and appended the turn, but the previousPromptIds tracking gets messy.
            // Let's reset the KV cache context tracking for simplicity.
            previousPromptIds = []
            
            if !currentCalls.isEmpty {
                // Execute tools natively
                for call in currentCalls {
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
                // Loop again to let the model respond to the tool!
            } else {
                turnActive = false
            }
        }
    }
}

let box = RunBox()
let sem = DispatchSemaphore(value: 0)
box.task = Task {
    do {
        try await runAgent()
        box.code = 0
    } catch {
        print("Fatal error: \(error)")
        box.code = 1
    }
    sem.signal()
}

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigintSource.setEventHandler { box.task?.cancel(); exit(0) }
sigintSource.resume()
sem.wait()
exit(box.code)

final class RunBox: @unchecked Sendable {
    var code: Int32 = 0
    var task: Task<Void, Never>?
}
