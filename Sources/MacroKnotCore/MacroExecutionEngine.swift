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
        for action in actions {
            try Task.checkCancellation()
            if let delay = action.delayBeforeMilliseconds, delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
            }
            if action.kind == .repeatBlock, let repeatBlock = action.repeatBlock {
                for _ in 0..<repeatBlock.count {
                    try Task.checkCancellation()
                    try await run(repeatBlock.actions)
                }
            } else {
                try await performer.perform(action)
            }
        }
    }
}
