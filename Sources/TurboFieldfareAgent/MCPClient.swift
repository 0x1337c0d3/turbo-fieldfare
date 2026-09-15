import Foundation
import TurboFieldfare

protocol MCPServerTransport: Sendable {
    var name: String { get }
    var connectionDetails: String { get }
    func callTool(name: String, argsJson: String) async -> String
    func listTools() async -> [GFTokenizer.FunctionDefinition]
}

final class MCPClient: @unchecked Sendable {
    nonisolated(unsafe) static var _shared_mcp_client: MCPClient? = MCPClient()
    static var shared: MCPClient? {
        get { return _shared_mcp_client }
        set { _shared_mcp_client = newValue }
    }

    final class ServerProcess: MCPServerTransport, @unchecked Sendable {
        let process: Process
        let inPipe = Pipe()
        let outPipe = Pipe()
        var requestId = 1
        let name: String
        let queue = DispatchQueue(label: "mcp.server.queue")

        var connectionDetails: String {
            let path = process.executableURL?.path ?? "unknown"
            let args = process.arguments?.joined(separator: " ") ?? ""
            return "\(path) \(args)"
        }

        init(name: String, command: String, args: [String], env: [String: String]?) throws {
            self.name = name
            process = Process()

            var executablePath = command
            if executablePath.hasPrefix("~") {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                executablePath = (home as NSString).appendingPathComponent(String(executablePath.dropFirst(2)))
            }

            if !executablePath.contains("/") {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executablePath] + args
            } else {
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = args
            }

            if let env = env {
                var currentEnv = ProcessInfo.processInfo.environment
                for (k, v) in env { currentEnv[k] = v }
                process.environment = currentEnv
            }

            process.standardInput = inPipe
            process.standardOutput = outPipe

            try process.run()

            let initReq = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"turbo-agent\",\"version\":\"1.0.0\"}}}\n"
            inPipe.fileHandleForWriting.write(initReq.data(using: .utf8)!)
            _ = readLineSync()

            let initNotif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
            inPipe.fileHandleForWriting.write(initNotif.data(using: .utf8)!)
        }

        deinit {
            process.terminate()
        }

        func readLineSync() -> String {
            var data = Data()
            let handle = outPipe.fileHandleForReading
            while true {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty { break }
                if byte == Data([10]) { break }
                data.append(byte)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        
        func listTools() async -> [GFTokenizer.FunctionDefinition] {
            return await withCheckedContinuation { cont in
                queue.async {
                    let reqId = self.requestId
                    self.requestId += 1
                    let req = "{\"jsonrpc\":\"2.0\",\"id\":\(reqId),\"method\":\"tools/list\"}\n"
                    self.inPipe.fileHandleForWriting.write(req.data(using: .utf8)!)

                    while true {
                        let line = self.readLineSync()
                        if line.isEmpty { break }
                        if line.contains("\"id\":\(reqId)") {
                            if let data = line.data(using: .utf8),
                               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let result = dict["result"] as? [String: Any],
                               let tools = result["tools"] as? [[String: Any]] {
                                var defs: [GFTokenizer.FunctionDefinition] = []
                                for t in tools {
                                    if let n = t["name"] as? String, let d = t["description"] as? String, let s = t["inputSchema"] {
                                        if let sData = try? JSONSerialization.data(withJSONObject: s),
                                           let sJSON = try? JSONDecoder().decode(JSONValue.self, from: sData) {
                                            defs.append(GFTokenizer.FunctionDefinition(name: n, description: d, parameters: sJSON))
                                        }
                                    }
                                }
                                cont.resume(returning: defs)
                                return
                            }
                            break
                        }
                    }
                    cont.resume(returning: [])
                }
            }
        }

        func callTool(name: String, argsJson: String) async -> String {
            return await withCheckedContinuation { cont in
                queue.async {
                    let reqId = self.requestId
                    self.requestId += 1

                    let req = "{\"jsonrpc\":\"2.0\",\"id\":\(reqId),\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":\(argsJson)}}\n"
                    self.inPipe.fileHandleForWriting.write(req.data(using: .utf8)!)

                    while true {
                        let line = self.readLineSync()
                        if line.isEmpty { break }
                        if line.contains("\"id\":\(reqId)") {
                            if let data = line.data(using: .utf8),
                               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                if let error = dict["error"] as? [String: Any] {
                                    let msg = error["message"] as? String ?? "Unknown"
                                    let code = error["code"] as? Int
                                    if code == -32601 || msg.lowercased().contains("not found") {
                                        cont.resume(returning: "TOOL_NOT_FOUND")
                                        return
                                    }
                                    cont.resume(returning: "Error: \(msg)")
                                    return
                                }
                                if let result = dict["result"] as? [String: Any],
                                   let content = result["content"] as? [[String: Any]],
                                   let text = content.first?["text"] as? String {
                                    cont.resume(returning: text)
                                    return
                                }
                            }
                            cont.resume(returning: "Failed to parse result from MCP: \(line)")
                            return
                        }
                    }
                    cont.resume(returning: "TOOL_NOT_FOUND")
                }
            }
        }
    }

    actor SSEProcess: MCPServerTransport {
        let name: String
        let url: URL
        let headers: [String: String]?
        var postURL: URL?
        var requestId = 1
        var pendingRequests: [Int: CheckedContinuation<Data, Never>] = [:]

        nonisolated var connectionDetails: String {
            return url.absoluteString
        }

        init(name: String, url: URL, headers: [String: String]?) {
            self.name = name
            self.url = url
            self.headers = headers
            Task {
                await startSSE()
            }
        }

        private func startSSE() async {
            var request = URLRequest(url: url)
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            if let headers = headers {
                for (k, v) in headers {
                    request.setValue(v, forHTTPHeaderField: k)
                }
            }
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                var currentEvent: String?
                for try await line in bytes.lines {
                    if line.hasPrefix("event: ") {
                        currentEvent = String(line.dropFirst(7))
                    } else if line.hasPrefix("data: ") {
                        let dataStr = String(line.dropFirst(6))
                        if currentEvent == "endpoint" {
                            if let newURL = URL(string: dataStr, relativeTo: url) {
                                self.postURL = newURL
                            }
                        } else {
                            if let data = dataStr.data(using: .utf8),
                               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let id = dict["id"] as? Int {
                                if let cont = pendingRequests.removeValue(forKey: id) {
                                    cont.resume(returning: data)
                                }
                            }
                        }
                    } else if line.isEmpty {
                        currentEvent = nil
                    }
                }
            } catch {
                print("SSE error for \(name): \(error)")
            }
        }
        
        func listTools() async -> [GFTokenizer.FunctionDefinition] {
            var attempt = 0
            while postURL == nil && attempt < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                attempt += 1
            }
            guard let pUrl = postURL else { return [] }

            let reqId = requestId
            requestId += 1
            
            let reqDict: [String: Any] = [
                "jsonrpc": "2.0",
                "id": reqId,
                "method": "tools/list"
            ]
            guard let reqBody = try? JSONSerialization.data(withJSONObject: reqDict) else { return [] }

            var req = URLRequest(url: pUrl)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let headers = headers {
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
            }
            req.httpBody = reqBody

            let respData = await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                pendingRequests[reqId] = cont
                Task {
                    do {
                        let _ = try await URLSession.shared.data(for: req)
                    } catch {
                        if let c = await removePendingRequest(id: reqId) {
                            c.resume(returning: Data())
                        }
                    }
                }
            }
            
            if let dict = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               let result = dict["result"] as? [String: Any], let tools = result["tools"] as? [[String: Any]] {
                var defs: [GFTokenizer.FunctionDefinition] = []
                for t in tools {
                    if let n = t["name"] as? String, let d = t["description"] as? String, let s = t["inputSchema"] {
                        if let sData = try? JSONSerialization.data(withJSONObject: s),
                           let sJSON = try? JSONDecoder().decode(JSONValue.self, from: sData) {
                            defs.append(GFTokenizer.FunctionDefinition(name: n, description: d, parameters: sJSON))
                        }
                    }
                }
                return defs
            }
            return []
        }

        func callTool(name: String, argsJson: String) async -> String {
            var attempt = 0
            while postURL == nil && attempt < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                attempt += 1
            }
            guard let pUrl = postURL else {
                return "Error: No POST URL received from SSE for \(self.name)"
            }

            let reqId = requestId
            requestId += 1
            
            let argsDict = (try? JSONSerialization.jsonObject(with: argsJson.data(using: .utf8) ?? Data())) as? [String: Any] ?? [:]
            let reqDict: [String: Any] = [
                "jsonrpc": "2.0",
                "id": reqId,
                "method": "tools/call",
                "params": [
                    "name": name,
                    "arguments": argsDict
                ]
            ]
            let reqBody = try? JSONSerialization.data(withJSONObject: reqDict)

            var req = URLRequest(url: pUrl)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let headers = headers {
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
            }
            req.httpBody = reqBody

            let respData = await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
                pendingRequests[reqId] = cont
                Task {
                    do {
                        let _ = try await URLSession.shared.data(for: req)
                    } catch {
                        if let c = await removePendingRequest(id: reqId) {
                            let errStr = "{\"error\":{\"message\":\"POST failed\"}}"
                            c.resume(returning: errStr.data(using: .utf8)!)
                        }
                    }
                }
            }
            
            var resultStr = "TOOL_NOT_FOUND"
            let dict = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
            if let error = dict["error"] as? [String: Any] {
                let msg = error["message"] as? String ?? "Unknown"
                let code = error["code"] as? Int
                if code != -32601 && !(msg.lowercased().contains("not found")) {
                    resultStr = "Error: \(msg)"
                }
            } else if let result = dict["result"] as? [String: Any],
                      let content = result["content"] as? [[String: Any]],
                      let text = content.first?["text"] as? String {
                resultStr = text
            } else {
                resultStr = "Failed to parse result from MCP: \(dict)"
            }
            
            return resultStr
        }
        
        private func removePendingRequest(id: Int) -> CheckedContinuation<Data, Never>? {
            return pendingRequests.removeValue(forKey: id)
        }
    }

    var servers: [MCPServerTransport] = []

    init?() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let configDir = homeDir.appendingPathComponent(".config/TurboFieldfareAgent")
        let configURL = configDir.appendingPathComponent("settings.json")

        if !FileManager.default.fileExists(atPath: configURL.path) {
            do {
                try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
                let defaultJson = """
                {
                  "mcpServers": {
                    "codex-nav": {
                      "command": "codex-nav-mcp-server",
                      "args": [],
                      "env": {}
                    }
                  }
                }
                """
                try defaultJson.write(to: configURL, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to create default MCP config: \(error)")
            }
        }

        guard let data = try? Data(contentsOf: configURL) else {
            print("MCP server config not found at \(configURL.path)")
            return nil
        }

        struct Config: Codable {
            struct ServerConfig: Codable {
                let command: String?
                let args: [String]?
                let env: [String: String]?
                let type: String?
                let url: String?
                let headers: [String: String]?
            }
            let mcpServers: [String: ServerConfig]?
        }

        guard let config = try? JSONDecoder().decode(Config.self, from: data), let mcpServers = config.mcpServers else {
            print("Invalid MCP config format in \(configURL.path)")
            return nil
        }

        for (name, serverConfig) in mcpServers {
            if let type = serverConfig.type, type == "sse", let urlString = serverConfig.url, let url = URL(string: urlString) {
                let server = SSEProcess(name: name, url: url, headers: serverConfig.headers)
                servers.append(server)
            } else if let command = serverConfig.command {
                do {
                    let server = try ServerProcess(name: name, command: command, args: serverConfig.args ?? [], env: serverConfig.env)
                    servers.append(server)
                } catch {
                    print("Failed to start MCP server \(name): \(error)")
                }
            }
        }

        if servers.isEmpty {
            print("No valid MCP servers configured or started.")
            return nil
        }
    }

    func listAllTools() async -> [GFTokenizer.FunctionDefinition] {
        var allTools: [GFTokenizer.FunctionDefinition] = []
        for server in servers {
            let tools = await server.listTools()
            allTools.append(contentsOf: tools)
        }
        return allTools
    }

    func callTool(name: String, argsJson: String) async -> String {
        for server in servers {
            let result = await server.callTool(name: name, argsJson: argsJson)
            if result != "TOOL_NOT_FOUND" {
                return result
            }
        }
        return "Error: Tool \(name) not found or failed on all MCP servers."
    }
}
