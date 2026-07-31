import AppKit
import Foundation
import MacroKnotCore
import SwiftUI

struct ActionEditorDraft: Identifiable {
    var id = UUID()
    var isEditing = false
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
        isEditing = true
        kind = action.kind
        delay = action.delayBeforeMilliseconds.map(String.init) ?? ""
        if let mouse = action.mouse {
            startX = ScreenCoordinateTextFormatter.string(mouse.start.x)
            startY = ScreenCoordinateTextFormatter.string(mouse.start.y)
            endX = mouse.end.map { ScreenCoordinateTextFormatter.string($0.x) } ?? "100"
            endY = mouse.end.map { ScreenCoordinateTextFormatter.string($0.y) } ?? "100"
            duration = mouse.durationMilliseconds.map(String.init) ?? "300"
            dragButtonNumber = mouse.buttonNumber ?? 0
            dragPath = mouse.path
            scrollX = mouse.scrollDeltaX.map(ScreenCoordinateTextFormatter.string) ?? "0"
            scrollY = mouse.scrollDeltaY.map(ScreenCoordinateTextFormatter.string) ?? "-100"
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

    mutating func setStartPoint(_ point: ScreenPoint) {
        startX = ScreenCoordinateTextFormatter.pickedString(point.x)
        startY = ScreenCoordinateTextFormatter.pickedString(point.y)
    }

    mutating func setEndPoint(_ point: ScreenPoint) {
        endX = ScreenCoordinateTextFormatter.pickedString(point.x)
        endY = ScreenCoordinateTextFormatter.pickedString(point.y)
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
            guard !destinationDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionDraftError.invalidField("저장 폴더")
            }
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

}

struct ActionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ActionEditorDraft
    let onSave: (MacroAction) -> Void
    @State private var errorMessage: String?
    @StateObject private var captureSources = CaptureSourceCatalog()
    @StateObject private var coordinatePicker = ScreenCoordinatePicker()
    @State private var nestedActionEditor: NestedActionEditorSelection?

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            Form {
                Section {
                    Picker("액션 종류", selection: $draft.kind) {
                        ForEach(MacroAction.Kind.allEditorCases, id: \.self) { kind in
                            Label(kind.editorName, systemImage: kind.systemImage)
                                .tag(kind)
                        }
                    }

                    LabeledContent("실행 전 대기") {
                        HStack(spacing: 7) {
                            compactTextField(
                                "실행 전 대기",
                                prompt: "없음",
                                text: $draft.delay,
                                width: 110
                            )
                            Text("ms")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("기본 설정")
                } footer: {
                    Text("실행 전 대기는 이전 액션이 끝난 뒤 이 액션을 시작하기까지의 간격입니다. 비워 두면 바로 실행합니다.")
                }

                fields
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            errorCallout
            Divider()
            editorFooter
        }
        .frame(width: 660)
        .frame(minHeight: 540)
        .task(id: draft.kind) {
            if draft.kind == .capture {
                await captureSources.loadIfNeeded()
            }
        }
        .onChange(of: draft.kind) { _, _ in
            errorMessage = nil
        }
        .onChange(of: draft.captureTargetKind) { _, _ in
            draft.captureTargetValue = ""
        }
        .sheet(item: $nestedActionEditor) { selection in
            ActionEditorSheet(draft: selection.draft) { action in
                guard draft.repeatActions.indices.contains(selection.index) else { return }
                draft.repeatActions[selection.index] = action
            }
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(draft.kind.tint.opacity(0.13))
                Image(systemName: draft.kind.systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(draft.kind.tint)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(draft.isEditing ? "액션 편집" : "새 액션 추가")
                    .font(.title2.weight(.semibold))
                Text(draft.kind.editorDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var errorCallout: some View {
        if let errorMessage {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.red.opacity(0.09))
            .accessibilityLabel("입력 오류: \(errorMessage)")
        }
    }

    private var editorFooter: some View {
        HStack {
            Text("필수 값을 확인한 뒤 저장해 주세요.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("취소") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(draft.isEditing ? "변경사항 저장" : "액션 추가") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            Section {
                coordinateRow(
                    "화면 좌표",
                    x: $draft.startX,
                    y: $draft.startY,
                    onPick: { draft.setStartPoint($0) }
                )
            } header: {
                Text("위치")
            } footer: {
                Text("화면에서 선택을 누른 뒤 원하는 위치를 클릭하세요. 숫자를 직접 수정할 수도 있습니다.")
            }
        case .drag:
            Section {
                coordinateRow(
                    "시작 위치",
                    x: $draft.startX,
                    y: $draft.startY,
                    onPick: { draft.setStartPoint($0) }
                )
                coordinateRow(
                    "끝 위치",
                    x: $draft.endX,
                    y: $draft.endY,
                    onPick: { draft.setEndPoint($0) }
                )
                LabeledContent("지속시간") {
                    HStack(spacing: 7) {
                        compactTextField(
                            "지속시간",
                            prompt: "300",
                            text: $draft.duration,
                            width: 110
                        )
                        Text("ms")
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("마우스 버튼", selection: $draft.dragButtonNumber) {
                    Text("왼쪽 버튼").tag(Int64(0))
                    Text("오른쪽 버튼").tag(Int64(1))
                }
            } header: {
                Text("드래그 경로")
            } footer: {
                Text("시작 위치와 끝 위치를 화면에서 각각 선택할 수 있습니다.")
            }
        case .scroll:
            Section {
                coordinateRow(
                    "시작 위치",
                    x: $draft.startX,
                    y: $draft.startY,
                    onPick: { draft.setStartPoint($0) }
                )
                pairedNumberRow(
                    "스크롤 양",
                    firstLabel: "가로",
                    first: $draft.scrollX,
                    secondLabel: "세로",
                    second: $draft.scrollY
                )
            } header: {
                Text("스크롤")
            } footer: {
                Text("양수와 음수로 스크롤 방향을 바꿀 수 있습니다.")
            }
        case .keyboard:
            Section {
                TextField("표시 문자", text: $draft.characters)
                LabeledContent("키 코드") {
                    compactTextField("키 코드", prompt: "0", text: $draft.keyCode, width: 150)
                }
                LabeledContent("보조 키 플래그") {
                    compactTextField(
                        "보조 키 플래그",
                        prompt: "0",
                        text: $draft.modifierFlags,
                        width: 150
                    )
                }
                Picker("키 동작", selection: $draft.keyboardEventKind) {
                    Text("누르고 떼기").tag(KeyboardPayload.EventKind.press)
                    Text("누르기").tag(KeyboardPayload.EventKind.keyDown)
                    Text("떼기").tag(KeyboardPayload.EventKind.keyUp)
                }
                Toggle("키를 누르고 있을 때 발생한 자동 반복 이벤트", isOn: $draft.keyboardIsRepeat)
                    .disabled(draft.keyboardEventKind != .keyDown)
            } header: {
                Text("키보드 입력")
            } footer: {
                Text("녹화된 키 코드와 보조 키 값을 그대로 유지하는 것이 가장 안전합니다.")
            }
        case .wait:
            Section {
                LabeledContent("대기시간") {
                    HStack(spacing: 7) {
                        compactTextField(
                            "대기시간",
                            prompt: "1000",
                            text: $draft.waitMilliseconds,
                            width: 130
                        )
                        Text("ms")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("대기")
            } footer: {
                Text("이 시간 동안 아무 입력도 실행하지 않고 다음 액션을 기다립니다.")
            }
        case .capture:
            Section {
                Picker("캡처 범위", selection: $draft.captureTargetKind) {
                    Text("디스플레이").tag(CaptureTarget.Kind.display)
                    Text("앱").tag(CaptureTarget.Kind.application)
                    Text("창").tag(CaptureTarget.Kind.window)
                }
                Picker("캡처 대상", selection: $draft.captureTargetValue) {
                    Text("대상을 선택하세요").tag("")
                    ForEach(captureSources.options(for: draft.captureTargetKind)) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                LabeledContent("저장 폴더") {
                    HStack(spacing: 8) {
                        compactTextField(
                            "저장 폴더 경로",
                            prompt: "폴더를 선택하세요",
                            text: $draft.destinationDirectory
                        )
                        Button("선택…", action: chooseDirectory)
                    }
                }
                if let sourceError = captureSources.errorMessage {
                    Label(sourceError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("화면 캡처")
            } footer: {
                Text("재생 중에는 선택창을 띄우지 않고 지금 정한 대상과 폴더를 사용합니다.")
            }
        case .repeatBlock:
            Section {
                LabeledContent("반복 횟수") {
                    HStack(spacing: 7) {
                        compactTextField(
                            "반복 횟수",
                            prompt: "2",
                            text: $draft.repeatCount,
                            width: 100
                        )
                        Text("회")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("포함된 액션", value: "\(draft.repeatActions.count)개")

                ForEach(Array(draft.repeatActions.enumerated()), id: \.element.id) { index, action in
                    HStack(spacing: 10) {
                        Image(systemName: action.kind.systemImage)
                            .foregroundStyle(action.kind.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(action.kind.editorName)")
                                .fontWeight(.medium)
                            Text(action.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
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
                            Label("위로 이동", systemImage: "chevron.up")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(index == 0)
                        Button {
                            draft.repeatActions.swapAt(index, index + 1)
                        } label: {
                            Label("아래로 이동", systemImage: "chevron.down")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(index == draft.repeatActions.count - 1)
                        Button(role: .destructive) {
                            draft.repeatActions.remove(at: index)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(draft.repeatActions.count == 1)
                    }
                    .buttonStyle(.borderless)
                }

                Menu("포함 액션 추가", systemImage: "plus") {
                    ForEach(
                        MacroAction.Kind.allEditorCases.filter {
                            $0 != .capture && $0 != .repeatBlock
                        },
                        id: \.self
                    ) { kind in
                        Button(kind.editorName, systemImage: kind.systemImage) {
                            addNestedAction(kind)
                        }
                    }
                }
            } header: {
                Text("반복")
            } footer: {
                Text("위에서 아래 순서로 포함된 액션을 실행하고, 지정한 횟수만큼 다시 반복합니다.")
            }
        }
    }

    private func coordinateRow(
        _ title: String,
        x: Binding<String>,
        y: Binding<String>,
        onPick: @escaping (ScreenPoint) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("X")
                    .foregroundStyle(.secondary)
                compactTextField("\(title) X 좌표", prompt: "0", text: x, width: 78)
                Text("Y")
                    .foregroundStyle(.secondary)
                compactTextField("\(title) Y 좌표", prompt: "0", text: y, width: 78)
                Button {
                    beginCoordinateSelection(onPick: onPick)
                } label: {
                    Label(
                        coordinatePicker.isSelecting ? "선택 중…" : "화면에서 선택",
                        systemImage: "scope"
                    )
                }
                .disabled(coordinatePicker.isSelecting)
                .help("전체 화면에서 원하는 위치를 클릭해 좌표 입력")
            }
        }
    }

    private func beginCoordinateSelection(onPick: @escaping (ScreenPoint) -> Void) {
        coordinatePicker.begin { outcome in
            switch outcome {
            case .selected(let point):
                onPick(point)
                errorMessage = nil
            case .cancelled:
                break
            case .failed(let message):
                errorMessage = message
            }
        }
    }

    private func pairedNumberRow(
        _ title: String,
        firstLabel: String,
        first: Binding<String>,
        secondLabel: String,
        second: Binding<String>
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(firstLabel)
                    .foregroundStyle(.secondary)
                compactTextField("\(title) \(firstLabel)", prompt: "0", text: first, width: 100)
                Text(secondLabel)
                    .foregroundStyle(.secondary)
                compactTextField("\(title) \(secondLabel)", prompt: "0", text: second, width: 100)
            }
        }
    }

    private func compactTextField(
        _ accessibilityLabel: String,
        prompt: String,
        text: Binding<String>,
        width: CGFloat? = nil
    ) -> some View {
        TextField(accessibilityLabel, text: text, prompt: Text(prompt))
            .labelsHidden()
            .frame(width: width)
            .accessibilityLabel(accessibilityLabel)
    }

    private func addNestedAction(_ kind: MacroAction.Kind) {
        do {
            draft.repeatActions.append(try ActionEditorDraft(kind: kind).makeAction())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
    @State private var repeatCount = 2
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.pink.opacity(0.12))
                    Image(systemName: "repeat")
                        .font(.title2)
                        .foregroundStyle(.pink)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("액션 범위를 반복으로 묶기")
                        .font(.title2.weight(.semibold))
                    Text("연속된 액션을 하나의 반복 블록으로 바꿉니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("반복할 범위") {
                    Picker("시작 액션", selection: $startIndex) {
                        ForEach(actions.indices, id: \.self) { index in
                            actionPickerLabel(index).tag(index)
                        }
                    }
                    Picker("끝 액션", selection: $endIndex) {
                        ForEach(validEndIndices, id: \.self) { index in
                            actionPickerLabel(index).tag(index)
                        }
                    }
                    LabeledContent("선택", value: "\(selectedActionCount)개 액션")
                }

                Section("반복 횟수") {
                    Stepper(value: $repeatCount, in: 1...9_999) {
                        LabeledContent("실행", value: "\(repeatCount)회")
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(.red.opacity(0.09))
            }

            Divider()

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("반복으로 묶기") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 500)
        .onChange(of: startIndex) { _, newStart in
            if endIndex < newStart {
                endIndex = newStart
            }
        }
    }

    private var validEndIndices: [Int] {
        guard actions.indices.contains(startIndex) else { return [] }
        return Array(startIndex..<actions.endIndex)
    }

    private var selectedActionCount: Int {
        guard endIndex >= startIndex else { return 0 }
        return endIndex - startIndex + 1
    }

    private func actionPickerLabel(_ index: Int) -> some View {
        Text("\(index + 1). \(actions[index].kind.editorName) · \(actions[index].summary)")
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func save() {
        guard actions.indices.contains(startIndex), actions.indices.contains(endIndex) else {
            errorMessage = "반복할 액션 범위를 확인해 주세요."
            return
        }
        do {
            try onSave(startIndex, endIndex, repeatCount)
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
        displayName
    }

    var editorDescription: String {
        switch self {
        case .click: return "지정한 화면 좌표를 한 번 클릭합니다."
        case .doubleClick: return "지정한 화면 좌표를 빠르게 두 번 클릭합니다."
        case .rightClick: return "지정한 화면 좌표에서 보조 클릭을 실행합니다."
        case .mouseMove: return "포인터를 지정한 화면 좌표로 이동합니다."
        case .drag: return "시작 위치에서 끝 위치까지 포인터를 끌어 이동합니다."
        case .scroll: return "지정한 화면 좌표에서 가로·세로로 스크롤합니다."
        case .keyboard: return "키 누르기·떼기와 보조 키 조합을 실행합니다."
        case .wait: return "다음 액션을 실행하기 전에 지정한 시간만큼 기다립니다."
        case .capture: return "선택한 디스플레이·앱·창을 PNG로 저장합니다."
        case .repeatBlock: return "여러 액션을 묶어 지정한 횟수만큼 반복합니다."
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
