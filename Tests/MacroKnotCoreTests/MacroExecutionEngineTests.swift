import Foundation
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

@Test
func reportsFailingTopLevelAndNestedActionNumbers() async {
    let performer = FailingPerformer(failingKind: .keyboard)
    let engine = MacroExecutionEngine(performer: performer)

    await #expect(throws: MacroExecutionError.actionFailed(
        path: [2, 1],
        message: "의도한 실패"
    )) {
        try await engine.run([
            .wait(milliseconds: 1),
            .repeatBlock(count: 1, actions: [
                .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
            ]),
        ])
    }
}

@Test
func executesLargeActionSetWithoutLosingActions() async throws {
    let performer = CountingPerformer()
    let engine = MacroExecutionEngine(performer: performer)
    let actions = (0..<50_000).map { index in
        MacroAction.keyboard(
            keyCode: UInt16(index % 100),
            characters: nil,
            modifierFlags: 0
        )
    }

    try await engine.run(actions)

    #expect(await performer.count == 50_000)
}

@Test
func waitsForRecordedDelayBeforePerformingActions() async throws {
    let performer = CountingPerformer()
    let engine = MacroExecutionEngine(performer: performer)
    var first = MacroAction.keyboard(keyCode: 0, characters: "a", modifierFlags: 0)
    first.delayBeforeMilliseconds = 80
    var second = MacroAction.keyboard(keyCode: 11, characters: "b", modifierFlags: 0)
    second.delayBeforeMilliseconds = 120
    let clock = ContinuousClock()
    let startedAt = clock.now

    try await engine.run([first, second])

    let elapsed = startedAt.duration(to: clock.now)
    #expect(elapsed >= .milliseconds(190))
    #expect(await performer.count == 2)
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

private struct FailingPerformer: MacroActionPerforming {
    let failingKind: MacroAction.Kind

    func perform(_ action: MacroAction) throws {
        if action.kind == failingKind {
            throw TestFailure()
        }
    }
}

private struct TestFailure: LocalizedError {
    var errorDescription: String? { "의도한 실패" }
}

private actor CountingPerformer: MacroActionPerforming {
    private(set) var count = 0

    func perform(_ action: MacroAction) {
        count += 1
    }
}
