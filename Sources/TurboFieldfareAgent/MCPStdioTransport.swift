import Foundation
import TurboFieldfare

final class MCPStdioTransport: MCPServerTransport, @unchecked Sendable {
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
                    if MCPRPC.matches(line, id: reqId) {
                        if let data = line.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let result = dict["result"] as? [String: Any],
                           let tools = result["tools"] as? [[String: Any]] {
                            let defs = tools.compactMap { tool -> GFTokenizer.FunctionDefinition? in
                                guard tool["description"] is String else { return nil }
                                return try? MCPToolDefinition.decode(tool)
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

                guard let request = try? MCPRPC.call(id: reqId, name: name, argumentsJSON: argsJson) else {
                    cont.resume(returning: "Error: invalid MCP arguments")
                    return
                }
                self.inPipe.fileHandleForWriting.write(request)

                while true {
                    let line = self.readLineSync()
                    if line.isEmpty { break }
                    if MCPRPC.matches(line, id: reqId) {
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
