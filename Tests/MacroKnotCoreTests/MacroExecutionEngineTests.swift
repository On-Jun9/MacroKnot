import Testing
@testable import MacroKnotCore

@Test
func executesActionsInOrderAndExpandsRepeatBlocks() async throws {
    let performer = RecordingPerformer()
    let engine = MacroExecutionEngine(performer: performer)
    let actions: [MacroAction] = [
        .wait(milliseconds: 10),
        .repeatBlock(count: 2, actions: [
            .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
            .wait(milliseconds: 20),
        ]),
    ]

    try await engine.run(actions)

    #expect(await performer.kinds == [.wait, .keyboard, .wait, .keyboard, .wait])
}

@Test
func stopsBeforeNextActionWhenCancelled() async throws {
    let performer = SuspendingPerformer()
    let engine = MacroExecutionEngine(performer: performer)
    let task = Task {
        try await engine.run([
            .wait(milliseconds: 10),
            .wait(milliseconds: 20),
        ])
    }
    await performer.waitUntilStarted()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(await performer.performCount == 1)
}

private actor RecordingPerformer: MacroActionPerforming {
    private(set) var kinds: [MacroAction.Kind] = []

    func perform(_ action: MacroAction) {
        kinds.append(action.kind)
    }
}

private actor SuspendingPerformer: MacroActionPerforming {
    private(set) var performCount = 0
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func perform(_ action: MacroAction) async throws {
        performCount += 1
        startedContinuation?.resume()
        startedContinuation = nil
        try await Task.sleep(for: .seconds(60))
    }

    func waitUntilStarted() async {
        if performCount > 0 { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }
}
