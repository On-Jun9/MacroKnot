import Foundation
import OSLog

@MainActor
enum RuntimeEventLogger {
    private static let logger = Logger(subsystem: "dev.macroknot.app.local", category: "runtime")

    static func record(
        _ event: String,
        result: String? = nil,
        fields: [String: String] = [:]
    ) {
        var payload = fields
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        payload["event"] = event
        if let result {
            payload["result"] = result
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard var line = String(data: data, encoding: .utf8) else { return }
            line.append("\n")
            try append(Data(line.utf8))
            logger.info("\(line, privacy: .public)")
        } catch {
            logger.error("runtime log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func append(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacroKnot", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("runtime.jsonl")

        if !fileManager.fileExists(atPath: file.path) {
            try data.write(to: file, options: .atomic)
            return
        }

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
