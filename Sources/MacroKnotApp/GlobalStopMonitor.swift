import CoreGraphics
import Foundation
import MacroKnotCore

final class GlobalStopMonitor {
    private(set) var isAwaitingShortcutRelease = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onStop: (() -> Void)?

    func start(onStop: @escaping () -> Void) throws {
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
            callback: globalStopEventTapCallback,
            userInfo: pointer
        ) else {
            throw GlobalStopMonitorError.eventTapUnavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.onStop = onStop
        self.tap = tap
        self.source = source
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
        onStop = nil
        isAwaitingShortcutRelease = false
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            let flags = event.flags
            let matches = EmergencyStopShortcut.matches(
                keyCode: keyCode,
                controlPressed: flags.contains(.maskControl),
                optionPressed: flags.contains(.maskAlternate),
                commandPressed: flags.contains(.maskCommand),
                shiftPressed: flags.contains(.maskShift)
            )
            guard matches || (isAwaitingShortcutRelease && keyCode == EmergencyStopShortcut.keyCode) else {
                return Unmanaged.passUnretained(event)
            }
            if !isAwaitingShortcutRelease {
                isAwaitingShortcutRelease = true
                onStop?()
            }
            return nil
        }

        if type == .keyUp,
           isAwaitingShortcutRelease,
           keyCode == EmergencyStopShortcut.keyCode {
            stop()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private func globalStopEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalStopMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.receive(type: type, event: event)
}

private enum GlobalStopMonitorError: LocalizedError {
    case eventTapUnavailable

    var errorDescription: String? {
        "전역 강제 중지를 시작하지 못했습니다. 손쉬운 사용 권한을 확인하십시오."
    }
}
