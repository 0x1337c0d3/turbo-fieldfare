import Foundation
import TurboFieldfare

enum RoutingMode: String {
  case auto = "Auto (Hybrid)"
  case forceLocal = "Local (Embedded)"
  case forceCloud = "Remote (OpenAI)"
}

final class AgentState: @unchecked Sendable {
  var content = ""
  var calls: [ParsedToolCall] = []
}

// MARK: - AgentRuntime
// Access is serialized by the REPL or AgentCore.
final class AgentRuntime: @unchecked Sendable {
  let config: AgentConfig
  var appleBackend: AppleFoundationModelBackend?
  var openAIBackend: OpenAICompatibleBackend?
  var gemmaBackend: MetalGemmaBackend?
  let statusLine = AgentStatusLine()

  var remainingToolCalls = 64
  var subagentDepth = 0

  var lastStopReason: StopReason = .endOfTurn

  var routingMode: RoutingMode = .auto
  var openAIClient: OpenAIClient? = OpenAIClient()

  var committedTokenIDs: [Int32] {
    get { gemmaBackend?.committedTokenIDs ?? _committedTokenIDs }
    set {
      _committedTokenIDs = newValue
      gemmaBackend?.committedTokenIDs = newValue
    }
  }
  private var _committedTokenIDs: [Int32] = []

  /// Concrete inference targets supported by the agent.
  public enum ModelTarget: String, Sendable, CaseIterable {
    case appleOnDevice = "apple-local"
    case appleCloud = "apple-pcc"
    case openai = "openai"
    case gemma = "gemma"

    public var label: String {
      switch self {
      case .appleOnDevice: return "Apple AFM 3 Core (On-Device Local)"
      case .appleCloud: return "Apple AFM Cloud Pro (Private Cloud Compute)"
      case .openai: return "OpenAI / OpenRouter"
      case .gemma: return "Gemma 4 (Local Metal)"
      }
    }

    public var isLocal: Bool {
      switch self {
      case .appleOnDevice, .gemma: return true
      case .appleCloud, .openai: return false
      }
    }
  }

  /// Current active model target.
  var currentTarget: ModelTarget {
    switch activeBackendKind {
    case .apple:
      return (applePCCPolicy == .disable) ? .appleOnDevice : .appleCloud
    case .openai:
      return .openai
    case .gemma:
      return .gemma
    }
  }

  /// Targets available for Shift-Tab cycling — includes both local and cloud options.
  var availableTargets: [ModelTarget] {
    var targets: [ModelTarget] = []
    if appleBackend != nil {
      targets.append(.appleOnDevice)
      targets.append(.appleCloud)
    }
    if openAIBackend != nil {
      targets.append(.openai)
    }
    if hasGemmaModel || gemmaBackend != nil {
      targets.append(.gemma)
    }
    return targets.isEmpty ? [.appleOnDevice] : targets
  }

  /// Whether a local Gemma .gturbo model directory exists.
  var hasGemmaModel: Bool {
    FileManager.default.fileExists(atPath: config.defaultModelURL.path)
  }

  /// Switches active execution target and updates status line context ceiling.
  func switchTo(target: ModelTarget) {
    switch target {
    case .appleOnDevice:
      activeBackendKind = .apple
      applePCCPolicy = .disable
      statusLine.snapshot.maxContext = appleBackend?.capabilities.maxContextLength ?? 8_192
      statusLine.snapshot.modelLabel = "AFM On-Device"
      statusLine.refresh(force: true)

    case .appleCloud:
      activeBackendKind = .apple
      applePCCPolicy = .require
      statusLine.snapshot.maxContext = 32_768
      statusLine.snapshot.modelLabel = "AFM Cloud (PCC)"
      statusLine.refresh(force: true)

    case .openai:
      activeBackendKind = .openai
      statusLine.snapshot.maxContext = openAIBackend?.capabilities.maxContextLength ?? 128_000
      statusLine.snapshot.modelLabel = openAIBackend.map { "\($0.client.modelName)" } ?? "OpenAI"
      statusLine.refresh(force: true)
      if let backend = openAIBackend {
        Task {
          _ = await backend.updateContextLength()
          if self.currentTarget == .openai {
            self.statusLine.snapshot.maxContext = backend.capabilities.maxContextLength
            self.statusLine.refresh(force: true)
          }
        }
      }

    case .gemma:
      activeBackendKind = .gemma
      statusLine.snapshot.maxContext = config.args.maxContext
      statusLine.snapshot.modelLabel = "Gemma 4 Metal"
      statusLine.refresh(force: true)
    }
    resetToolBudget()
  }

  /// The maximum rounds allowed for the active model target.
  /// Turn limits apply only to on-device local models (Gemma 4 and AFM 3 On-Device Core).
  /// Cloud models (OpenAI/OpenRouter and AFM 3 Private Cloud Compute) are unbounded by default.
  var effectiveMaxRounds: Int {
    if let explicit = config.explicitMaxRounds {
      return explicit
    }
    if currentTarget.isLocal {
      return config.maxRounds
    }
    return Int.max
  }

  /// Resets the remaining tool execution budget for a turn based on effectiveMaxRounds.
  func resetToolBudget() {
    let rounds = effectiveMaxRounds
    if rounds == Int.max {
      remainingToolCalls = Int.max
    } else {
      remainingToolCalls = max(64, rounds * 2)
    }
  }

  /// Ensures the local Gemma Metal model is loaded into memory on demand.
  func ensureGemmaLoaded() async throws -> MetalGemmaBackend {
    if let gemma = gemmaBackend { return gemma }
    let modelURL = config.defaultModelURL
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw MetalGemmaError.modelNotFound(modelURL.path)
    }
    printColor(
      "\n[Loading Gemma 4 Local Metal from \(modelURL.lastPathComponent)...]\n", color: "blue")
    let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
    self.gemmaBackend = gemma
    return gemma
  }

  /// The currently active backend interface based on activeBackendKind.
  var backend: any InferenceBackend {
    switch activeBackendKind {
    case .apple:
      if let apple = appleBackend { return apple }
    case .openai:
      if let openAI = openAIBackend { return openAI }
    case .gemma:
      if let gemma = gemmaBackend { return gemma }
      return FallbackGemmaCapabilitiesBackend(maxContext: config.args.maxContext)
    }
    if let apple = appleBackend { return apple }
    if let openAI = openAIBackend { return openAI }
    if let gemma = gemmaBackend { return gemma }
    fatalError("No inference backend initialized")
  }

  /// Live PCC policy for the Apple backend. Changing this takes effect on the next generate() call.
  var applePCCPolicy: PCCPolicy {
    get { appleBackend?.pccPolicy ?? config.pccPolicy }
    set { appleBackend?.pccPolicy = newValue }
  }

  /// The backend currently active for generation. Changed live by the Shift-Tab toggle.
  var activeBackendKind: AgentBackendKind

  /// Backends available for Shift-Tab cycling — only those with initialised objects/clients.
  var availableBackends: [AgentBackendKind] {
    var list: [AgentBackendKind] = []
    if appleBackend != nil { list.append(.apple) }
    if openAIBackend != nil { list.append(.openai) }
    if gemmaBackend != nil || hasGemmaModel { list.append(.gemma) }
    return list.isEmpty ? [activeBackendKind] : list
  }

  init(config: AgentConfig) async throws {
    self.config = config
    self.activeBackendKind = config.backend
    resetToolBudget()

    if let rm = config.routingMode {
      switch rm {
      case "local": self.routingMode = .forceLocal
      case "cloud": self.routingMode = .forceCloud
      case "auto": self.routingMode = .auto
      default: break
      }
    }

    // 1. Initialize Apple backend if supported on macOS 27+
    #if canImport(FoundationModels)
      if #available(macOS 27.0, *) {
        self.appleBackend = AppleFoundationModelBackend(
          pccPolicy: config.pccPolicy,
          systemPrompt: config.systemPrompt,
          statusLine: statusLine
        )
      }
    #endif

    // 2. Initialize OpenAI backend if configuration is present
    if let client = openAIClient {
      let backend = try? OpenAICompatibleBackend(client: client, statusLine: statusLine)
      self.openAIBackend = backend
      if let backend {
        Task {
          _ = await backend.updateContextLength()
          if self.currentTarget == .openai {
            self.statusLine.snapshot.maxContext = backend.capabilities.maxContextLength
            self.statusLine.refresh(force: true)
          }
        }
      }
    }

    // 3. Initialize Gemma backend if explicitly requested
    if config.backend == .gemma {
      let gemma = try await MetalGemmaBackend(config: config, statusLine: statusLine)
      self.gemmaBackend = gemma
    } else {
      self.gemmaBackend = nil
    }

    // Fallbacks if requested backend could not be initialized
    if config.backend == .apple && self.appleBackend == nil {
      printColor(
        "[Apple Foundation Models require macOS 27.0 (Golden Gate) or later with FoundationModels. Falling back...]\n",
        color: "yellow")
      if self.openAIBackend != nil {
        self.activeBackendKind = .openai
      } else if hasGemmaModel {
        self.activeBackendKind = .gemma
      }
    } else if config.backend == .openai && self.openAIBackend == nil {
      if self.appleBackend != nil {
        self.activeBackendKind = .apple
      } else if hasGemmaModel {
        self.activeBackendKind = .gemma
      }
    }

    // Set the initial status-bar model label based on the resolved active backend.
    switch activeBackendKind {
    case .apple:
      statusLine.snapshot.modelLabel =
        (config.pccPolicy == .require) ? "AFM Cloud (PCC)" : "AFM On-Device"
    case .openai:
      statusLine.snapshot.modelLabel =
        openAIClient.map { $0.modelName } ?? "OpenAI"
    case .gemma:
      statusLine.snapshot.modelLabel = "Gemma 4 Metal"
    }
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]? = nil,
    interaction: AgentInteraction? = nil,
    cancellation: AgentCancellation? = nil,
    terminal: TerminalGeneration? = nil,
    forceLocal: Bool = false
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    let definitions = tools ?? ToolRegistry.definitions

    switch activeBackendKind {
    case .apple:
      if let apple = appleBackend {
        return try await apple.generate(
          messages: messages, tools: definitions, interaction: interaction,
          cancellation: cancellation, terminal: terminal)
      }

    case .openai:
      if let openAI = openAIBackend {
        lastStopReason = .endOfTurn
        return try await openAI.generate(
          messages: messages, tools: definitions, interaction: interaction,
          cancellation: cancellation, terminal: terminal)
      }

    case .gemma:
      let _ = try await ensureGemmaLoaded()
      if gemmaBackend != nil {
        var target: RouteTarget = .local
        if forceLocal {
          target = .local
        } else {
          switch routingMode {
          case .forceLocal:
            target = .local
          case .forceCloud:
            target = .cloud
          case .auto:
            let router = HybridRouter(
              backendKind: config.backend,
              pccPolicy: config.pccPolicy,
              localRuntime: self,
              cloudClient: openAIClient
            )
            target = try await router.decide(messages: messages)
          }
        }

        if target == .cloud, let openAI = openAIBackend {
          if interaction == nil {
            terminalPrint("\n\u{001B}[33m[Auto-Routed to Cloud (OpenAI)]\u{001B}[0m\n")
          }
          do {
            let result = try await openAI.generate(
              messages: messages, tools: definitions, interaction: interaction,
              cancellation: cancellation, terminal: terminal)
            lastStopReason = .endOfTurn
            return result
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            if interaction == nil {
              terminalPrint(
                "\n\u{001B}[31m[Cloud route failed: \(error). Falling back to Local...]\u{001B}[0m\n"
              )
            }
            return try await generateLocally(
              messages: messages, tools: definitions, interaction: interaction,
              cancellation: cancellation, terminal: terminal)
          }
        } else {
          if routingMode == .auto && interaction == nil {
            terminalPrint("\n\u{001B}[32m[Auto-Routed to Local (Embedded)]\u{001B}[0m\n")
          }
          return try await generateLocally(
            messages: messages, tools: definitions, interaction: interaction,
            cancellation: cancellation, terminal: terminal)
        }
      }
    }

    return try await backend.generate(
      messages: messages, tools: definitions, interaction: interaction,
      cancellation: cancellation, terminal: terminal)
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
    if let gemma = gemmaBackend {
      let result = try await gemma.generateLocally(
        messages: messages,
        tools: tools,
        interaction: interaction,
        cancellation: cancellation,
        terminal: terminal,
        maxNewTokensOverride: maxNewTokensOverride,
        silent: silent
      )
      self.lastStopReason = gemma.lastStopReason
      return result
    } else {
      return try await backend.generate(
        messages: messages, tools: tools, interaction: interaction,
        cancellation: cancellation, terminal: terminal)
    }
  }
}

/// Fallback capabilities representation for Gemma before weights are loaded into memory.
private struct FallbackGemmaCapabilitiesBackend: InferenceBackend {
  let capabilities: BackendCapabilities

  init(maxContext: Int) {
    self.capabilities = BackendCapabilities(
      name: "Metal Gemma 4 (Local Metal)",
      supportsTools: true,
      supportsStreaming: true,
      maxContextLength: maxContext,
      isOnDevice: true,
      isPrivateCloudCompute: false
    )
  }

  func generate(
    messages: [GFTokenizer.Message],
    tools: [GFTokenizer.FunctionDefinition]?,
    interaction: AgentInteraction?
  ) async throws -> (content: String, calls: [ParsedToolCall]) {
    fatalError("ensureGemmaLoaded() must be called before generate()")
  }
}
