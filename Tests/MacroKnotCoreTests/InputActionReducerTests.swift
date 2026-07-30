import Testing
@testable import MacroKnotCore

@Test
func excludesEventsCreatedByOrDeliveredToMacroKnot() {
    let macroKnotProcessID: Int64 = 100

    #expect(!InputEventProcessFilter.shouldRecord(
        sourceProcessID: macroKnotProcessID,
        destinationProcessID: 200,
        recorderProcessID: macroKnotProcessID,
        excludesEventsTargetingRecorder: true
    ))
    #expect(!InputEventProcessFilter.shouldRecord(
        sourceProcessID: 0,
        destinationProcessID: macroKnotProcessID,
        recorderProcessID: macroKnotProcessID,
        excludesEventsTargetingRecorder: true
    ))
    #expect(InputEventProcessFilter.shouldRecord(
        sourceProcessID: 0,
        destinationProcessID: 200,
        recorderProcessID: macroKnotProcessID,
        excludesEventsTargetingRecorder: true
    ))
    #expect(InputEventProcessFilter.shouldRecord(
        sourceProcessID: 0,
        destinationProcessID: nil,
        recorderProcessID: macroKnotProcessID,
        excludesEventsTargetingRecorder: true
    ))
    #expect(InputEventProcessFilter.shouldRecord(
        sourceProcessID: 0,
        destinationProcessID: macroKnotProcessID,
        recorderProcessID: macroKnotProcessID,
        excludesEventsTargetingRecorder: false
    ))
    #expect(!InputEventProcessFilter.shouldRecord(
        sourceProcessID: macroKnotProcessID,
        destinationProcessID: 200,
        recorderProcessID: macroKnotProcessID,
        excludesEventsTargetingRecorder: false
    ))
}

@Test
func reducesClicksAndDoubleClicks() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    let point = ScreenPoint(x: 10, y: 20)

    #expect(reducer.consume(RawInputEvent(kind: .leftMouseDown, location: point)).isEmpty)
    let click = reducer.consume(RawInputEvent(
        kind: .leftMouseUp,
        location: point,
        clickCount: 1
    ))
    #expect(click.map(\.kind) == [.click])

    #expect(reducer.consume(RawInputEvent(kind: .leftMouseDown, location: point)).isEmpty)
    let doubleClick = reducer.consume(RawInputEvent(
        kind: .leftMouseUp,
        location: point,
        clickCount: 2
    ))
    #expect(doubleClick.map(\.kind) == [.doubleClick])
}

@Test
func replacesFirstClickWhenRecordingDoubleClickSequence() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    var actions: [MacroAction] = []
    let point = ScreenPoint(x: 10, y: 20)

    reducer.consume(
        RawInputEvent(
            kind: .keyDown,
            timestampNanoseconds: 500_000_000,
            keyCode: 0,
            characters: "a"
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .leftMouseDown,
            timestampNanoseconds: 1_000_000_000,
            location: point,
            clickCount: 1
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .leftMouseUp,
            timestampNanoseconds: 1_010_000_000,
            location: point,
            clickCount: 1
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .leftMouseDown,
            timestampNanoseconds: 1_100_000_000,
            location: point,
            clickCount: 2
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .leftMouseUp,
            timestampNanoseconds: 1_110_000_000,
            location: point,
            clickCount: 2
        ),
        appendingTo: &actions
    )

    #expect(actions.map(\.kind) == [.keyboard, .doubleClick])
    #expect(actions.last?.delayBeforeMilliseconds == 510)
}

@Test
func reducesDragFromDownToUp() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    let start = ScreenPoint(x: 10, y: 20)
    let end = ScreenPoint(x: 100, y: 200)

    #expect(reducer.consume(RawInputEvent(kind: .leftMouseDown, location: start)).isEmpty)
    #expect(reducer.consume(RawInputEvent(kind: .leftMouseDragged, location: end)).isEmpty)
    let actions = reducer.consume(RawInputEvent(kind: .leftMouseUp, location: end))

    #expect(actions.count == 1)
    #expect(actions.first?.kind == .drag)
    #expect(actions.first?.mouse?.start == start)
    #expect(actions.first?.mouse?.end == end)
}

@Test
func preservesDragPathAndDuration() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    let start = ScreenPoint(x: 10, y: 20)
    let middle = ScreenPoint(x: 40, y: 80)
    let end = ScreenPoint(x: 100, y: 200)

    #expect(reducer.consume(RawInputEvent(
        kind: .leftMouseDown,
        timestampNanoseconds: 1_000_000_000,
        location: start
    )).isEmpty)
    #expect(reducer.consume(RawInputEvent(
        kind: .leftMouseDragged,
        timestampNanoseconds: 1_120_000_000,
        location: middle
    )).isEmpty)
    let actions = reducer.consume(RawInputEvent(
        kind: .leftMouseUp,
        timestampNanoseconds: 1_350_000_000,
        location: end
    ))

    #expect(actions.first?.mouse?.path == [
        TimedScreenPoint(point: start, offsetMilliseconds: 0),
        TimedScreenPoint(point: middle, offsetMilliseconds: 120),
        TimedScreenPoint(point: end, offsetMilliseconds: 350),
    ])
    #expect(actions.first?.mouse?.durationMilliseconds == 350)
}

@Test
func separatesDelayBeforeDragFromDragDuration() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    var actions: [MacroAction] = []

    reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 500_000_000,
        keyCode: 0
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .leftMouseDown,
        timestampNanoseconds: 1_000_000_000,
        location: ScreenPoint(x: 0, y: 0)
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .leftMouseDragged,
        timestampNanoseconds: 1_200_000_000,
        location: ScreenPoint(x: 50, y: 50)
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .leftMouseUp,
        timestampNanoseconds: 1_350_000_000,
        location: ScreenPoint(x: 100, y: 100)
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .keyUp,
        timestampNanoseconds: 1_500_000_000,
        keyCode: 0
    ), appendingTo: &actions)

    #expect(actions.map(\.delayBeforeMilliseconds) == [nil, 500, 150])
    #expect(actions[1].mouse?.durationMilliseconds == 350)
}

@Test
func preservesRightMouseButtonForDrag() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)

    #expect(reducer.consume(RawInputEvent(
        kind: .rightMouseDown,
        timestampNanoseconds: 1_000_000_000,
        location: ScreenPoint(x: 1, y: 2),
        buttonNumber: 1
    )).isEmpty)
    #expect(reducer.consume(RawInputEvent(
        kind: .rightMouseDragged,
        timestampNanoseconds: 1_100_000_000,
        location: ScreenPoint(x: 3, y: 4),
        buttonNumber: 1
    )).isEmpty)
    let actions = reducer.consume(RawInputEvent(
        kind: .rightMouseUp,
        timestampNanoseconds: 1_200_000_000,
        location: ScreenPoint(x: 5, y: 6),
        buttonNumber: 1
    ))

    #expect(actions.first?.kind == .drag)
    #expect(actions.first?.mouse?.buttonNumber == 1)
}

@Test
func filtersOrIncludesMouseMovementByMode() {
    let event = RawInputEvent(
        kind: .mouseMoved,
        location: ScreenPoint(x: 50, y: 60)
    )
    var meaningful = InputActionReducer(mode: .meaningfulActionsOnly)
    var allMovement = InputActionReducer(mode: .allMouseMovement)

    #expect(meaningful.consume(event).isEmpty)
    #expect(allMovement.consume(event).map(\.kind) == [.mouseMove])
}

@Test
func reducesScrollAndKeyboard() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    let scroll = reducer.consume(RawInputEvent(
        kind: .scrollWheel,
        location: ScreenPoint(x: 1, y: 2),
        scrollDeltaX: 3,
        scrollDeltaY: -4
    ))
    let keyboard = reducer.consume(RawInputEvent(
        kind: .keyDown,
        keyCode: 0,
        characters: "a",
        modifierFlags: 1
    ))

    #expect(scroll.map(\.kind) == [.scroll])
    #expect(scroll.first?.mouse?.scrollDeltaX == 3)
    #expect(scroll.first?.mouse?.scrollDeltaY == -4)
    #expect(keyboard.map(\.kind) == [.keyboard])
    #expect(keyboard.first?.keyboard?.characters == "a")
    #expect(keyboard.first?.keyboard?.resolvedEventKind == .keyDown)
}

@Test
func preservesKeyDownUpHoldAndModifierTransitions() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    var actions: [MacroAction] = []

    reducer.consume(RawInputEvent(
        kind: .flagsChanged,
        timestampNanoseconds: 1_000_000_000,
        keyCode: 55,
        modifierFlags: 0x0010_0000
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 1_100_000_000,
        keyCode: 0,
        characters: "a",
        modifierFlags: 0x0010_0000
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 1_400_000_000,
        keyCode: 0,
        characters: "a",
        modifierFlags: 0x0010_0000,
        isKeyboardRepeat: true
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .keyUp,
        timestampNanoseconds: 1_800_000_000,
        keyCode: 0,
        characters: "a",
        modifierFlags: 0x0010_0000
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .flagsChanged,
        timestampNanoseconds: 1_900_000_000,
        keyCode: 55,
        modifierFlags: 0
    ), appendingTo: &actions)

    #expect(actions.map { $0.keyboard?.resolvedEventKind } == [
        .keyDown, .keyDown, .keyDown, .keyUp, .keyUp,
    ])
    #expect(actions.map { $0.keyboard?.isRepeat == true } == [false, false, true, false, false])
    #expect(actions.map(\.delayBeforeMilliseconds) == [nil, 100, 300, 400, 100])
}

@Test
func distinguishesLeftAndRightModifierReleaseWhileAggregateFlagRemainsSet() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    var actions: [MacroAction] = []

    for event in [
        RawInputEvent(kind: .flagsChanged, keyCode: 56, modifierFlags: 0x0002_0000),
        RawInputEvent(kind: .flagsChanged, keyCode: 60, modifierFlags: 0x0002_0000),
        RawInputEvent(kind: .flagsChanged, keyCode: 56, modifierFlags: 0x0002_0000),
        RawInputEvent(kind: .flagsChanged, keyCode: 60, modifierFlags: 0),
    ] {
        reducer.consume(event, appendingTo: &actions)
    }

    #expect(actions.map { $0.keyboard?.resolvedEventKind } == [
        .keyDown, .keyDown, .keyUp, .keyUp,
    ])
    #expect(actions.compactMap { $0.keyboard?.keyCode } == [56, 60, 56, 60])
}

@Test
func preservesContinuousScrollAndAllMouseMovement() {
    var reducer = InputActionReducer(mode: .allMouseMovement)
    var actions: [MacroAction] = []

    reducer.consume(RawInputEvent(
        kind: .mouseMoved,
        timestampNanoseconds: 1_000_000_000,
        location: ScreenPoint(x: 1, y: 2)
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .mouseMoved,
        timestampNanoseconds: 1_010_000_000,
        location: ScreenPoint(x: 3, y: 4)
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .scrollWheel,
        timestampNanoseconds: 1_020_000_000,
        location: ScreenPoint(x: 3, y: 4),
        scrollDeltaY: -1.25
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .scrollWheel,
        timestampNanoseconds: 1_030_000_000,
        location: ScreenPoint(x: 3, y: 4),
        scrollDeltaY: -2.5
    ), appendingTo: &actions)

    #expect(actions.map(\.kind) == [.mouseMove, .mouseMove, .scroll, .scroll])
    #expect(actions.map(\.delayBeforeMilliseconds) == [nil, 10, 10, 10])
    #expect(actions.suffix(2).compactMap { $0.mouse?.scrollDeltaY } == [-1.25, -2.5])
}

@Test
func reducesLargeMouseMovementStreamWithoutLosingActions() {
    var reducer = InputActionReducer(mode: .allMouseMovement)
    var actions: [MacroAction] = []
    actions.reserveCapacity(20_000)

    for index in 0..<20_000 {
        reducer.consume(RawInputEvent(
            kind: .mouseMoved,
            timestampNanoseconds: UInt64(index) * 1_000_000,
            location: ScreenPoint(x: Double(index % 1_000), y: Double(index / 1_000))
        ), appendingTo: &actions)
    }

    #expect(actions.count == 20_000)
    #expect(actions.first?.mouse?.start == ScreenPoint(x: 0, y: 0))
    #expect(actions.last?.mouse?.start == ScreenPoint(x: 999, y: 19))
}

@Test
func preservesElapsedTimeBetweenRecordedActions() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)

    let first = reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 1_000_000_000,
        keyCode: 0,
        characters: "a"
    ))
    let second = reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 1_650_000_000,
        keyCode: 11,
        characters: "b"
    ))

    #expect(first.map(\.kind) == [.keyboard])
    #expect(second.map(\.kind) == [.keyboard])
    #expect(second.first?.delayBeforeMilliseconds == 650)
}

@Test
func preservesDelayFromRecordingStartToFirstAction() {
    var reducer = InputActionReducer(
        mode: .meaningfulActionsOnly,
        recordingStartTimestampNanoseconds: 1_000_000_000
    )

    let first = reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 2_250_000_000,
        keyCode: 0,
        characters: "a"
    ))

    #expect(first.first?.delayBeforeMilliseconds == 1_250)
}

@Test
func preservesOrderAndElapsedTimeAcrossMouseScrollAndKeyboard() {
    var reducer = InputActionReducer(mode: .meaningfulActionsOnly)
    var actions: [MacroAction] = []
    let point = ScreenPoint(x: 10, y: 20)

    reducer.consume(
        RawInputEvent(
            kind: .leftMouseDown,
            timestampNanoseconds: 100_000_000,
            location: point
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .leftMouseUp,
            timestampNanoseconds: 200_000_000,
            location: point
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .scrollWheel,
            timestampNanoseconds: 500_000_000,
            location: point,
            scrollDeltaY: -4
        ),
        appendingTo: &actions
    )
    reducer.consume(
        RawInputEvent(
            kind: .keyDown,
            timestampNanoseconds: 900_000_000,
            keyCode: 0,
            characters: "a"
        ),
        appendingTo: &actions
    )

    #expect(actions.map(\.kind) == [.click, .scroll, .keyboard])
    #expect(actions.map(\.delayBeforeMilliseconds) == [nil, 300, 400])
}
