import Foundation

class MCPClient: @unchecked Sendable {
    static let shared = MCPClient()

    class ServerProcess {
        let process: Process
        let inPipe = Pipe()
        let outPipe = Pipe()
        var requestId = 1
        let name: String

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

            // Init MCP
            let initReq = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"turbo-agent\",\"version\":\"1.0.0\"}}}\n"
            inPipe.fileHandleForWriting.write(initReq.data(using: .utf8)!)
            _ = readLine() // consume response

            let initNotif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
            inPipe.fileHandleForWriting.write(initNotif.data(using: .utf8)!)
        }

        func readLine() -> String {
            var data = Data()
            let handle = outPipe.fileHandleForReading
            while true {
                let byte = handle.readData(ofLength: 1)
                if byte.isEmpty { break }
                if byte == Data([10]) { break } // \n
                data.append(byte)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    var servers: [ServerProcess] = []

    private init?() {
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
                let command: String
                let args: [String]?
                let env: [String: String]?
            }
            let mcpServers: [String: ServerConfig]?
        }

        guard let config = try? JSONDecoder().decode(Config.self, from: data), let mcpServers = config.mcpServers else {
            print("Invalid MCP config format in \(configURL.path)")
            return nil
        }

        for (name, serverConfig) in mcpServers {
            do {
                let server = try ServerProcess(name: name, command: serverConfig.command, args: serverConfig.args ?? [], env: serverConfig.env)
                servers.append(server)
            } catch {
                print("Failed to start MCP server \(name): \(error)")
            }
        }

        if servers.isEmpty {
            print("No valid MCP servers configured or started.")
            return nil
        }
    }

    func callTool(name: String, args: [String: Any]) -> String {
        for server in servers {
            let reqId = server.requestId
            server.requestId += 1

            let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data()
            let argsJson = String(data: argsData, encoding: .utf8) ?? "{}"

            let req = "{\"jsonrpc\":\"2.0\",\"id\":\(reqId),\"method\":\"tools/call\",\"params\":{\"name\":\"\(name)\",\"arguments\":\(argsJson)}}\n"
            server.inPipe.fileHandleForWriting.write(req.data(using: .utf8)!)

            while true {
                let line = server.readLine()
                if line.isEmpty { break }
                if line.contains("\"id\":\(reqId)") {
                    if let data = line.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let error = dict["error"] as? [String: Any] {
                            let msg = error["message"] as? String ?? "Unknown"
                            let code = error["code"] as? Int
                            if code == -32601 || msg.lowercased().contains("not found") {
                                break // Try next server
                            }
                            return "Error: \(msg)"
                        }
                        if let result = dict["result"] as? [String: Any],
                           let content = result["content"] as? [[String: Any]],
                           let text = content.first?["text"] as? String {
                            return text
                        }
                    }
                    return "Failed to parse result from MCP: \(line)"
                }
            }
        }
        return "Error: Tool \(name) not found or failed on all MCP servers."
    }
}
