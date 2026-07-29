import Combine
import CoreGraphics
import Foundation
import MacroKnotCore

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
    private var task: Task<Void, Never>?
    private let globalStopMonitor = GlobalStopMonitor()

    func play(actions: [MacroAction]) {
        guard task == nil, !actions.isEmpty else { return }
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
        RuntimeEventLogger.record(
            "playback_started",
            result: "PASS",
            fields: ["action_count": String(actions.count)]
        )
        let engine = MacroExecutionEngine(performer: SystemActionPerformer())
        task = Task { [weak self] in
            do {
                try await engine.run(actions)
                guard !Task.isCancelled else {
                    self?.finish(.stopped)
                    return
                }
                self?.finish(.completed)
            } catch is CancellationError {
                self?.finish(.stopped)
            } catch {
                self?.finish(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        task?.cancel()
        if task != nil {
            state = .stopped
        }
        task = nil
        globalStopMonitor.stop()
    }

    private func finish(_ state: State) {
        self.state = state
        task = nil
        RuntimeEventLogger.record(
            "playback_finished",
            result: "PASS",
            fields: ["state": state.logValue]
        )
        if !globalStopMonitor.isAwaitingShortcutRelease {
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
        task = nil
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
}

private struct SystemActionPerformer: MacroActionPerforming {
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
            throw InputPlayerError.captureNotImplemented
        case .repeatBlock:
            throw InputPlayerError.invalidAction
        }
    }

    private func postClick(_ action: MacroAction) throws {
        guard let point = action.mouse?.start else { throw InputPlayerError.invalidAction }
        let position = CGPoint(x: point.x, y: point.y)
        let button: CGMouseButton = action.kind == .rightClick ? .right : .left
        let downType: CGEventType = action.kind == .rightClick ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = action.kind == .rightClick ? .rightMouseUp : .leftMouseUp
        let count = action.kind == .doubleClick ? 2 : 1

        for clickIndex in 1...count {
            guard
                let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: position, mouseButton: button),
                let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: position, mouseButton: button)
            else { throw InputPlayerError.eventCreationFailed }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postMouseMove(_ action: MacroAction) throws {
        guard let point = action.mouse?.start,
              let event = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: point.x, y: point.y),
                mouseButton: .left
              ) else { throw InputPlayerError.invalidAction }
        event.post(tap: .cghidEventTap)
    }

    private func postDrag(_ action: MacroAction) async throws {
        guard let start = action.mouse?.start, let end = action.mouse?.end else {
            throw InputPlayerError.invalidAction
        }
        let startPoint = CGPoint(x: start.x, y: start.y)
        let endPoint = CGPoint(x: end.x, y: end.y)
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left),
            let dragged = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: endPoint, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
        else { throw InputPlayerError.eventCreationFailed }
        var didReleaseButton = false
        defer {
            if !didReleaseButton {
                up.post(tap: .cghidEventTap)
            }
        }
        down.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(30))
        dragged.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        didReleaseButton = true
    }

    private func postScroll(_ action: MacroAction) throws {
        guard let mouse = action.mouse,
              let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(mouse.scrollDeltaY ?? 0),
                wheel2: Int32(mouse.scrollDeltaX ?? 0),
                wheel3: 0
              ) else { throw InputPlayerError.invalidAction }
        event.post(tap: .cghidEventTap)
    }

    private func postKeyboard(_ action: MacroAction) throws {
        guard let keyboard = action.keyboard,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyboard.keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyboard.keyCode), keyDown: false)
        else { throw InputPlayerError.invalidAction }
        let flags = CGEventFlags(rawValue: keyboard.modifierFlags)
        down.flags = flags
        up.flags = flags
        if let characters = keyboard.characters {
            let utf16 = Array(characters.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let address = buffer.baseAddress else { return }
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private enum InputPlayerError: LocalizedError {
    case invalidAction
    case eventCreationFailed
    case captureNotImplemented

    var errorDescription: String? {
        switch self {
        case .invalidAction: return "재생할 액션 구성이 올바르지 않습니다."
        case .eventCreationFailed: return "macOS 입력 이벤트를 만들지 못했습니다."
        case .captureNotImplemented: return "캡처 액션 재생은 아직 구현되지 않았습니다."
        }
    }
}
