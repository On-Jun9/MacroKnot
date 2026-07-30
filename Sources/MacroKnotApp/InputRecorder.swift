import CoreGraphics
import Foundation
import MacroKnotCore

@MainActor
final class InputRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var actions: [MacroAction] = []
    @Published private(set) var lastEvent = "아직 녹화한 입력이 없습니다."
    @Published private(set) var errorMessage: String?

    private let driver = EventTapDriver()
    private var reducer = InputActionReducer(mode: .meaningfulActionsOnly)

    init() {
        driver.onEvent = { [weak self] event in
            self?.consume(event)
        }
    }

    func start(
        mode: InputRecordingMode,
        excludesEventsTargetingMacroKnot: Bool,
        suppressesInitialShortcutModifierReleases: Bool = false
    ) {
        guard !isRecording else { return }
        actions = []
        errorMessage = nil
        lastEvent = "입력을 기다리고 있습니다."
        reducer = InputActionReducer(
            mode: mode,
            recordingStartTimestampNanoseconds: Self.currentInputTimestampNanoseconds()
        )
        driver.excludesEventsTargetingRecorder = excludesEventsTargetingMacroKnot
        driver.suppressesShortcutModifierReleases = suppressesInitialShortcutModifierReleases

        do {
            try driver.start()
            isRecording = true
            RuntimeEventLogger.record(
                "recording_started",
                result: "PASS",
                fields: ["mode": mode.rawValue]
            )
        } catch {
            errorMessage = error.localizedDescription
            RuntimeEventLogger.record(
                "recording_started",
                result: "FAIL",
                fields: ["error": error.localizedDescription]
            )
        }
    }

    func stop(discardingTrailingShortcutModifiers: Bool = false) {
        driver.stop()
        if discardingTrailingShortcutModifiers {
            while actions.last?.isShortcutModifierKeyDown == true {
                actions.removeLast()
            }
        }
        isRecording = false
        RuntimeEventLogger.record(
            "recording_stopped",
            result: "PASS",
            fields: ["action_count": String(actions.count)]
        )
    }

    private func consume(_ event: RawInputEvent) {
        let reduced = reducer.consume(event, appendingTo: &actions)
        guard !reduced.isEmpty else { return }
        lastEvent = "\(event.kind.rawValue) → \(reduced.map(\.kind.rawValue).joined(separator: ", "))"
    }

    private static func currentInputTimestampNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

private final class EventTapDriver {
    var onEvent: ((RawInputEvent) -> Void)?
    var excludesEventsTargetingRecorder = true

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var windowOwnerProcessIDs: [CGWindowID: Int64] = [:]
    var suppressesShortcutModifierReleases = false

    func start() throws {
        guard tap == nil else { return }
        let mask = Self.eventTypes.reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: inputEventTapCallback,
            userInfo: pointer
        ) else {
            throw InputRecorderError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        source = nil
        tap = nil
        windowOwnerProcessIDs.removeAll()
        suppressesShortcutModifierReleases = false
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard let kind = Self.kind(for: type) else { return }
        if suppressesShortcutModifierReleases, kind == .flagsChanged {
            let flags = event.flags
            if !flags.contains(.maskControl),
               !flags.contains(.maskAlternate),
               !flags.contains(.maskCommand),
               !flags.contains(.maskShift) {
                suppressesShortcutModifierReleases = false
            }
            return
        }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let destinationPID = destinationProcessID(for: kind, event: event)
        let recorderPID = Int64(ProcessInfo.processInfo.processIdentifier)
        guard InputEventProcessFilter.shouldRecord(
            sourceProcessID: sourcePID,
            destinationProcessID: destinationPID,
            recorderProcessID: recorderPID,
            excludesEventsTargetingRecorder: excludesEventsTargetingRecorder
        ) else { return }

        let location = event.location
        onEvent?(RawInputEvent(
            kind: kind,
            timestampNanoseconds: event.timestamp,
            location: ScreenPoint(x: location.x, y: location.y),
            buttonNumber: event.getIntegerValueField(.mouseEventButtonNumber),
            clickCount: event.getIntegerValueField(.mouseEventClickState),
            scrollDeltaX: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
            scrollDeltaY: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),
            keyCode: type == .keyDown || type == .keyUp || type == .flagsChanged
                ? UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                : nil,
            characters: Self.characters(from: event),
            modifierFlags: event.flags.rawValue,
            isKeyboardRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        ))
    }

    private func destinationProcessID(for kind: RawInputEventKind, event: CGEvent) -> Int64? {
        guard kind.isPointerEvent else {
            return event.getIntegerValueField(.eventTargetUnixProcessID)
        }

        let handlingWindowID = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        let windowUnderPointerID = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let rawWindowID = handlingWindowID > 0 ? handlingWindowID : windowUnderPointerID
        guard rawWindowID > 0, rawWindowID <= Int64(UInt32.max) else {
            return nil
        }

        let windowID = CGWindowID(rawWindowID)
        if let cachedProcessID = windowOwnerProcessIDs[windowID] {
            return cachedProcessID
        }
        guard
            let windowInfo = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
                as? [[CFString: Any]],
            let ownerProcessID = windowInfo.first?[kCGWindowOwnerPID] as? NSNumber
        else {
            return nil
        }
        let processID = ownerProcessID.int64Value
        windowOwnerProcessIDs[windowID] = processID
        return processID
    }

    private static let eventTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .mouseMoved,
        .leftMouseDragged, .rightMouseDragged,
        .scrollWheel,
        .keyDown, .keyUp, .flagsChanged,
    ]

    private static func kind(for type: CGEventType) -> RawInputEventKind? {
        switch type {
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseUp: return .leftMouseUp
        case .rightMouseDown: return .rightMouseDown
        case .rightMouseUp: return .rightMouseUp
        case .mouseMoved: return .mouseMoved
        case .leftMouseDragged: return .leftMouseDragged
        case .rightMouseDragged: return .rightMouseDragged
        case .scrollWheel: return .scrollWheel
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        default: return nil
        }
    }

    private static func characters(from event: CGEvent) -> String? {
        guard event.type == .keyDown || event.type == .keyUp else { return nil }
        var buffer = [UniChar](repeating: 0, count: 16)
        var actualLength = 0
        buffer.withUnsafeMutableBufferPointer { pointer in
            event.keyboardGetUnicodeString(
                maxStringLength: pointer.count,
                actualStringLength: &actualLength,
                unicodeString: pointer.baseAddress
            )
        }
        guard actualLength > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: actualLength)
    }
}

private extension RawInputEventKind {
    var isPointerEvent: Bool {
        switch self {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .mouseMoved, .leftMouseDragged, .rightMouseDragged,
             .scrollWheel:
            return true
        case .keyDown, .keyUp, .flagsChanged:
            return false
        }
    }
}

private extension MacroAction {
    var isShortcutModifierKeyDown: Bool {
        guard kind == .keyboard,
              keyboard?.resolvedEventKind == .keyDown,
              let keyCode = keyboard?.keyCode
        else { return false }
        return [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(keyCode)
    }
}

private func inputEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let driver = Unmanaged<EventTapDriver>.fromOpaque(userInfo).takeUnretainedValue()
    driver.receive(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private enum InputRecorderError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "입력 이벤트 감시를 시작하지 못했습니다. 손쉬운 사용 권한을 확인하십시오."
    }
}
