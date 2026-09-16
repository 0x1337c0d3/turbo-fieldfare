import Foundation
import TurboFieldfare

final class AgentState: @unchecked Sendable {
    var content = ""
    var calls: [ParsedToolCall] = []
}

// MARK: - AgentRuntime
// Access is serialized by the REPL or AgentCore.
final class AgentRuntime: @unchecked Sendable {
    let context: MetalContext
    let model: Model
    let runner: RealForwardRunner
    let scratch: RawCompletionScratch
    let tokenizer: GFTokenizer
    let config: AgentConfig

    let statusLine = AgentStatusLine()

    var remainingToolCalls = 64
    var subagentDepth = 0

    var lastStopReason: StopReason = .endOfTurn

    var committedTokenIDs: [Int32] = []

    init(config: AgentConfig) async throws {
        self.config = config
        let modelURL = URL(fileURLWithPath: config.args.model)
        self.context = try MetalContext()
        let runtime = try config.args.resolvedRuntimeConfiguration(forceLogitsHead: true, imagePrompt: false)

        printColor("Loading Gemma 4 Agent from \(config.args.model)...\n", color: "blue")

        self.model = try Model.load(
            directoryURL: modelURL,
            device: context.device,
            streamingMode: .pread(slotCount: runtime.expertCacheSlots),
            expertCachePolicy: runtime.modelExpertCachePolicy,
            integrityPolicy: .fullSha256)

        self.runner = try RealForwardRunner(
            model: model,
            context: context,
            maxContext: config.args.maxContext,
            runtimeConfiguration: runtime)

        self.scratch = try RawCompletionScratch(context: context, vocab: model.config.vocabSize)
        self.tokenizer = try await GFTokenizer.load(forModelDirectory: modelURL)
    }

    func generate(messages: [GFTokenizer.Message],
                  tools: [GFTokenizer.FunctionDefinition]? = nil,
                  interaction: AgentInteraction? = nil) async throws -> (content: String, calls: [ParsedToolCall]) {
        let definitions = tools ?? ToolRegistry.definitions
        let promptIds = try tokenizer.encodeToolChat(messages: messages, tools: definitions)
        let start = AgentPromptCache.start(
            prompt: promptIds, committed: committedTokenIDs,
            position: runner.continuationPosition, rewind: runner.rewind(to:))
        let cachedTokens: Int
        switch start {
        case .reset: cachedTokens = 0
        case .resume(let count): cachedTokens = count
        }
        // Any failure after this point may leave partially advanced KV state.
        // Only a successful completion supplies a trustworthy token record.
        committedTokenIDs.removeAll(keepingCapacity: true)
        let decoder = StructuredAssistantDecoder(tokenizer: tokenizer, allowedTools: Set(definitions.map { $0.name }))


        if interaction == nil { statusLine.beginGeneration(contextTokens: cachedTokens) }
        let state = AgentState()
        let cancellation = interaction?.cancellation ?? AgentCancellation()
        let stopAfterTool = AgentCancellation()
        let terminal = interaction == nil ? TerminalGeneration(cancellation: cancellation) : nil
        defer { terminal?.restore() }

        func handleDecoderEvents(_ events: [StructuredAssistantEvent]) {
            for event in events {
                switch event {
                case .content(let text):
                    state.content += text
                    if let interaction { interaction.text(text) }
                    else { terminal?.text(text) }
                case .toolCall(let call):
                    state.calls.append(call)
                    stopAfterTool.cancel()
                }
            }
        }

        let result: RawDecodeResult
        do {
            result = try await runRawCompletion(
                producer: runner,
                tokenizer: tokenizer,
                promptIds: promptIds,
                config: GenerationConfig(
                    maxNewTokens: config.args.maxNew,
                    temperature: config.args.temperature,
                    topK: config.args.topK,
                    topP: config.args.topP,
                    repetitionPenalty: config.args.repetitionPenalty,
                    seed: config.args.seed,
                    stopStrings: config.args.stops,
                    extraStopTokens: []
                ),
                context: context,
                scratch: scratch,
                start: start,
                shouldStop: { stopAfterTool.isCancelled || cancellation.isCancelled || Task.isCancelled },
                onProgress: { event in
                    switch event {
                    case .prefill(let done, _):
                        if interaction == nil { self.statusLine.prefill(done: done) }
                    case .token(let index, let tokenID, let delta):
                        if interaction == nil { self.statusLine.token(count: index + 1, contextTokens: promptIds.count + index) }
                        handleDecoderEvents((try? decoder.consume(tokenID: tokenID, delta: delta)) ?? [])
                    case .tail(let text):
                        handleDecoderEvents((try? decoder.consumeTail(text)) ?? [])
                    }
                }
            )
        } catch {
            await terminal?.finish()
            statusLine.snapshot.phase = "Error"
            statusLine.refresh(force: true)
            throw error
        }

        await terminal?.finish()

        _ = try? decoder.finish()

        if interaction == nil { statusLine.finish(tokens: result.newTokens, decodeSeconds: result.decodeSeconds, contextTokens: result.kvPosition) }
        lastStopReason = result.reason
        if interaction?.cancellation.isCancelled == true || Task.isCancelled {
            committedTokenIDs.removeAll()
            throw CancellationError()
        }
        self.committedTokenIDs = result.kvBackedTokenIDs
        return (state.content, state.calls)
    }
}
