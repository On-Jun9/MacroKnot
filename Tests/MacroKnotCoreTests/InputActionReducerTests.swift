import Testing
@testable import MacroKnotCore

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
