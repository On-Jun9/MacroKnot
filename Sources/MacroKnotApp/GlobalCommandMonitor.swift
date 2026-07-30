import Combine
import CoreGraphics
import Foundation

enum GlobalCommand {
    case toggleRecording
    case play
}

struct GlobalShortcutDefinition: Equatable {
    let keyCode: UInt16
    let control: Bool
    let option: Bool
    let command: Bool
    let shift: Bool

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        keyCode == self.keyCode
            && flags.contains(.maskControl) == control
            && flags.contains(.maskAlternate) == option
            && flags.contains(.maskCommand) == command
            && flags.contains(.maskShift) == shift
    }
}

enum RecordingShortcutChoice: String, CaseIterable, Identifiable {
    case disabled
    case controlOptionR
    case commandShiftR
    case controlShiftR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "사용 안 함"
        case .controlOptionR: return "Control + Option + R"
        case .commandShiftR: return "Command + Shift + R"
        case .controlShiftR: return "Control + Shift + R"
        }
    }

    var definition: GlobalShortcutDefinition? {
        switch self {
        case .disabled:
            return nil
        case .controlOptionR:
            return GlobalShortcutDefinition(
                keyCode: 15, control: true, option: true, command: false, shift: false
            )
        case .commandShiftR:
            return GlobalShortcutDefinition(
                keyCode: 15, control: false, option: false, command: true, shift: true
            )
        case .controlShiftR:
            return GlobalShortcutDefinition(
                keyCode: 15, control: true, option: false, command: false, shift: true
            )
        }
    }
}

enum PlaybackShortcutChoice: String, CaseIterable, Identifiable {
    case disabled
    case controlOptionP
    case commandShiftP
    case controlShiftP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "사용 안 함"
        case .controlOptionP: return "Control + Option + P"
        case .commandShiftP: return "Command + Shift + P"
        case .controlShiftP: return "Control + Shift + P"
        }
    }

    var definition: GlobalShortcutDefinition? {
        switch self {
        case .disabled:
            return nil
        case .controlOptionP:
            return GlobalShortcutDefinition(
                keyCode: 35, control: true, option: true, command: false, shift: false
            )
        case .commandShiftP:
            return GlobalShortcutDefinition(
                keyCode: 35, control: false, option: false, command: true, shift: true
            )
        case .controlShiftP:
            return GlobalShortcutDefinition(
                keyCode: 35, control: true, option: false, command: false, shift: true
            )
        }
    }
}

final class GlobalCommandMonitor: ObservableObject {
    @Published private(set) var errorMessage: String?

    var onCommand: ((GlobalCommand) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var capturedKeyCode: UInt16?

    func start() {
        guard tap == nil else { return }
        let mask = [CGEventType.keyDown, .keyUp].reduce(CGEventMask(0)) { partial, type in
            partial | (CGEventMask(1) << type.rawValue)
        }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalCommandEventTapCallback,
            userInfo: pointer
        ) else {
            errorMessage = "전역 단축키를 시작하지 못했습니다. 손쉬운 사용 권한을 확인하십시오."
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        errorMessage = nil
        CGEvent.tapEnable(tap: tap, enable: true)
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
        capturedKeyCode = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, capturedKeyCode == keyCode {
            capturedKeyCode = nil
            return nil
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        if capturedKeyCode == keyCode {
            return nil
        }
        guard let command = Self.command(keyCode: keyCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }
        guard onCommand?(command) == true else {
            return Unmanaged.passUnretained(event)
        }
        capturedKeyCode = keyCode
        return nil
    }

    static func command(keyCode: UInt16, flags: CGEventFlags) -> GlobalCommand? {
        let defaults = UserDefaults.standard
        let recordingRawValue = defaults.string(
            forKey: AppPreferenceKeys.recordingShortcut
        ) ?? AppPreferenceDefaults.recordingShortcut.rawValue
        let recording = RecordingShortcutChoice(rawValue: recordingRawValue)
            ?? AppPreferenceDefaults.recordingShortcut
        if recording.definition?.matches(keyCode: keyCode, flags: flags) == true {
            return .toggleRecording
        }

        let playbackRawValue = defaults.string(
            forKey: AppPreferenceKeys.playbackShortcut
        ) ?? AppPreferenceDefaults.playbackShortcut.rawValue
        let playback = PlaybackShortcutChoice(rawValue: playbackRawValue)
            ?? AppPreferenceDefaults.playbackShortcut
        if playback.definition?.matches(keyCode: keyCode, flags: flags) == true {
            return .play
        }
        return nil
    }
}

private func globalCommandEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalCommandMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.receive(type: type, event: event)
}
