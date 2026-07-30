import Foundation
import MacroKnotCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var permissions: PermissionState
    @StateObject private var documentController = DocumentController()
    @StateObject private var recorder = InputRecorder()
    @StateObject private var player = InputPlayer()
    @StateObject private var globalCommandMonitor = GlobalCommandMonitor()
    @State private var actionEditorDraft: ActionEditorDraft?
    @State private var isRepeatRangePresented = false
    @State private var isDeleteAllConfirmationPresented = false
    @AppStorage(AppPreferenceKeys.excludesEventsTargetingMacroKnot)
    private var excludesEventsTargetingMacroKnot = true
    @AppStorage(AppPreferenceKeys.recordingMode)
    private var recordingModeRawValue = AppPreferenceDefaults.recordingMode.rawValue

    var body: some View {
        NavigationSplitView {
            List {
                Button(action: documentController.newDocument) {
                    Label("새 매크로", systemImage: "plus.square")
                }
                Button(action: documentController.openDocument) {
                    Label("열기", systemImage: "folder")
                }
                Divider()
                Button(action: documentController.saveDocument) {
                    Label("저장", systemImage: "square.and.arrow.down")
                }
                Button(action: documentController.saveDocumentAs) {
                    Label("다른 이름으로 저장", systemImage: "doc.badge.plus")
                }
                Divider()
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
            }
            .navigationTitle("MacroKnot")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    documentSection
                    recordingSection
                    playbackSection
                    actionListSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
            .navigationTitle(documentController.windowTitle)
        }
        .sheet(item: $actionEditorDraft) { draft in
            ActionEditorSheet(draft: draft) { action in
                if documentController.document.actions.contains(where: { $0.id == action.id }) {
                    documentController.updateAction(action)
                } else {
                    documentController.addAction(action)
                }
            }
        }
        .sheet(isPresented: $isRepeatRangePresented) {
            RepeatRangeSheet(actions: documentController.document.actions) { start, end, count in
                try documentController.wrapActionsInRepeat(
                    from: start,
                    through: end,
                    count: count
                )
            }
        }
        .alert("모든 액션을 삭제할까요?", isPresented: $isDeleteAllConfirmationPresented) {
            Button("전체 삭제", role: .destructive) {
                documentController.removeAllActions()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 문서의 액션이 모두 삭제됩니다.")
        }
        .onAppear(perform: startGlobalCommandMonitor)
        .onDisappear(perform: globalCommandMonitor.stop)
        .onChange(of: permissions.accessibilityGranted) { _, granted in
            if granted {
                startGlobalCommandMonitor()
            }
        }
        .background {
            #if DEBUG
            UISnapshotCaptureView()
            #else
            EmptyView()
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("첫 매크로")
                .font(.largeTitle.bold())
            Text("녹화부터 재생·중지까지 이어지는 최소 버전을 구현하고 있습니다.")
                .foregroundStyle(.secondary)
        }
    }

    private var documentSection: some View {
        GroupBox("매크로 문서") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("매크로 이름", text: $documentController.document.name)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("형식 버전", value: "\(documentController.document.formatVersion)")
                LabeledContent("제어 범위", value: "전체 화면")
                LabeledContent("액션", value: actionCountText)
                LabeledContent(
                    "예상 재생 시간",
                    value: Self.durationText(
                        documentController.document.actions.estimatedDurationMilliseconds
                    )
                )
                if let errorMessage = documentController.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 8)
        }
    }

    private var recordingSection: some View {
        GroupBox("입력 녹화") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("마우스 녹화", selection: recordingModeBinding) {
                    Text("클릭·스크롤·드래그만").tag(InputRecordingMode.meaningfulActionsOnly)
                    Text("모든 마우스 이동").tag(InputRecordingMode.allMouseMovement)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(recorder.isRecording ? "녹화 중지" : "녹화 시작") {
                        toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!recorder.isRecording && player.state == .running)
                    Text(recorder.isRecording ? "녹화 중" : "중지됨")
                        .foregroundStyle(recorder.isRecording ? .green : .secondary)
                    Spacer()
                    Text("이번 녹화 \(recorder.actions.count)개")
                        .foregroundStyle(.secondary)
                }

                Text(recorder.lastEvent)
                    .font(.system(.body, design: .monospaced))
                if let errorMessage = recorder.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                if let errorMessage = globalCommandMonitor.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 8)
        }
    }

    private var actionListSection: some View {
        GroupBox("액션 목록") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Menu("액션 추가") {
                        ForEach(MacroAction.Kind.allEditorCases.filter { $0 != .repeatBlock }, id: \.self) { kind in
                            Button(kind.editorName) {
                                actionEditorDraft = ActionEditorDraft(kind: kind)
                            }
                        }
                    }
                    .disabled(recorder.isRecording)
                    Button("범위 반복") {
                        isRepeatRangePresented = true
                    }
                    .disabled(recorder.isRecording || documentController.document.actions.isEmpty)
                    Spacer()
                    Button("전체 삭제", role: .destructive) {
                        isDeleteAllConfirmationPresented = true
                    }
                    .disabled(recorder.isRecording || documentController.document.actions.isEmpty)
                }

                if recorder.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text("녹화 중 · 이번 녹화 \(recorder.actions.count)개")
                            .foregroundStyle(.secondary)
                        if recorder.actions.count > Self.liveActionLimit {
                            Text("최근 \(Self.liveActionLimit)개 표시")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                if displayedActions.isEmpty {
                    ContentUnavailableView(
                        "액션이 없습니다",
                        systemImage: "list.bullet.rectangle",
                        description: Text("입력을 녹화하거나 대기 액션을 추가하십시오.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List {
                        ForEach(Array(displayedActions.enumerated()), id: \.element.action.id) { index, item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(index + 1)")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, alignment: .trailing)
                                    Image(systemName: item.action.kind.systemImage)
                                    Text(item.action.kind.displayName)
                                    if item.isLive {
                                        Text("녹화 중")
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                    Spacer()
                                    Text(item.action.summary)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Button("편집") {
                                        actionEditorDraft = ActionEditorDraft(action: item.action)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(item.isLive || recorder.isRecording)
                                    Button {
                                        documentController.moveAction(id: item.action.id, offset: -1)
                                    } label: {
                                        Image(systemName: "chevron.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(item.isLive || recorder.isRecording || index == 0)
                                    Button {
                                        documentController.moveAction(id: item.action.id, offset: 1)
                                    } label: {
                                        Image(systemName: "chevron.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(
                                        item.isLive
                                            || recorder.isRecording
                                            || index == documentController.document.actions.count - 1
                                    )
                                    Button(role: .destructive) {
                                        documentController.removeAction(id: item.action.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(item.isLive || recorder.isRecording)
                                }
                                if !item.isLive,
                                   let error = documentController.validationMessage(for: item.action) {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .padding(.leading, 40)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 180)
                }
            }
            .padding(.top, 8)
        }
    }

    private var playbackSection: some View {
        GroupBox("재생과 중지") {
            HStack {
                Button(player.state == .running ? "실행 중" : "재생") {
                    startPlayback()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    recorder.isRecording
                        || player.state == .running
                        || documentController.document.actions.isEmpty
                )

                Button("중지", role: .destructive, action: player.stop)
                    .disabled(player.state != .running)
                Spacer()
                Text(player.state.displayName)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            Text("강제 중지: Control + Escape")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleRecording(triggeredByGlobalShortcut: Bool = false) {
        if recorder.isRecording {
            recorder.stop(discardingTrailingShortcutModifiers: triggeredByGlobalShortcut)
            documentController.appendRecordedActions(recorder.actions)
            return
        }
        guard player.state != .running else { return }
        guard permissions.accessibilityGranted else {
            permissions.openAccessibilitySettings()
            return
        }
        recorder.start(
            mode: recordingMode,
            excludesEventsTargetingMacroKnot: excludesEventsTargetingMacroKnot,
            suppressesInitialShortcutModifierReleases: triggeredByGlobalShortcut
        )
    }

    private static func durationText(_ milliseconds: UInt64) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f초", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds)ms"
    }

    private static let liveActionLimit = 200

    private var actionCountText: String {
        guard recorder.isRecording else {
            return "\(documentController.document.actions.count)개"
        }
        return "\(documentController.document.actions.count)개 + 녹화 중 \(recorder.actions.count)개"
    }

    private var displayedActions: [DisplayedAction] {
        let saved = documentController.document.actions.map {
            DisplayedAction(action: $0, isLive: false)
        }
        guard recorder.isRecording else { return saved }
        let live = recorder.actions.suffix(Self.liveActionLimit).map {
            DisplayedAction(action: $0, isLive: true)
        }
        return saved + live
    }

    private var recordingMode: InputRecordingMode {
        InputRecordingMode(rawValue: recordingModeRawValue)
            ?? AppPreferenceDefaults.recordingMode
    }

    private var recordingModeBinding: Binding<InputRecordingMode> {
        Binding(
            get: { recordingMode },
            set: { recordingModeRawValue = $0.rawValue }
        )
    }

    private func startPlayback() {
        guard !recorder.isRecording,
              player.state != .running,
              !documentController.document.actions.isEmpty
        else { return }
        guard permissions.accessibilityGranted else {
            permissions.openAccessibilitySettings()
            return
        }
        player.play(document: documentController.document)
    }

    private func startGlobalCommandMonitor() {
        guard permissions.accessibilityGranted else { return }
        globalCommandMonitor.onCommand = { command in
            switch command {
            case .toggleRecording:
                guard recorder.isRecording || player.state != .running else { return false }
                toggleRecording(triggeredByGlobalShortcut: true)
                return true
            case .play:
                guard !recorder.isRecording,
                      player.state != .running,
                      !documentController.document.actions.isEmpty
                else { return false }
                startPlayback()
                return true
            }
        }
        globalCommandMonitor.start()
    }
}

private struct DisplayedAction {
    let action: MacroAction
    let isLive: Bool
}

private extension InputPlayer.State {
    var displayName: String {
        switch self {
        case .idle: return "대기"
        case .running: return "실행 중"
        case .completed: return "완료"
        case .stopped: return "중지됨"
        case let .failed(message): return "실패: \(message)"
        }
    }
}

private extension MacroAction.Kind {
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
        case .mouseMove, .drag: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scroll: return "scroll"
        case .keyboard: return "keyboard"
        case .wait: return "clock"
        case .capture: return "camera"
        case .repeatBlock: return "repeat"
        }
    }
}

private extension MacroAction {
    var summary: String {
        let detail: String
        switch kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            guard let point = mouse?.start else { return "" }
            detail = "(\(Self.number(point.x)), \(Self.number(point.y)))"
        case .drag:
            guard let start = mouse?.start, let end = mouse?.end else { return "" }
            detail = "(\(Self.number(start.x)), \(Self.number(start.y))) → (\(Self.number(end.x)), \(Self.number(end.y)))"
        case .scroll:
            detail = "x \(Self.number(mouse?.scrollDeltaX ?? 0)), y \(Self.number(mouse?.scrollDeltaY ?? 0))"
        case .keyboard:
            detail = keyboard?.characters ?? "키 코드 \(keyboard?.keyCode ?? 0)"
        case .wait:
            detail = "\(wait?.milliseconds ?? 0)ms"
        case .capture:
            detail = capture?.destinationDirectory ?? ""
        case .repeatBlock:
            detail = "\(repeatBlock?.count ?? 0)회"
        }
        guard let delayBeforeMilliseconds, delayBeforeMilliseconds > 0 else {
            return detail
        }
        return "전 \(Self.duration(delayBeforeMilliseconds)) 대기 · \(detail)"
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

    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "invalid" }
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.3g", value)
        }
        return String(format: "%.0f", value)
    }

    private static func duration(_ milliseconds: UInt64) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2f초", Double(milliseconds) / 1_000)
        }
        return "\(milliseconds)ms"
    }
}

private extension Array where Element == MacroAction {
    var estimatedDurationMilliseconds: UInt64 {
        reduce(0) { total, action in
            let result = total.addingReportingOverflow(action.estimatedDurationMilliseconds)
            return result.overflow ? .max : result.partialValue
        }
    }
}
