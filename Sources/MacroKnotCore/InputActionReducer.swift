import Foundation

public enum InputRecordingMode: String, Codable, Equatable, Sendable {
    case allMouseMovement
    case meaningfulActionsOnly
}

public enum RawInputEventKind: String, Codable, Equatable, Sendable {
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case mouseMoved
    case leftMouseDragged
    case rightMouseDragged
    case scrollWheel
    case keyDown
    case keyUp
    case flagsChanged
}

public struct RawInputEvent: Codable, Equatable, Sendable {
    public var kind: RawInputEventKind
    public var timestampNanoseconds: UInt64
    public var location: ScreenPoint
    public var buttonNumber: Int64
    public var clickCount: Int64
    public var scrollDeltaX: Double
    public var scrollDeltaY: Double
    public var keyCode: UInt16?
    public var characters: String?
    public var modifierFlags: UInt64

    public init(
        kind: RawInputEventKind,
        timestampNanoseconds: UInt64 = 0,
        location: ScreenPoint = ScreenPoint(x: 0, y: 0),
        buttonNumber: Int64 = 0,
        clickCount: Int64 = 1,
        scrollDeltaX: Double = 0,
        scrollDeltaY: Double = 0,
        keyCode: UInt16? = nil,
        characters: String? = nil,
        modifierFlags: UInt64 = 0
    ) {
        self.kind = kind
        self.timestampNanoseconds = timestampNanoseconds
        self.location = location
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.keyCode = keyCode
        self.characters = characters
        self.modifierFlags = modifierFlags
    }
}

public struct InputActionReducer: Sendable {
    public var mode: InputRecordingMode

    private var mouseDown: RawInputEvent?
    private var mouseDragged = false
    private var lastActionTimestampNanoseconds: UInt64?

    public init(mode: InputRecordingMode) {
        self.mode = mode
    }

    public mutating func consume(_ event: RawInputEvent) -> [MacroAction] {
        let actions = reduce(event)
        guard !actions.isEmpty else { return [] }

        var timedActions = actions
        if let previousTimestamp = lastActionTimestampNanoseconds,
           event.timestampNanoseconds > previousTimestamp {
            let elapsedMilliseconds = (event.timestampNanoseconds - previousTimestamp) / 1_000_000
            if elapsedMilliseconds > 0 {
                timedActions[0].delayBeforeMilliseconds = elapsedMilliseconds
            }
        }
        lastActionTimestampNanoseconds = event.timestampNanoseconds
        return timedActions
    }

    private mutating func reduce(_ event: RawInputEvent) -> [MacroAction] {
        switch event.kind {
        case .leftMouseDown, .rightMouseDown:
            mouseDown = event
            mouseDragged = false
            return []
        case .leftMouseDragged, .rightMouseDragged:
            mouseDragged = true
            return movementAction(for: event)
        case .leftMouseUp, .rightMouseUp:
            return finishMouseInteraction(with: event)
        case .mouseMoved:
            return movementAction(for: event)
        case .scrollWheel:
            return [MacroAction(
                kind: .scroll,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(
                    start: event.location,
                    scrollDeltaX: event.scrollDeltaX,
                    scrollDeltaY: event.scrollDeltaY
                )
            )]
        case .keyDown:
            guard let keyCode = event.keyCode else { return [] }
            return [.keyboard(
                keyCode: keyCode,
                characters: event.characters,
                modifierFlags: event.modifierFlags
            )]
        case .keyUp, .flagsChanged:
            return []
        }
    }

    private mutating func finishMouseInteraction(with event: RawInputEvent) -> [MacroAction] {
        defer {
            mouseDown = nil
            mouseDragged = false
        }
        guard let mouseDown else { return [] }

        if mouseDragged {
            return [MacroAction(
                kind: .drag,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(start: mouseDown.location, end: event.location)
            )]
        }

        let kind: MacroAction.Kind
        if event.kind == .rightMouseUp || event.buttonNumber == 1 {
            kind = .rightClick
        } else if event.clickCount >= 2 {
            kind = .doubleClick
        } else {
            kind = .click
        }
        return [.click(
            kind: kind,
            point: event.location,
            strategy: .screenCoordinate
        )]
    }

    private func movementAction(for event: RawInputEvent) -> [MacroAction] {
        guard mode == .allMouseMovement else { return [] }
        return [MacroAction(
            kind: .mouseMove,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: event.location)
        )]
    }
}
