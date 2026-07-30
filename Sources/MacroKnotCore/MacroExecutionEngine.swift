import Foundation

public protocol MacroActionPerforming: Sendable {
    func perform(_ action: MacroAction) async throws
}

public struct MacroExecutionEngine: Sendable {
    private let performer: any MacroActionPerforming

    public init(performer: any MacroActionPerforming) {
        self.performer = performer
    }

    public func run(_ actions: [MacroAction]) async throws {
        try await run(actions, path: [])
    }

    private func run(_ actions: [MacroAction], path: [Int]) async throws {
        for (index, action) in actions.enumerated() {
            do {
                try Task.checkCancellation()
                if let delay = action.delayBeforeMilliseconds, delay > 0 {
                    try await Task.sleep(for: .milliseconds(delay))
                }
                if action.kind == .repeatBlock, let repeatBlock = action.repeatBlock {
                    for _ in 0..<repeatBlock.count {
                        try Task.checkCancellation()
                        try await run(repeatBlock.actions, path: path + [index + 1])
                    }
                } else {
                    try await performer.perform(action)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as MacroExecutionError {
                throw error
            } catch {
                throw MacroExecutionError.actionFailed(
                    path: path + [index + 1],
                    message: error.localizedDescription
                )
            }
        }
    }
}

public enum MacroExecutionError: Error, Equatable, LocalizedError {
    case actionFailed(path: [Int], message: String)

    public var errorDescription: String? {
        switch self {
        case let .actionFailed(path, message):
            return "액션 \(path.map(String.init).joined(separator: ".")) 실행 실패: \(message)"
        }
    }
}
