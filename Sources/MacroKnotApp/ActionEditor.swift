import AppKit
import Foundation
import MacroKnotCore
import SwiftUI

struct ActionEditorDraft: Identifiable {
    var id = UUID()
    var kind = MacroAction.Kind.click
    var delay = ""
    var startX = "0"
    var startY = "0"
    var endX = "100"
    var endY = "100"
    var duration = "300"
    var dragButtonNumber: Int64 = 0
    var dragPath: [TimedScreenPoint]?
    var scrollX = "0"
    var scrollY = "-100"
    var keyCode = "0"
    var characters = "a"
    var modifierFlags = "0"
    var keyboardEventKind = KeyboardPayload.EventKind.press
    var keyboardIsRepeat = false
    var waitMilliseconds = "1000"
    var captureTargetKind = CaptureTarget.Kind.display
    var captureTargetValue = ""
    var destinationDirectory = ""
    var repeatCount = "2"
    var repeatActions: [MacroAction] = [.wait(milliseconds: 100)]

    init(kind: MacroAction.Kind) {
        self.kind = kind
    }

    init(action: MacroAction) {
        id = action.id
        kind = action.kind
        delay = action.delayBeforeMilliseconds.map(String.init) ?? ""
        if let mouse = action.mouse {
            startX = Self.string(mouse.start.x)
            startY = Self.string(mouse.start.y)
            endX = mouse.end.map { Self.string($0.x) } ?? "100"
            endY = mouse.end.map { Self.string($0.y) } ?? "100"
            duration = mouse.durationMilliseconds.map(String.init) ?? "300"
            dragButtonNumber = mouse.buttonNumber ?? 0
            dragPath = mouse.path
            scrollX = mouse.scrollDeltaX.map(Self.string) ?? "0"
            scrollY = mouse.scrollDeltaY.map(Self.string) ?? "-100"
        }
        if let keyboard = action.keyboard {
            keyCode = String(keyboard.keyCode)
            characters = keyboard.characters ?? ""
            modifierFlags = String(keyboard.modifierFlags)
            keyboardEventKind = keyboard.resolvedEventKind
            keyboardIsRepeat = keyboard.isRepeat == true
        }
        waitMilliseconds = action.wait.map { String($0.milliseconds) } ?? "1000"
        if let capture = action.capture {
            captureTargetKind = capture.target.kind
            captureTargetValue = capture.target.editorValue
            destinationDirectory = capture.destinationDirectory
        }
        repeatCount = action.repeatBlock.map { String($0.count) } ?? "2"
        repeatActions = action.repeatBlock?.actions ?? [.wait(milliseconds: 100)]
    }

    func makeAction() throws -> MacroAction {
        let delayValue = try optionalUInt64(delay, field: "실행 전 대기")
        let action: MacroAction
        switch kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            action = MacroAction(
                id: id,
                kind: kind,
                delayBeforeMilliseconds: delayValue,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(start: try startPoint())
            )
        case .drag:
            let start = try startPoint()
            let end = try endPoint()
            let durationValue = try requiredUInt64(duration, field: "드래그 지속시간")
            let preservedPath: [TimedScreenPoint]?
            if dragPath?.first?.point == start,
               dragPath?.last?.point == end,
               dragPath?.last?.offsetMilliseconds == durationValue {
                preservedPath = dragPath
            } else {
                preservedPath = nil
            }
            action = MacroAction(
                id: id,
                kind: .drag,
                delayBeforeMilliseconds: delayValue,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(
                    start: start,
                    end: end,
                    path: preservedPath,
                    durationMilliseconds: durationValue,
                    buttonNumber: dragButtonNumber
                )
            )
        case .scroll:
            action = MacroAction(
                id: id,
                kind: .scroll,
                delayBeforeMilliseconds: delayValue,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(
                    start: try startPoint(),
                    scrollDeltaX: try requiredDouble(scrollX, field: "가로 스크롤"),
                    scrollDeltaY: try requiredDouble(scrollY, field: "세로 스크롤")
                )
            )
        case .keyboard:
            guard let code = UInt16(keyCode) else {
                throw ActionDraftError.invalidField("키 코드")
            }
            guard let flags = UInt64(modifierFlags) else {
                throw ActionDraftError.invalidField("보조 키 플래그")
            }
            action = MacroAction(
                id: id,
                kind: .keyboard,
                delayBeforeMilliseconds: delayValue,
                keyboard: KeyboardPayload(
                    keyCode: code,
                    characters: characters.isEmpty ? nil : characters,
                    modifierFlags: flags,
                    eventKind: keyboardEventKind,
                    isRepeat: keyboardEventKind == .keyDown && keyboardIsRepeat
                )
            )
        case .wait:
            action = MacroAction(
                id: id,
                kind: .wait,
                delayBeforeMilliseconds: delayValue,
                wait: WaitPayload(
                    milliseconds: try requiredUInt64(waitMilliseconds, field: "대기시간")
                )
            )
        case .capture:
            action = MacroAction(
                id: id,
                kind: .capture,
                delayBeforeMilliseconds: delayValue,
                capture: CapturePayload(
                    target: try captureTarget(),
                    destinationDirectory: destinationDirectory
                )
            )
        case .repeatBlock:
            guard let count = Int(repeatCount), count > 0 else {
                throw ActionDraftError.invalidField("반복 횟수")
            }
            action = MacroAction(
                id: id,
                kind: .repeatBlock,
                delayBeforeMilliseconds: delayValue,
                repeatBlock: RepeatPayload(count: count, actions: repeatActions)
            )
        }
        try action.validate()
        return action
    }

    private func startPoint() throws -> ScreenPoint {
        ScreenPoint(
            x: try requiredDouble(startX, field: "시작 X"),
            y: try requiredDouble(startY, field: "시작 Y")
        )
    }

    private func endPoint() throws -> ScreenPoint {
        ScreenPoint(
            x: try requiredDouble(endX, field: "끝 X"),
            y: try requiredDouble(endY, field: "끝 Y")
        )
    }

    private func captureTarget() throws -> CaptureTarget {
        switch captureTargetKind {
        case .display:
            guard let value = UInt32(captureTargetValue) else {
                throw ActionDraftError.invalidField("디스플레이")
            }
            return .display(value)
        case .application:
            guard !captureTargetValue.isEmpty else {
                throw ActionDraftError.invalidField("앱 번들 식별자")
            }
            return .application(captureTargetValue)
        case .window:
            guard let value = UInt32(captureTargetValue) else {
                throw ActionDraftError.invalidField("창")
            }
            return .window(value)
        }
    }

    private func requiredDouble(_ value: String, field: String) throws -> Double {
        guard let number = Double(value), number.isFinite else {
            throw ActionDraftError.invalidField(field)
        }
        return number
    }

    private func requiredUInt64(_ value: String, field: String) throws -> UInt64 {
        guard let number = UInt64(value) else {
            throw ActionDraftError.invalidField(field)
        }
        return number
    }

    private func optionalUInt64(_ value: String, field: String) throws -> UInt64? {
        guard !value.isEmpty else { return nil }
        return try requiredUInt64(value, field: field)
    }

    private static func string(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if abs(value) < 1_000_000_000_000_000, value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(value)
    }
}

struct ActionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ActionEditorDraft
    let onSave: (MacroAction) -> Void
    @State private var errorMessage: String?
    @StateObject private var captureSources = CaptureSourceCatalog()
    @State private var nestedActionEditor: NestedActionEditorSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("액션 편집")
                .font(.title2.bold())
            Form {
                Picker("종류", selection: $draft.kind) {
                    ForEach(MacroAction.Kind.allEditorCases, id: \.self) { kind in
                        Text(kind.editorName).tag(kind)
                    }
                }
                TextField("실행 전 대기(ms, 선택)", text: $draft.delay)
                fields
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("저장") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
        .task(id: draft.kind) {
            if draft.kind == .capture {
                await captureSources.loadIfNeeded()
            }
        }
        .sheet(item: $nestedActionEditor) { selection in
            ActionEditorSheet(draft: selection.draft) { action in
                guard draft.repeatActions.indices.contains(selection.index) else { return }
                draft.repeatActions[selection.index] = action
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            coordinateFields
        case .drag:
            coordinateFields
            TextField("끝 X", text: $draft.endX)
            TextField("끝 Y", text: $draft.endY)
            TextField("지속시간(ms)", text: $draft.duration)
            Picker("마우스 버튼", selection: $draft.dragButtonNumber) {
                Text("왼쪽").tag(Int64(0))
                Text("오른쪽").tag(Int64(1))
            }
        case .scroll:
            coordinateFields
            TextField("가로 스크롤", text: $draft.scrollX)
            TextField("세로 스크롤", text: $draft.scrollY)
        case .keyboard:
            TextField("키 코드", text: $draft.keyCode)
            TextField("문자", text: $draft.characters)
            TextField("보조 키 플래그", text: $draft.modifierFlags)
            Picker("키 동작", selection: $draft.keyboardEventKind) {
                Text("누르고 떼기").tag(KeyboardPayload.EventKind.press)
                Text("누르기").tag(KeyboardPayload.EventKind.keyDown)
                Text("떼기").tag(KeyboardPayload.EventKind.keyUp)
            }
            Toggle("자동 반복 이벤트", isOn: $draft.keyboardIsRepeat)
                .disabled(draft.keyboardEventKind != .keyDown)
        case .wait:
            TextField("대기시간(ms)", text: $draft.waitMilliseconds)
        case .capture:
            Picker("대상 종류", selection: $draft.captureTargetKind) {
                Text("디스플레이").tag(CaptureTarget.Kind.display)
                Text("앱").tag(CaptureTarget.Kind.application)
                Text("창").tag(CaptureTarget.Kind.window)
            }
            Picker("대상", selection: $draft.captureTargetValue) {
                Text("선택하십시오").tag("")
                ForEach(captureSources.options(for: draft.captureTargetKind)) { option in
                    Text(option.label).tag(option.value)
                }
            }
            if let sourceError = captureSources.errorMessage {
                Text(sourceError).foregroundStyle(.red)
            }
            HStack {
                TextField("저장 폴더", text: $draft.destinationDirectory)
                Button("선택") { chooseDirectory() }
            }
        case .repeatBlock:
            TextField("반복 횟수", text: $draft.repeatCount)
            LabeledContent("포함된 액션", value: "\(draft.repeatActions.count)개")
            ForEach(Array(draft.repeatActions.enumerated()), id: \.element.id) { index, action in
                HStack {
                    Text("\(index + 1). \(action.kind.editorName)")
                    Spacer()
                    Button("편집") {
                        nestedActionEditor = NestedActionEditorSelection(
                            index: index,
                            draft: ActionEditorDraft(action: action)
                        )
                    }
                    Button {
                        draft.repeatActions.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(index == 0)
                    Button {
                        draft.repeatActions.swapAt(index, index + 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(index == draft.repeatActions.count - 1)
                    Button(role: .destructive) {
                        draft.repeatActions.remove(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                }
                .buttonStyle(.borderless)
            }
            Menu("포함 액션 추가") {
                ForEach(
                    MacroAction.Kind.allEditorCases.filter {
                        $0 != .capture && $0 != .repeatBlock
                    },
                    id: \.self
                ) { kind in
                    Button(kind.editorName) {
                        do {
                            draft.repeatActions.append(
                                try ActionEditorDraft(kind: kind).makeAction()
                            )
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private var coordinateFields: some View {
        Group {
            TextField("X", text: $draft.startX)
            TextField("Y", text: $draft.startY)
        }
    }

    private func save() {
        do {
            onSave(try draft.makeAction())
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !draft.destinationDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.destinationDirectory)
        } else if let lastDirectoryURL = CaptureFolderHistory.lastDirectoryURL {
            panel.directoryURL = lastDirectoryURL
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.destinationDirectory = url.path
        CaptureFolderHistory.lastDirectoryURL = url
    }
}

private struct NestedActionEditorSelection: Identifiable {
    let id = UUID()
    let index: Int
    let draft: ActionEditorDraft
}

struct RepeatRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let actions: [MacroAction]
    let onSave: (Int, Int, Int) throws -> Void
    @State private var startIndex = 0
    @State private var endIndex = 0
    @State private var repeatCount = "2"
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("액션 범위 반복")
                .font(.title2.bold())
            Picker("시작 액션", selection: $startIndex) {
                ForEach(actions.indices, id: \.self) { index in
                    Text("\(index + 1). \(actions[index].kind.editorName)").tag(index)
                }
            }
            Picker("끝 액션", selection: $endIndex) {
                ForEach(actions.indices, id: \.self) { index in
                    Text("\(index + 1). \(actions[index].kind.editorName)").tag(index)
                }
            }
            TextField("반복 횟수", text: $repeatCount)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("적용") { save() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func save() {
        guard let count = Int(repeatCount) else {
            errorMessage = "반복 횟수를 확인하십시오."
            return
        }
        do {
            try onSave(startIndex, endIndex, count)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum ActionDraftError: LocalizedError {
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case let .invalidField(field): return "\(field) 값을 확인하십시오."
        }
    }
}

extension MacroAction.Kind {
    static let allEditorCases: [Self] = [
        .click, .doubleClick, .rightClick, .mouseMove, .drag, .scroll,
        .keyboard, .wait, .capture, .repeatBlock,
    ]

    var editorName: String {
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
}

private extension CaptureTarget {
    var editorValue: String {
        switch kind {
        case .display: return displayID.map(String.init) ?? ""
        case .application: return bundleIdentifier ?? ""
        case .window: return windowID.map(String.init) ?? ""
        }
    }
}
