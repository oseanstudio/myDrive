import Darwin
import Foundation

@MainActor enum BlipCommand {
    static func run(_ arguments: [String]) -> Never {
        do {
            let command = arguments[0]
            if command == "serve", arguments.count == 1 {
                guard let app = BlipMacEngine.installedApplication else { throw BlipMacEngine.missing }
                try BlipMacEngine.runInstalled(appPath: app.path)
                exit(0)
            }
            guard let socket = BlipLocalRPC.socketURL() else {
                throw BlipReceiverError.message("Start mydrive-cli blip serve in another terminal after signing in to Blip once.")
            }
            let result: JSON
            switch command {
            case "poll" where arguments.count == 1:
                result = try BlipLocalRPC.request("poll", arguments: [], socket: socket)
            case "accept" where arguments.count == 4 && arguments[1] == "--id" && arguments[3] == "--execute":
                result = try BlipLocalRPC.request("accept", arguments: Array(arguments[1...2]), socket: socket)
            case "send" where arguments.count >= 6 && arguments[1] == "--peer" && Array(arguments[3...4]) == ["--execute", "--"]:
                let status = try BlipLocalRPC.request("poll", arguments: [], socket: socket).dict("status")
                guard status.bool("authenticated") else { throw BlipRPCError.unavailable }
                let id = UUID().uuidString.lowercased()
                try BlipLocalRPC.send(paths: Array(arguments.dropFirst(5)), peer: arguments[2],
                                      sender: status.str("user_id") + ":" + status.str("device_id"), socket: socket, requestID: id)
                result = ["ok": true, "transfer_id": id, "phase": "dispatched"]
            default: throw BlipRPCError.invalid
            }
            try FileHandle.standardOutput.write(contentsOf: JSONSerialization.data(withJSONObject: result) + Data([10]))
            exit(0)
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
