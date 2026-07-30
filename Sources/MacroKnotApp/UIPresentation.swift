import Foundation
import MacroKnotCore
import SwiftUI

extension MacroAction.Kind {
    var displayName: String {
        switch self {
        case .click: return "클릭"
        case .doubleClick: return "더블클릭"
        case .rightClick: return "우클릭"
        case .mouseMove: return "마우스 이동"
        case .drag: return "드래그"
        case .scroll: return "스크롤"
        case .keyboard: return "키 입력"
        case .wait: return "대기"
        case .capture: return "캡처"
        case .repeatBlock: return "반복"
        }
    }

    var systemImage: String {
        switch self {
        case .click, .doubleClick, .rightClick: return "cursorarrow.click"
        case .mouseMove: return "cursorarrow.motionlines"
        case .drag: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scroll: return "scroll"
        case .keyboard: return "keyboard"
        case .wait: return "timer"
        case .capture: return "camera"
        case .repeatBlock: return "repeat"
        }
    }

    var tint: Color {
        switch self {
        case .click, .doubleClick, .rightClick: return .blue
        case .mouseMove, .drag, .scroll: return .indigo
        case .keyboard: return .purple
        case .wait: return .orange
        case .capture: return .teal
        case .repeatBlock: return .pink
        }
    }
}

extension MacroAction {
    var summary: String {
        let detail: String
        switch kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            guard let point = mouse?.start else { return "세부 정보 없음" }
            detail = "화면 좌표 \(Self.pointText(point))"
        case .drag:
            guard let start = mouse?.start, let end = mouse?.end else {
                return "세부 정보 없음"
            }
            let duration = MacroDurationFormatter.concise(
                milliseconds: mouse?.durationMilliseconds ?? 0
            )
            detail = "\(Self.pointText(start)) → \(Self.pointText(end)) · \(duration)"
        case .scroll:
            detail = "가로 \(Self.number(mouse?.scrollDeltaX ?? 0)) · 세로 \(Self.number(mouse?.scrollDeltaY ?? 0))"
        case .keyboard:
            guard let keyboard else { return "세부 정보 없음" }
            let input =
                Self.keyboardInputText(keyboard.characters)
                ?? "키 코드 \(keyboard.keyCode)"
            let event = keyboard.resolvedEventKind.presentationName
            detail =
                keyboard.modifierFlags == 0
                ? "\(input) · \(event)"
                : "\(input) · 보조 키 포함 · \(event)"
        case .wait:
            detail = MacroDurationFormatter.concise(milliseconds: wait?.milliseconds ?? 0)
        case .capture:
            guard let capture else { return "세부 정보 없음" }
            let folder = URL(fileURLWithPath: capture.destinationDirectory).lastPathComponent
            detail = "\(capture.target.presentationName) → \(folder.isEmpty ? "저장 폴더" : folder)"
        case .repeatBlock:
            let count = repeatBlock?.count ?? 0
            let actionCount = repeatBlock?.actions.count ?? 0
            detail = "\(actionCount)개 액션을 \(count)회 반복"
        }

        guard let delayBeforeMilliseconds, delayBeforeMilliseconds > 0 else {
            return detail
        }
        return "시작 전 \(MacroDurationFormatter.concise(milliseconds: delayBeforeMilliseconds)) · \(detail)"
    }

    var estimatedDurationMilliseconds: UInt64 {
        let delay = delayBeforeMilliseconds ?? 0
        let actionDuration: UInt64
        switch kind {
        case .drag:
            actionDuration = mouse?.durationMilliseconds ?? 30
        case .wait:
            actionDuration = wait?.milliseconds ?? 0
        case .repeatBlock:
            let repeated = repeatBlock?.actions.estimatedDurationMilliseconds ?? 0
            let result = repeated.multipliedReportingOverflow(
                by: UInt64(max(repeatBlock?.count ?? 0, 0))
            )
            actionDuration = result.overflow ? .max : result.partialValue
        default:
            actionDuration = 0
        }
        let result = delay.addingReportingOverflow(actionDuration)
        return result.overflow ? .max : result.partialValue
    }

    private static func pointText(_ point: ScreenPoint) -> String {
        "(\(number(point.x)), \(number(point.y)))"
    }

    private static func keyboardInputText(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        switch value {
        case "\r", "\n": return "Return"
        case "\t": return "Tab"
        case " ": return "Space"
        case "\u{1B}": return "Escape"
        default:
            let singleLine =
                value
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            return "“\(singleLine)”"
        }
    }

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "잘못된 값" }
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.3g", value)
        }
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

extension Array where Element == MacroAction {
    var estimatedDurationMilliseconds: UInt64 {
        reduce(0) { total, action in
            let result = total.addingReportingOverflow(action.estimatedDurationMilliseconds)
            return result.overflow ? .max : result.partialValue
        }
    }

    var containsCaptureAction: Bool {
        contains { action in
            action.kind == .capture
                || action.repeatBlock?.actions.containsCaptureAction == true
        }
    }
}

enum MacroDurationFormatter {
    static func concise(milliseconds: UInt64) -> String {
        guard milliseconds >= 1_000 else { return "\(milliseconds)ms" }
        if milliseconds.isMultiple(of: 1_000) {
            return "\(milliseconds / 1_000)초"
        }
        return String(format: "%.1f초", Double(milliseconds) / 1_000)
    }
}

struct MacroActionPreviewItem: Identifiable {
    let id: UUID
    let startIndex: Int
    let endIndex: Int
    let firstAction: MacroAction
    let lastAction: MacroAction

    var kind: MacroAction.Kind { firstAction.kind }
    var count: Int { endIndex - startIndex + 1 }

    var sourceLabel: String {
        startIndex == endIndex
            ? "\(startIndex + 1)"
            : "\(startIndex + 1)–\(endIndex + 1)"
    }

    var title: String {
        count > 1 && kind == .mouseMove
            ? "마우스 이동 ×\(count)"
            : kind.displayName
    }

    var summary: String {
        guard count > 1, kind == .mouseMove,
              let start = firstAction.mouse?.start,
              let end = lastAction.mouse?.start else {
            return firstAction.summary
        }
        return "\(Self.pointText(start)) → \(Self.pointText(end)) · 연속 이동 경로"
    }

    static func grouped(_ actions: [MacroAction]) -> [Self] {
        var result: [Self] = []
        var index = 0
        while index < actions.count {
            let first = actions[index]
            var endIndex = index
            if first.kind == .mouseMove {
                while endIndex + 1 < actions.count,
                      actions[endIndex + 1].kind == .mouseMove {
                    endIndex += 1
                }
            }
            result.append(Self(
                id: first.id,
                startIndex: index,
                endIndex: endIndex,
                firstAction: first,
                lastAction: actions[endIndex]
            ))
            index = endIndex + 1
        }
        return result
    }

    private static func pointText(_ point: ScreenPoint) -> String {
        "(\(number(point.x)), \(number(point.y)))"
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}

extension KeyboardPayload.EventKind {
    fileprivate var presentationName: String {
        switch self {
        case .press: return "누르고 떼기"
        case .keyDown: return "누르기"
        case .keyUp: return "떼기"
        }
    }
}

extension CaptureTarget {
    fileprivate var presentationName: String {
        switch kind {
        case .display: return "디스플레이"
        case .application: return "앱"
        case .window: return "창"
        }
    }
}
