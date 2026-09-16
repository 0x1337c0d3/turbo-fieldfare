import Foundation
import TurboFieldfare

enum RouteTarget {
    case local
    case cloud
}

struct HybridRouter {
    let localRuntime: AgentRuntime
    let cloudClient: OpenAIClient?

    func decide(messages: [GFTokenizer.Message]) async throws -> RouteTarget {
        guard cloudClient != nil else { return .local }
        
        let spinnerTask = Task {
            let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            var index = 0
            while !Task.isCancelled {
                AgentTerminal.write("\r\u{001B}[34m\(frames[index % frames.count]) Routing...\u{001B}[0m\u{001B}[K")
                index += 1
                do { try await Task.sleep(for: .milliseconds(80)) } catch { break }
            }
            AgentTerminal.write("\r\u{001B}[K")
        }
        
        let target: RouteTarget
        do {
            if let heuristic = checkHeuristics(messages: messages) {
                target = heuristic
            } else {
                target = try await askLocalRouter(messages: messages)
            }
        }
        
        spinnerTask.cancel()
        _ = await spinnerTask.value
        return target
    }
    
    private func checkHeuristics(messages: [GFTokenizer.Message]) -> RouteTarget? {
        let text = messages.last?.content ?? ""
        let textLower = text.lowercased()
        
        if text.count > 4_000 { return .cloud }
        
        let cloudKeywords = ["search the web", "generate image", "summarize 100", "complex reasoning", "write an essay"]
        for kw in cloudKeywords {
            if textLower.contains(kw) { return .cloud }
        }
        
        let localKeywords = ["format this string", "what time is it", "ping", "hello", "hi"]
        for kw in localKeywords {
            if textLower.contains(kw) { return .local }
        }
        
        return nil
    }
    
    private func askLocalRouter(messages: [GFTokenizer.Message]) async throws -> RouteTarget {
        let classifierPrompt = """
        You are a routing agent. Decide if the user's request requires a powerful cloud model (complex reasoning, heavy coding) or can be handled locally (simple questions, summaries, text formatting).
        Output exactly one word: LOCAL or CLOUD.
        """
        
        let routingMessages = [GFTokenizer.Message(role: .system, content: classifierPrompt, toolCalls: [], toolCallID: nil, name: nil)] + messages
        
        // Run a fast, 5-token inference on the local model
        let (content, _) = try await localRuntime.generateLocally(
            messages: routingMessages,
            tools: nil,
            interaction: nil,
            maxNewTokensOverride: 5,
            silent: true
        )
        
        return content.uppercased().contains("CLOUD") ? .cloud : .local
    }
}
