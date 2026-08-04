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
        return "실행 전 \(MacroDurationFormatter.concise(milliseconds: delayBeforeMilliseconds)) · \(detail)"
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

enum PlaybackProgressPresentation {
    static func iterationValue(
        iteration: Int,
        repetition: PlaybackOptions.Repetition
    ) -> String {
        switch repetition {
        case .finite(let count):
            return "\(iteration)/\(count)"
        case .infinite:
            return "\(iteration)/∞"
        }
    }

    static func iterationText(
        iteration: Int,
        repetition: PlaybackOptions.Repetition
    ) -> String {
        switch repetition {
        case .finite(let count):
            return "반복 \(iteration)/\(count)"
        case .infinite:
            return "반복 \(iteration) · 무한 반복"
        }
    }

    static func actionValue(actionIndex: Int?, actionCount: Int?) -> String? {
        guard let actionIndex, let actionCount, actionIndex > 0, actionCount > 0 else {
            return nil
        }
        return "\(actionIndex)/\(actionCount)"
    }

    static func statusText(
        iteration: Int,
        repetition: PlaybackOptions.Repetition,
        actionIndex: Int? = nil,
        actionCount: Int? = nil
    ) -> String {
        let iterationText = iterationText(iteration: iteration, repetition: repetition)
        guard let actionValue = actionValue(
            actionIndex: actionIndex,
            actionCount: actionCount
        ) else {
            return iterationText
        }
        return "\(iterationText) · 액션 \(actionValue)"
    }
}

enum PlaybackWaitPresentation {
    /// 남은 시간을 세는 두 가지 원인. 대기 액션과 `실행 전 대기`는 화면에서 다르게 표기한다.
    enum Wait: Equatable {
        case waitAction(milliseconds: UInt64)
        case delayBeforeAction(milliseconds: UInt64)
    }

    /// 짧은 `실행 전 대기`에서 `0:00`이 번쩍이지 않도록 이 시간 이상만 표시한다.
    /// 대기 액션에는 적용하지 않으므로 재생 속도로 짧아져도 표시가 사라지지 않는다.
    static let delayDisplayThresholdMilliseconds: UInt64 = 1_000

    /// 실행 중 남은 시간을 표시할 대상이면 그 종류와 시간을, 아니면 `nil`을 돌려준다.
    /// 실행 엔진은 액션 시작을 알린 뒤 `실행 전 대기`부터 쉬므로, 대기 액션에 붙은
    /// `실행 전 대기`는 그 액션이 끝날 때까지의 시간으로 함께 더한다.
    static func displayedWait(for action: MacroAction) -> Wait? {
        let delay = action.delayBeforeMilliseconds ?? 0
        if action.kind == .wait, let milliseconds = action.wait?.milliseconds {
            let total = milliseconds.addingReportingOverflow(delay)
            return .waitAction(milliseconds: total.overflow ? .max : total.partialValue)
        }
        guard delay >= delayDisplayThresholdMilliseconds else { return nil }
        return .delayBeforeAction(milliseconds: delay)
    }
}

extension PlaybackWaitPresentation.Wait {
    var milliseconds: UInt64 {
        switch self {
        case let .waitAction(milliseconds), let .delayBeforeAction(milliseconds):
            return milliseconds
        }
    }

    var isWaitAction: Bool {
        if case .waitAction = self { return true }
        return false
    }
}

enum DraftRecoveryPresentation {
    private static func name(for draft: MacroDraftRecord) -> String {
        let trimmedName = draft.document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "이름 없는 매크로" : trimmedName
    }

    static func message(
        for draft: MacroDraftRecord,
        formatDate: (Date) -> String = {
            $0.formatted(date: .abbreviated, time: .shortened)
        }
    ) -> String {
        "\(name(for: draft)) · 마지막 수정: \(formatDate(draft.updatedAt))"
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

    func contains(actionNumber: Int) -> Bool {
        let index = actionNumber - 1
        return startIndex...endIndex ~= index
    }

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
