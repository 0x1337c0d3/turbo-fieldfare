import Foundation
import TurboFieldfare

public enum MetalGemmaError: Error, CustomStringConvertible {
  case modelNotFound(String)

  public var description: String {
    switch self {
    case .modelNotFound(let path):
      return
        "Gemma 4 model file not found at \(path). Run 'swift run -c release TurboFieldfareRepack --output scratch/gemma4.gturbo' to install it, or use --backend apple."
    }
  }
}

final class MetalGemmaBackend: InferenceBackend, @unchecked Sendable {
  let capabilities: BackendCapabilities
  let context: MetalContext
  let model: Model
  let runner: RealForwardRunner
  let scratch: RawCompletionScratch
  let tokenizer: GFTokenizer
  let config: AgentConfig
  let statusLine: AgentStatusLine

  var committedTokenIDs: [Int32] = []
  var lastStopReason: StopReason = .endOfTurn

  init(config: AgentConfig, statusLine: AgentStatusLine? = nil) async throws {
    self.config = config
    self.statusLine = statusLine ?? AgentStatusLine()

    let modelURL: URL
    if config.args.model == "none" || config.args.model.isEmpty {
      modelURL = config.defaultModelURL
    } else {
      modelURL = URL(fileURLWithPath: config.args.model)
    }

    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw MetalGemmaError.modelNotFound(modelURL.path)
    }

    self.context = try MetalContext()
    let runtime = try config.args.resolvedRuntimeConfiguration(
      forceLogitsHead: true, imagePrompt: false)

    printColor("Loading Gemma 4 Agent from \(modelURL.path)...\n", color: "blue")

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

    self.capabilities = BackendCapabilities(
      name: "Metal Gemma 4 26B-A4B",
      supportsTools: true,
      supportsStreaming: true,
      maxContextLength: config.args.maxContext,
      isOnDevice: true,
      isPrivateCloudCompute: false
    )
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]?,
    interaction: AgentInteraction?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    return try await generateLocally(
      messages: messages,
      tools: tools,
      interaction: interaction
    )
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]?,
    interaction: AgentInteraction?,
    cancellation: AgentCancellation?,
    terminal: TerminalGeneration?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    return try await generateLocally(
      messages: messages,
      tools: tools,
      interaction: interaction,
      cancellation: cancellation,
      terminal: terminal
    )
  }

  func generateLocally(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]? = nil,
    interaction: AgentInteraction? = nil,
    cancellation: AgentCancellation? = nil,
    terminal: TerminalGeneration? = nil,
    maxNewTokensOverride: Int? = nil,
    silent: Bool = false
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
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

    if !silent { committedTokenIDs.removeAll(keepingCapacity: true) }
    let decoder = StructuredAssistantDecoder(
      tokenizer: tokenizer, allowedTools: Set(definitions.map { $0.name }), emitThoughts: true)

    if interaction == nil && !silent { statusLine.beginGeneration(contextTokens: cachedTokens) }
    let state = AgentState()
    let effectiveCancellation = interaction?.cancellation ?? cancellation ?? AgentCancellation()
    let stopAfterTool = AgentCancellation()
    let activeTerminal: TerminalGeneration?
    let ownsTerminal: Bool
    if interaction == nil && !silent {
      if let terminal {
        activeTerminal = terminal
        ownsTerminal = false
        terminal.beginGeneration()
      } else {
        activeTerminal = TerminalGeneration(cancellation: effectiveCancellation)
        ownsTerminal = true
      }
    } else {
      activeTerminal = nil
      ownsTerminal = false
    }
    defer {
      if ownsTerminal { activeTerminal?.restore() }
    }

    func handleDecoderEvents(_ events: [StructuredAssistantEvent]) {
      for event in events {
        switch event {
        case .content(let text):
          state.content += text
          if !silent {
            if let interaction { interaction.text(text) } else { activeTerminal?.text(text) }
          }
        case .thought(let text):
          if !silent {
            activeTerminal?.thought(text)
          }
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
          maxNewTokens: maxNewTokensOverride ?? config.args.maxNew,
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
        shouldStop: {
          stopAfterTool.isCancelled || effectiveCancellation.isCancelled || Task.isCancelled
        },
        onProgress: { event in
          switch event {
          case .prefill(let done, _):
            if interaction == nil && !silent { self.statusLine.prefill(done: done) }
          case .token(let index, let tokenID, let delta):
            if interaction == nil && !silent {
              self.statusLine.token(count: index + 1, contextTokens: promptIds.count + index)
            }
            handleDecoderEvents((try? decoder.consume(tokenID: tokenID, delta: delta)) ?? [])
          case .tail(let text):
            handleDecoderEvents((try? decoder.consumeTail(text)) ?? [])
          }
        }
      )
    } catch {
      if !silent {
        await activeTerminal?.finishGeneration()
        statusLine.snapshot.phase = "Error"
        statusLine.refresh(force: true)
      }
      throw error
    }

    if !silent { await activeTerminal?.finishGeneration() }
    _ = try? decoder.finish()

    if interaction == nil && !silent {
      statusLine.finish(
        tokens: result.newTokens, decodeSeconds: result.decodeSeconds,
        contextTokens: result.kvPosition)
    }

    if !silent {
      lastStopReason = result.reason
      if effectiveCancellation.isCancelled || result.reason == .cancelled || Task.isCancelled {
        committedTokenIDs.removeAll()
        throw CancellationError()
      }
      self.committedTokenIDs = result.kvBackedTokenIDs
    }
    return (state.content, state.calls)
  }
}
