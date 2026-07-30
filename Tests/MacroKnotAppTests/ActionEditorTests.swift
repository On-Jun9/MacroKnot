import CoreGraphics
import Foundation
import MacroKnotCore
import Testing
@testable import MacroKnotApp

@Test
func createsEveryEditableActionKind() throws {
    for kind in MacroAction.Kind.allEditorCases {
        var draft = ActionEditorDraft(kind: kind)
        if kind == .capture {
            draft.captureTargetValue = "1"
            draft.destinationDirectory = "/tmp"
        }

        let action = try draft.makeAction()

        #expect(action.kind == kind)
        try action.validate()
    }
}

@Test
func editsRecordedActionWithoutChangingIdentity() throws {
    let recorded = MacroAction.click(
        point: ScreenPoint(x: 10, y: 20),
        strategy: .screenCoordinate
    )
    var draft = ActionEditorDraft(action: recorded)
    draft.kind = .doubleClick
    draft.startX = "30"
    draft.startY = "40"

    let edited = try draft.makeAction()

    #expect(edited.id == recorded.id)
    #expect(edited.kind == .doubleClick)
    #expect(edited.mouse?.start == ScreenPoint(x: 30, y: 40))
}

@Test
func preservesRecordedDragPathWhenEditingUnrelatedFields() throws {
    let start = ScreenPoint(x: 0, y: 0)
    let middle = ScreenPoint(x: 50, y: 20)
    let end = ScreenPoint(x: 100, y: 100)
    let path = [
        TimedScreenPoint(point: start, offsetMilliseconds: 0),
        TimedScreenPoint(point: middle, offsetMilliseconds: 100),
        TimedScreenPoint(point: end, offsetMilliseconds: 300),
    ]
    let recorded = MacroAction(
        kind: .drag,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(
            start: start,
            end: end,
            path: path,
            durationMilliseconds: 300,
            buttonNumber: 0
        )
    )
    var draft = ActionEditorDraft(action: recorded)
    draft.delay = "200"

    let edited = try draft.makeAction()

    #expect(edited.mouse?.path == path)
    #expect(edited.delayBeforeMilliseconds == 200)
}

@Test
func safelyEditsHugeFiniteValueAndPreservesKeyboardRepeat() throws {
    let hugeMove = MacroAction(
        kind: .mouseMove,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(start: ScreenPoint(x: 1e300, y: -1e300))
    )
    let moveDraft = ActionEditorDraft(action: hugeMove)
    #expect(moveDraft.startX == "1e+300")
    #expect(moveDraft.startY == "-1e+300")

    let repeatedKey = MacroAction.keyboard(
        keyCode: 0,
        characters: "a",
        modifierFlags: 0,
        eventKind: .keyDown,
        isRepeat: true
    )
    let editedKey = try ActionEditorDraft(action: repeatedKey).makeAction()

    #expect(editedKey.keyboard?.isRepeat == true)
}

@MainActor
@Test
func wrapsSelectedActionRangeInRepeatBlock() throws {
    let controller = DocumentController()
    controller.document.actions = [
        .wait(milliseconds: 100),
        .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
        .wait(milliseconds: 200),
    ]

    try controller.wrapActionsInRepeat(from: 0, through: 1, count: 3)

    #expect(controller.document.actions.count == 2)
    #expect(controller.document.actions.first?.kind == .repeatBlock)
    #expect(controller.document.actions.first?.repeatBlock?.count == 3)
    #expect(controller.document.actions.first?.repeatBlock?.actions.count == 2)
}

@MainActor
@Test
func removesAllActionsFromCurrentDocument() {
    let controller = DocumentController()
    controller.document.actions = [
        .wait(milliseconds: 100),
        .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
    ]

    controller.removeAllActions()

    #expect(controller.document.actions.isEmpty)
}

@MainActor
@Test
func removesMultipleSelectedActionsTogether() {
    let controller = DocumentController()
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.keyboard(keyCode: 0, characters: "a", modifierFlags: 0)
    let third = MacroAction.wait(milliseconds: 200)
    controller.document.actions = [first, second, third]

    controller.removeActions(ids: [first.id, third.id])

    #expect(controller.document.actions.map(\.id) == [second.id])
}

@Test
func detectsMacroEditorChangesAgainstItsOpeningSnapshot() {
    let initial = MacroDocument(name: "새 매크로")

    #expect(
        !MacroEditorChangeDetection.hasUnsavedChanges(
            initial: initial,
            current: initial
        )
    )

    var renamed = initial
    renamed.name = "변경한 매크로"
    #expect(
        MacroEditorChangeDetection.hasUnsavedChanges(
            initial: initial,
            current: renamed
        )
    )

    var actionAdded = initial
    actionAdded.actions.append(.wait(milliseconds: 100))
    #expect(
        MacroEditorChangeDetection.hasUnsavedChanges(
            initial: initial,
            current: actionAdded
        )
    )
}

@Test
func rejectsInvalidEditorValues() {
    var draft = ActionEditorDraft(kind: .drag)
    draft.startX = "not-a-number"

    #expect(throws: (any Error).self) {
        try draft.makeAction()
    }
}

@MainActor
@Test
func preventsDuplicatePlaybackAndReleasesInputsWhenStopped() async {
    let stopMonitor = FakeStopMonitor()
    let performer = SuspendingInputPerformer()
    let player = InputPlayer(
        globalStopMonitor: stopMonitor,
        performerFactory: { performer }
    )
    let document = MacroDocument(
        name: "재생 상태",
        actions: [
            .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
        ]
    )

    player.play(document: document)
    player.play(document: document)

    #expect(player.state == .running)
    #expect(stopMonitor.startCount == 1)
    await performer.waitUntilStarted()
    player.stop()
    for _ in 0..<100 where await performer.releaseCount == 0 {
        await Task.yield()
    }

    #expect(player.state == .stopped)
    #expect(await performer.releaseCount == 1)
    #expect(stopMonitor.stopCount == 1)
}

@MainActor
@Test
func repeatsPlaybackForRequestedFiniteCount() async {
    let stopMonitor = FakeStopMonitor()
    let performer = CountingInputPerformer()
    let player = InputPlayer(
        globalStopMonitor: stopMonitor,
        performerFactory: { performer }
    )
    let document = MacroDocument(
        name: "3회 재생",
        actions: [.keyboard(keyCode: 0, characters: "a", modifierFlags: 0)]
    )

    player.play(
        document: document,
        options: PlaybackOptions(rate: 2, repetition: .finite(3))
    )
    for _ in 0..<200 where player.state == .running {
        await Task.yield()
    }

    #expect(player.state == .completed)
    #expect(await performer.performCount == 3)
    #expect(await performer.releaseCount == 1)
    #expect(stopMonitor.startCount == 1)
    #expect(stopMonitor.stopCount == 1)
}

@MainActor
@Test
func stopsInfinitePlaybackAndReleasesInputs() async {
    let stopMonitor = FakeStopMonitor()
    let performer = CountingInputPerformer(suspendsAfterCount: 3)
    let player = InputPlayer(
        globalStopMonitor: stopMonitor,
        performerFactory: { performer }
    )
    let document = MacroDocument(
        name: "무한 재생",
        actions: [.keyboard(keyCode: 0, characters: "a", modifierFlags: 0)]
    )

    player.play(
        document: document,
        options: PlaybackOptions(rate: 1, repetition: .infinite)
    )
    await performer.waitUntilSuspended()
    player.stop()
    for _ in 0..<200 where await performer.releaseCount == 0 {
        await Task.yield()
    }

    #expect(player.state == .stopped)
    #expect(await performer.performCount == 3)
    #expect(await performer.releaseCount == 1)
    #expect(stopMonitor.stopCount == 1)
}

@MainActor
@Test
func completesRecordedEditedSavedLoadedAndPlayedWorkflow() async throws {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    var recorded: [MacroAction] = []
    reducer.consume(RawInputEvent(
        kind: .leftMouseDown,
        timestampNanoseconds: 1_000_000_000,
        location: ScreenPoint(x: 10, y: 20)
    ), appendingTo: &recorded)
    reducer.consume(RawInputEvent(
        kind: .leftMouseUp,
        timestampNanoseconds: 1_100_000_000,
        location: ScreenPoint(x: 10, y: 20)
    ), appendingTo: &recorded)
    reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 1_300_000_000,
        keyCode: 0,
        characters: "a"
    ), appendingTo: &recorded)
    reducer.consume(RawInputEvent(
        kind: .keyUp,
        timestampNanoseconds: 1_500_000_000,
        keyCode: 0,
        characters: "a"
    ), appendingTo: &recorded)

    var clickDraft = ActionEditorDraft(action: recorded[0])
    clickDraft.startX = "30"
    clickDraft.startY = "40"
    recorded[0] = try clickDraft.makeAction()

    let configuration = DisplayConfiguration(displays: [
        DisplayGeometry(
            id: 1,
            origin: ScreenPoint(x: 0, y: 0),
            width: 1_000,
            height: 1_000,
            scale: 1
        ),
    ])
    let document = MacroDocument(
        name: "통합 흐름",
        actions: recorded,
        displayConfiguration: configuration
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workflow.json")
    try MacroDocumentCodec.save(document, to: url)
    let loaded = try MacroDocumentCodec.load(from: url)
    try loaded.validateForPlayback(currentDisplayConfiguration: configuration)

    let performer = WorkflowRecordingPerformer()
    try await MacroExecutionEngine(performer: performer).run(loaded.actions)

    #expect(loaded.actions.first?.mouse?.start == ScreenPoint(x: 30, y: 40))
    #expect(await performer.kinds == [.click, .keyboard, .keyboard])
}

@Test
func postsScrollAtRecordedCoordinateAndPreservesKeyboardRepeat() async throws {
    let poster = RecordingSystemEventPoster()
    let performer = SystemActionPerformer(eventPoster: poster)
    let point = ScreenPoint(x: 77, y: 88)

    try await performer.perform(MacroAction(
        kind: .scroll,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(start: point, scrollDeltaX: 3.25, scrollDeltaY: -4.5)
    ))
    try await performer.perform(.keyboard(
        keyCode: 0,
        characters: "a",
        modifierFlags: 0,
        eventKind: .keyDown,
        isRepeat: true
    ))

    #expect(poster.mouseEvents.first?.type == CGEventType.mouseMoved.rawValue)
    #expect(poster.mouseEvents.first?.point == point)
    #expect(poster.scrollEvents.count == 1)
    #expect(poster.scrollEvents.first?.0 == 3.25)
    #expect(poster.scrollEvents.first?.1 == -4.5)
    #expect(poster.keyboardEvents.last?.keyboard.isRepeat == true)
}

@Test
func releasesModifierWithoutHeldFlagsAndCancelsDragAtCurrentPoint() async throws {
    let poster = RecordingSystemEventPoster()
    let performer = SystemActionPerformer(eventPoster: poster)
    try await performer.perform(.keyboard(
        keyCode: 55,
        characters: nil,
        modifierFlags: 0x0010_0000,
        eventKind: .keyDown
    ))
    await performer.releaseAllInputs()

    #expect(poster.keyboardEvents.last?.isDown == false)
    #expect(poster.keyboardEvents.last?.keyboard.modifierFlags == 0)

    let start = ScreenPoint(x: 10, y: 20)
    let end = ScreenPoint(x: 300, y: 400)
    let task = Task {
        try await performer.perform(MacroAction(
            kind: .drag,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(
                start: start,
                end: end,
                path: [
                    TimedScreenPoint(point: start, offsetMilliseconds: 0),
                    TimedScreenPoint(point: end, offsetMilliseconds: 1_000),
                ],
                durationMilliseconds: 1_000,
                buttonNumber: 0
            )
        ))
    }
    while poster.mouseEvents.isEmpty {
        await Task.yield()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    #expect(poster.mouseEvents.last?.type == CGEventType.leftMouseUp.rawValue)
    #expect(poster.mouseEvents.last?.point == start)
}

@MainActor
private final class FakeStopMonitor: GlobalStopMonitoring {
    var isAwaitingShortcutRelease = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onStop: @escaping () -> Void) throws {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private actor SuspendingInputPerformer: InputReleasingActionPerformer {
    private(set) var releaseCount = 0
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func perform(_ action: MacroAction) async throws {
        started = true
        continuation?.resume()
        continuation = nil
        try await Task.sleep(for: .seconds(60))
    }

    func releaseAllInputs() {
        releaseCount += 1
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor WorkflowRecordingPerformer: MacroActionPerforming {
    private(set) var kinds: [MacroAction.Kind] = []

    func perform(_ action: MacroAction) {
        kinds.append(action.kind)
    }
}

private actor CountingInputPerformer: InputReleasingActionPerformer {
    private(set) var performCount = 0
    private(set) var releaseCount = 0
    private let suspendsAfterCount: Int?
    private var continuation: CheckedContinuation<Void, Never>?

    init(suspendsAfterCount: Int? = nil) {
        self.suspendsAfterCount = suspendsAfterCount
    }

    func perform(_ action: MacroAction) async throws {
        performCount += 1
        guard performCount == suspendsAfterCount else { return }
        continuation?.resume()
        continuation = nil
        try await Task.sleep(for: .seconds(60))
    }

    func releaseAllInputs() {
        releaseCount += 1
    }

    func waitUntilSuspended() async {
        if performCount == suspendsAfterCount { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private final class RecordingSystemEventPoster: SystemEventPosting, @unchecked Sendable {
    struct MouseEvent: Equatable {
        let type: UInt32
        let point: ScreenPoint
        let button: UInt32
    }

    struct KeyboardEvent {
        let keyboard: KeyboardPayload
        let isDown: Bool
    }

    private let lock = NSLock()
    private var storedMouseEvents: [MouseEvent] = []
    private var storedScrollEvents: [(Double, Double)] = []
    private var storedKeyboardEvents: [KeyboardEvent] = []
    private var storedCurrentLocation = ScreenPoint(x: 0, y: 0)

    var mouseEvents: [MouseEvent] {
        locked { storedMouseEvents }
    }

    var scrollEvents: [(Double, Double)] {
        locked { storedScrollEvents }
    }

    var keyboardEvents: [KeyboardEvent] {
        locked { storedKeyboardEvents }
    }

    var currentMouseLocation: ScreenPoint {
        locked { storedCurrentLocation }
    }

    func postMouse(
        type: CGEventType,
        point: ScreenPoint,
        button: CGMouseButton,
        clickState: Int64?
    ) {
        locked {
            storedCurrentLocation = point
            storedMouseEvents.append(MouseEvent(
                type: type.rawValue,
                point: point,
                button: button.rawValue
            ))
        }
    }

    func postScroll(deltaX: Double, deltaY: Double) {
        locked { storedScrollEvents.append((deltaX, deltaY)) }
    }

    func postKeyboard(_ keyboard: KeyboardPayload, isDown: Bool) {
        locked { storedKeyboardEvents.append(KeyboardEvent(keyboard: keyboard, isDown: isDown)) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@Test
func appliesCoordinatesPickedFromTheScreen() throws {
    var draft = ActionEditorDraft(kind: .click)
    draft.setStartPoint(ScreenPoint(x: 128.125, y: -242.5))

    let action = try draft.makeAction()

    #expect(draft.startX == "128.13")
    #expect(draft.startY == "-242.5")
    #expect(action.mouse?.start == ScreenPoint(x: 128.13, y: -242.5))
}

@Test
func convertsCoreGraphicsPointerLocationWithoutChangingCoordinateSystem() {
    let point = ScreenCoordinatePicker.screenPoint(from: CGPoint(x: -640, y: 360.5))

    #expect(point == ScreenPoint(x: -640, y: 360.5))
}
