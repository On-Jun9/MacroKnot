import Combine
import CoreGraphics
import Foundation
import MacroKnotCore

@MainActor
protocol GlobalStopMonitoring: AnyObject {
    var isAwaitingShortcutRelease: Bool { get }
    func start(onStop: @escaping () -> Void) throws
    func stop()
}

protocol InputReleasingActionPerformer: MacroActionPerforming {
    func releaseAllInputs() async
}

protocol SystemEventPosting: Sendable {
    func postMouse(
        type: CGEventType,
        point: ScreenPoint,
        button: CGMouseButton,
        clickState: Int64?
    ) throws
    func postScroll(deltaX: Double, deltaY: Double) throws
    func postKeyboard(_ keyboard: KeyboardPayload, isDown: Bool) throws
    var currentMouseLocation: ScreenPoint { get }
}

@MainActor
final class InputPlayer: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case completed
        case stopped
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var currentIteration = 0
    @Published private(set) var currentActionIndex = 0
    @Published private(set) var totalActionCount = 0
    @Published private(set) var activeOptions: PlaybackOptions?
    private var task: Task<Void, Never>?
    private var performer: (any InputReleasingActionPerformer)?
    private let globalStopMonitor: any GlobalStopMonitoring
    private let performerFactory: () -> any InputReleasingActionPerformer

    init(
        globalStopMonitor: any GlobalStopMonitoring = GlobalStopMonitor(),
        performerFactory: @escaping () -> any InputReleasingActionPerformer = {
            SystemActionPerformer()
        }
    ) {
        self.globalStopMonitor = globalStopMonitor
        self.performerFactory = performerFactory
    }

    func play(document: MacroDocument, options: PlaybackOptions = .default) {
        guard task == nil, !document.actions.isEmpty else { return }
        do {
            try options.validate()
            try document.validateForPlayback(
                currentDisplayConfiguration: DisplayConfigurationProvider.current()
            )
        } catch {
            state = .failed(error.localizedDescription)
            RuntimeEventLogger.record(
                "playback_preflight",
                result: "FAIL",
                fields: ["error": error.localizedDescription]
            )
            return
        }
        let actions: [MacroAction]
        do {
            actions = try document.actions.map { try $0.scalingTiming(for: options.rate) }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        RuntimeEventLogger.record(
            "playback_preflight",
            result: "PASS",
            fields: [
                "action_count": String(actions.count),
                "rate": String(options.rate),
                "repetition": options.repetition.logValue,
            ]
        )
        do {
            try globalStopMonitor.start { [weak self] in
                self?.stopFromGlobalShortcut()
            }
        } catch {
            state = .failed(error.localizedDescription)
            RuntimeEventLogger.record(
                "global_stop_monitor_started",
                result: "FAIL",
                fields: ["error": error.localizedDescription]
            )
            return
        }
        state = .running
        currentIteration = 1
        currentActionIndex = 1
        totalActionCount = actions.count
        activeOptions = options
        RuntimeEventLogger.record(
            "playback_started",
            result: "PASS",
            fields: [
                "action_count": String(actions.count),
                "rate": String(options.rate),
                "repetition": options.repetition.logValue,
            ]
        )
        let performer = performerFactory()
        self.performer = performer
        let engine = MacroExecutionEngine(performer: performer)
        task = Task { [weak self] in
            do {
                var iteration = 0
                while options.repetition.shouldRun(iteration: iteration) {
                    try Task.checkCancellation()
                    self?.currentIteration = iteration + 1
                    self?.currentActionIndex = 1
                    try await engine.run(actions) { actionIndex in
                        await MainActor.run {
                            self?.currentActionIndex = actionIndex
                        }
                    }
                    iteration += 1
                }
                await performer.releaseAllInputs()
                guard !Task.isCancelled else {
                    self?.finish(.stopped)
                    return
                }
                self?.finish(.completed)
            } catch is CancellationError {
                await performer.releaseAllInputs()
                self?.finish(.stopped)
            } catch {
                await performer.releaseAllInputs()
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        task?.cancel()
        if task != nil {
            state = .stopped
        }
        globalStopMonitor.stop()
    }

    private func finish(_ state: State) {
        self.state = state
        if state != .running {
            currentIteration = 0
            currentActionIndex = 0
            totalActionCount = 0
            activeOptions = nil
        }
        task = nil
        performer = nil
        RuntimeEventLogger.record(
            "playback_finished",
            result: state.isFailure ? "FAIL" : "PASS",
            fields: state.logFields
        )
        if state != .stopped && !globalStopMonitor.isAwaitingShortcutRelease {
            globalStopMonitor.stop()
        }
    }

    private func stopFromGlobalShortcut() {
        RuntimeEventLogger.record(
            "global_stop_triggered",
            result: "PASS",
            fields: ["shortcut": "control_escape"]
        )
        task?.cancel()
        if task != nil {
            state = .stopped
        }
    }
}

private extension PlaybackOptions.Repetition {
    func shouldRun(iteration: Int) -> Bool {
        switch self {
        case .finite(let count): return iteration < count
        case .infinite: return true
        }
    }

    var logValue: String {
        switch self {
        case .finite(let count): return String(count)
        case .infinite: return "infinite"
        }
    }
}

private extension InputPlayer.State {
    var logValue: String {
        switch self {
        case .idle: return "idle"
        case .running: return "running"
        case .completed: return "completed"
        case .stopped: return "stopped"
        case .failed: return "failed"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var logFields: [String: String] {
        var fields = ["state": logValue]
        if case let .failed(message) = self {
            fields["error"] = message
        }
        return fields
    }
}

actor SystemActionPerformer: InputReleasingActionPerformer {
    private var heldKeyFlags: [UInt16: UInt64] = [:]
    private var heldMouseButtons: Set<UInt32> = []
    private let eventPoster: any SystemEventPosting

    init(eventPoster: any SystemEventPosting = CoreGraphicsEventPoster()) {
        self.eventPoster = eventPoster
    }

    func perform(_ action: MacroAction) async throws {
        try Task.checkCancellation()
        switch action.kind {
        case .click, .doubleClick, .rightClick:
            try postClick(action)
        case .mouseMove:
            try postMouseMove(action)
        case .drag:
            try await postDrag(action)
        case .scroll:
            try postScroll(action)
        case .keyboard:
            try postKeyboard(action)
        case .wait:
            guard let milliseconds = action.wait?.milliseconds else {
                throw InputPlayerError.invalidAction
            }
            try await Task.sleep(for: .milliseconds(milliseconds))
        case .capture:
            guard let capture = action.capture else { throw InputPlayerError.invalidAction }
            let destination = try await ScreenCaptureService.capture(capture)
            await RuntimeEventLogger.record(
                "capture_saved",
                result: "PASS",
                fields: ["file": destination.lastPathComponent]
            )
        case .repeatBlock:
            throw InputPlayerError.invalidAction
        }
    }

    private func postClick(_ action: MacroAction) throws {
        guard let point = action.mouse?.start else { throw InputPlayerError.invalidAction }
        let button: CGMouseButton = action.kind == .rightClick ? .right : .left
        let downType: CGEventType = action.kind == .rightClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = action.kind == .rightClick ? .rightMouseUp : .leftMouseUp
        let count = action.kind == .doubleClick ? 2 : 1

        for clickIndex in 1...count {
            try eventPoster.postMouse(
                type: downType,
                point: point,
                button: button,
                clickState: Int64(clickIndex)
            )
            try eventPoster.postMouse(
                type: upType,
                point: point,
                button: button,
                clickState: Int64(clickIndex)
            )
        }
    }

    private func postMouseMove(_ action: MacroAction) throws {
        guard let point = action.mouse?.start else { throw InputPlayerError.invalidAction }
        try eventPoster.postMouse(
            type: .mouseMoved,
            point: point,
            button: .left,
            clickState: nil
        )
    }

    private func postDrag(_ action: MacroAction) async throws {
        guard let start = action.mouse?.start, let end = action.mouse?.end else {
            throw InputPlayerError.invalidAction
        }
        let button: CGMouseButton = action.mouse?.buttonNumber == 1 ? .right : .left
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let draggedType: CGEventType = button == .right ? .rightMouseDragged : .leftMouseDragged
        heldMouseButtons.insert(button.rawValue)
        try eventPoster.postMouse(
            type: downType,
            point: start,
            button: button,
            clickState: nil
        )

        var currentPoint = start
        do {
            let path = action.mouse?.path ?? [
                TimedScreenPoint(point: start, offsetMilliseconds: 0),
                TimedScreenPoint(
                    point: end,
                    offsetMilliseconds: action.mouse?.durationMilliseconds ?? 30
                ),
            ]
            var previousOffset = path.first?.offsetMilliseconds ?? 0
            for sample in path.dropFirst() {
                try Task.checkCancellation()
                let delay = sample.offsetMilliseconds - previousOffset
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(delay))
                }
                try eventPoster.postMouse(
                    type: draggedType,
                    point: sample.point,
                    button: button,
                    clickState: nil
                )
                currentPoint = sample.point
                previousOffset = sample.offsetMilliseconds
            }
            try postMouseUp(button: button, point: end)
        } catch {
            try? postMouseUp(button: button, point: currentPoint)
            throw error
        }
    }

    private func postScroll(_ action: MacroAction) throws {
        guard let mouse = action.mouse else { throw InputPlayerError.invalidAction }
        let deltaX = mouse.scrollDeltaX ?? 0
        let deltaY = mouse.scrollDeltaY ?? 0
        guard deltaX.isFinite,
              deltaY.isFinite,
              deltaX >= Double(Int32.min),
              deltaX <= Double(Int32.max),
              deltaY >= Double(Int32.min),
              deltaY <= Double(Int32.max) else {
            throw InputPlayerError.invalidAction
        }
        try postMouseMove(MacroAction(
            kind: .mouseMove,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: mouse.start)
        ))
        try eventPoster.postScroll(
            deltaX: deltaX,
            deltaY: deltaY
        )
    }

    private func postKeyboard(_ action: MacroAction) throws {
        guard let keyboard = action.keyboard else { throw InputPlayerError.invalidAction }
        switch keyboard.resolvedEventKind {
        case .press:
            try postKey(keyboard, isDown: true)
            try postKey(keyboard, isDown: false)
        case .keyDown:
            try postKey(keyboard, isDown: true)
            heldKeyFlags[keyboard.keyCode] = keyboard.modifierFlags
        case .keyUp:
            try postKey(keyboard, isDown: false)
            heldKeyFlags.removeValue(forKey: keyboard.keyCode)
        }
    }

    private func postKey(_ keyboard: KeyboardPayload, isDown: Bool) throws {
        try eventPoster.postKeyboard(keyboard, isDown: isDown)
    }

    private func postMouseUp(button: CGMouseButton, point: ScreenPoint) throws {
        try eventPoster.postMouse(
            type: button == .right ? .rightMouseUp : .leftMouseUp,
            point: point,
            button: button,
            clickState: nil
        )
        heldMouseButtons.remove(button.rawValue)
    }

    func releaseAllInputs() {
        for keyCode in heldKeyFlags.keys {
            let keyboard = KeyboardPayload(
                keyCode: keyCode,
                characters: nil,
                modifierFlags: 0,
                eventKind: .keyUp
            )
            try? postKey(keyboard, isDown: false)
        }
        heldKeyFlags.removeAll()

        let current = eventPoster.currentMouseLocation
        for rawButton in heldMouseButtons {
            guard let button = CGMouseButton(rawValue: rawButton) else { continue }
            try? eventPoster.postMouse(
                type: button == .right ? .rightMouseUp : .leftMouseUp,
                point: current,
                button: button,
                clickState: nil
            )
        }
        heldMouseButtons.removeAll()
    }
}

struct CoreGraphicsEventPoster: SystemEventPosting {
    var currentMouseLocation: ScreenPoint {
        let point = CGEvent(source: nil)?.location ?? .zero
        return ScreenPoint(x: point.x, y: point.y)
    }

    func postMouse(
        type: CGEventType,
        point: ScreenPoint,
        button: CGMouseButton,
        clickState: Int64?
    ) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: CGPoint(x: point.x, y: point.y),
            mouseButton: button
        ) else { throw InputPlayerError.eventCreationFailed }
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        event.post(tap: .cghidEventTap)
    }

    func postScroll(deltaX: Double, deltaY: Double) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY.rounded()),
            wheel2: Int32(deltaX.rounded()),
            wheel3: 0
        ) else { throw InputPlayerError.eventCreationFailed }
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: deltaX)
        event.post(tap: .cghidEventTap)
    }

    func postKeyboard(_ keyboard: KeyboardPayload, isDown: Bool) throws {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyboard.keyCode),
            keyDown: isDown
        ) else { throw InputPlayerError.eventCreationFailed }
        event.flags = CGEventFlags(rawValue: keyboard.modifierFlags)
        if keyboard.isRepeat == true {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        if let characters = keyboard.characters {
            let utf16 = Array(characters.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let address = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: address
                )
            }
        }
        event.post(tap: .cghidEventTap)
    }
}

private enum InputPlayerError: LocalizedError {
    case invalidAction
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidAction: return "재생할 액션 구성이 올바르지 않습니다."
        case .eventCreationFailed: return "macOS 입력 이벤트를 만들지 못했습니다."
        }
    }
}
