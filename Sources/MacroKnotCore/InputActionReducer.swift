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
    public var isKeyboardRepeat: Bool

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
        modifierFlags: UInt64 = 0,
        isKeyboardRepeat: Bool = false
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
        self.isKeyboardRepeat = isKeyboardRepeat
    }
}

public struct InputActionReducer: Sendable {
    public var mode: InputRecordingMode

    private var mouseDown: RawInputEvent?
    private var mouseDragged = false
    private var dragEvents: [RawInputEvent] = []
    private var lastActionTimestampNanoseconds: UInt64?
    private var previousClickActionID: UUID?
    private var actionStartTimestampNanoseconds: UInt64?
    private var pressedModifierKeyCodes: Set<UInt16> = []

    public init(
        mode: InputRecordingMode,
        recordingStartTimestampNanoseconds: UInt64? = nil
    ) {
        self.mode = mode
        lastActionTimestampNanoseconds = recordingStartTimestampNanoseconds
    }

    public mutating func consume(_ event: RawInputEvent) -> [MacroAction] {
        actionStartTimestampNanoseconds = nil
        let actions = reduce(event)
        guard !actions.isEmpty else { return [] }

        var timedActions = actions
        let startTimestamp = actionStartTimestampNanoseconds ?? event.timestampNanoseconds
        if let previousTimestamp = lastActionTimestampNanoseconds,
           startTimestamp > previousTimestamp {
            let elapsedMilliseconds = (startTimestamp - previousTimestamp) / 1_000_000
            if elapsedMilliseconds > 0 {
                timedActions[0].delayBeforeMilliseconds = elapsedMilliseconds
            }
        }
        lastActionTimestampNanoseconds = event.timestampNanoseconds
        return timedActions
    }

    @discardableResult
    public mutating func consume(
        _ event: RawInputEvent,
        appendingTo recordedActions: inout [MacroAction]
    ) -> [MacroAction] {
        let reducedActions = consume(event)
        for var action in reducedActions {
            if action.kind == .doubleClick,
               let index = recordedActions.firstIndex(where: { $0.id == action.id }) {
                action.delayBeforeMilliseconds = recordedActions[index].delayBeforeMilliseconds
                recordedActions[index] = action
            } else {
                recordedActions.append(action)
            }
        }
        return reducedActions
    }

    private mutating func reduce(_ event: RawInputEvent) -> [MacroAction] {
        switch event.kind {
        case .leftMouseDown, .rightMouseDown:
            mouseDown = event
            mouseDragged = false
            dragEvents = [event]
            return []
        case .leftMouseDragged, .rightMouseDragged:
            mouseDragged = true
            dragEvents.append(event)
            return []
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
                modifierFlags: event.modifierFlags,
                eventKind: .keyDown,
                isRepeat: event.isKeyboardRepeat
            )]
        case .keyUp:
            guard let keyCode = event.keyCode else { return [] }
            return [.keyboard(
                keyCode: keyCode,
                characters: event.characters,
                modifierFlags: event.modifierFlags,
                eventKind: .keyUp
            )]
        case .flagsChanged:
            guard let keyCode = event.keyCode,
                  let flagMask = Self.modifierFlagMask(for: keyCode) else { return [] }
            let eventKind: KeyboardPayload.EventKind
            if event.modifierFlags & flagMask == 0 || pressedModifierKeyCodes.contains(keyCode) {
                eventKind = .keyUp
                pressedModifierKeyCodes.remove(keyCode)
            } else {
                eventKind = .keyDown
                pressedModifierKeyCodes.insert(keyCode)
            }
            return [.keyboard(
                keyCode: keyCode,
                characters: nil,
                modifierFlags: event.modifierFlags,
                eventKind: eventKind
            )]
        }
    }

    private mutating func finishMouseInteraction(with event: RawInputEvent) -> [MacroAction] {
        defer {
            mouseDown = nil
            mouseDragged = false
            dragEvents = []
        }
        guard let mouseDown else { return [] }

        if mouseDragged {
            actionStartTimestampNanoseconds = mouseDown.timestampNanoseconds
            dragEvents.append(event)
            let path = dragEvents.map { dragEvent in
                TimedScreenPoint(
                    point: dragEvent.location,
                    offsetMilliseconds: elapsedMilliseconds(
                        from: mouseDown.timestampNanoseconds,
                        to: dragEvent.timestampNanoseconds
                    )
                )
            }
            return [MacroAction(
                kind: .drag,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(
                    start: mouseDown.location,
                    end: event.location,
                    path: path,
                    durationMilliseconds: path.last?.offsetMilliseconds,
                    buttonNumber: mouseDown.buttonNumber
                )
            )]
        }

        if event.kind == .rightMouseUp || event.buttonNumber == 1 {
            previousClickActionID = nil
            return [.click(
                kind: .rightClick,
                point: event.location,
                strategy: .screenCoordinate
            )]
        }

        var action = MacroAction.click(
            kind: event.clickCount >= 2 ? .doubleClick : .click,
            point: event.location,
            strategy: .screenCoordinate
        )
        if event.clickCount >= 2 {
            if let previousClickActionID {
                action.id = previousClickActionID
            }
            previousClickActionID = nil
        } else {
            previousClickActionID = action.id
        }
        return [action]
    }

    private func movementAction(for event: RawInputEvent) -> [MacroAction] {
        guard mode == .allMouseMovement else { return [] }
        return [MacroAction(
            kind: .mouseMove,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: event.location)
        )]
    }

    private func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> UInt64 {
        guard end > start else { return 0 }
        return (end - start) / 1_000_000
    }

    private static func modifierFlagMask(for keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 54, 55: return 0x0010_0000
        case 56, 60: return 0x0002_0000
        case 58, 61: return 0x0008_0000
        case 59, 62: return 0x0004_0000
        case 57: return 0x0001_0000
        default: return nil
        }
    }
}
