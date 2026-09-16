import Foundation
import TurboFieldfare

struct OpenAISettings: Decodable {
    let openai_api_key: String?
    let openai_base_url: String?
    let openai_model: String?
}

struct OpenAIRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String?
        let name: String?
        let tool_calls: [ToolCall]?
        let tool_call_id: String?
        
        struct ToolCall: Encodable {
            let id: String
            let type: String
            let function: FunctionCall
        }
        
        struct FunctionCall: Encodable {
            let name: String
            let arguments: String
        }
    }
    
    struct Tool: Encodable {
        let type: String
        let function: FunctionDef
        
        struct FunctionDef: Encodable {
            let name: String
            let description: String
            let parameters: JSONValue
        }
    }
    
    let model: String
    let messages: [Message]
    let tools: [Tool]?
}

struct OpenAIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let tool_calls: [ToolCall]?
            
            struct ToolCall: Decodable {
                let id: String
                let function: FunctionCall
                
                struct FunctionCall: Decodable {
                    let name: String
                    let arguments: String
                }
            }
        }
        let message: Message
    }
    let choices: [Choice]
}

fileprivate func resolveEnv(_ value: String) -> String {
    var resolved = value
    if resolved.hasPrefix("$") {
        let envVar = resolved.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if let envVal = ProcessInfo.processInfo.environment[envVar] {
            return envVal
        }
    } else if let envVal = ProcessInfo.processInfo.environment[resolved] {
        return envVal
    }
    return resolved
}

final class OpenAIClient: @unchecked Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let modelName: String

    init?() {
        let fm = FileManager.default
        let settingsURL = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/TurboFieldfareAgent/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(OpenAISettings.self, from: data),
              let key = settings.openai_api_key else {
            return nil
        }
        self.apiKey = resolveEnv(key)
        self.baseURL = URL(string: settings.openai_base_url ?? "https://api.openai.com/v1/")!
        self.modelName = settings.openai_model ?? "gpt-4o"
    }
    
    func generate(messages: [GFTokenizer.Message], tools: [GFTokenizer.FunctionDefinition]?) async throws -> (content: String, calls: [ParsedToolCall]) {
        let reqMessages = messages.map { msg -> OpenAIRequest.Message in
            let toolCalls = msg.toolCalls.isEmpty ? nil : msg.toolCalls.map { tc in
                OpenAIRequest.Message.ToolCall(
                    id: tc.id,
                    type: "function",
                    function: OpenAIRequest.Message.FunctionCall(name: tc.name, arguments: (try? tc.arguments.encoded()) ?? "{}")
                )
            }
            return OpenAIRequest.Message(
                role: msg.role.rawValue,
                content: msg.content,
                name: msg.name,
                tool_calls: toolCalls,
                tool_call_id: msg.toolCallID
            )
        }
        
        let reqTools = tools?.map { t in
            OpenAIRequest.Tool(
                type: "function",
                function: OpenAIRequest.Tool.FunctionDef(
                    name: t.name,
                    description: t.description,
                    parameters: t.parameters
                )
            )
        }
        
        let requestPayload = OpenAIRequest(model: modelName, messages: reqMessages, tools: reqTools)
        
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "api-key") // For Azure / Microsoft Foundry
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key") // For other generic gateways
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestPayload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 else {
            let errStr = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OpenAIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(errStr)"])
        }
        
        let res = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let message = res.choices.first?.message else {
            return ("", [])
        }
        
        var calls: [ParsedToolCall] = []
        if let toolCalls = message.tool_calls {
            for tc in toolCalls {
                let argsData = tc.function.arguments.data(using: .utf8)!
                let argsJSON = (try? JSONDecoder().decode(JSONValue.self, from: argsData)) ?? .object([:])
                calls.append(ParsedToolCall(id: tc.id, name: tc.function.name, arguments: argsJSON, argumentsJSON: tc.function.arguments))
            }
        }
        
        return (message.content ?? "", calls)
    }
}
