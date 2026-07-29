import MacroKnotCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var permissions: PermissionState
    @StateObject private var documentController = DocumentController()
    @StateObject private var recorder = InputRecorder()
    @StateObject private var player = InputPlayer()
    @State private var recordingMode = InputRecordingMode.meaningfulActionsOnly

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
            }
            .navigationTitle("MacroKnot")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    permissionsSection
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("첫 매크로")
                .font(.largeTitle.bold())
            Text("녹화부터 재생·중지까지 이어지는 최소 버전을 구현하고 있습니다.")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        GroupBox("권한") {
            VStack(spacing: 12) {
                permissionRow(
                    "손쉬운 사용",
                    granted: permissions.accessibilityGranted,
                    action: permissions.openAccessibilitySettings
                )
                permissionRow(
                    "화면 캡처",
                    granted: permissions.screenCaptureGranted,
                    action: permissions.openScreenCaptureSettings
                )
                HStack {
                    Button("권한 상태 새로고침", action: permissions.refresh)
                    Spacer()
                }
            }
            .padding(.top, 8)
        }
    }

    private var documentSection: some View {
        GroupBox("매크로 문서") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("매크로 이름", text: $documentController.document.name)
                    .textFieldStyle(.roundedBorder)
                LabeledContent("형식 버전", value: "\(documentController.document.formatVersion)")
                LabeledContent("제어 범위", value: "전체 화면")
                LabeledContent("액션", value: "\(documentController.document.actions.count)개")
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
                Picker("마우스 녹화", selection: $recordingMode) {
                    Text("클릭·스크롤·드래그만").tag(InputRecordingMode.meaningfulActionsOnly)
                    Text("모든 마우스 이동").tag(InputRecordingMode.allMouseMovement)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(recorder.isRecording ? "녹화 중지" : "녹화 시작") {
                        toggleRecording()
                    }
                    .buttonStyle(.borderedProminent)
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
            }
            .padding(.top, 8)
        }
    }

    private var actionListSection: some View {
        GroupBox("액션 목록") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("대기 추가") {
                        documentController.addWaitAction()
                    }
                    Spacer()
                }

                if documentController.document.actions.isEmpty {
                    ContentUnavailableView(
                        "액션이 없습니다",
                        systemImage: "list.bullet.rectangle",
                        description: Text("입력을 녹화하거나 대기 액션을 추가하십시오.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List {
                        ForEach(Array(documentController.document.actions.enumerated()), id: \.element.id) { index, action in
                            HStack {
                                Text("\(index + 1)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                                Image(systemName: action.kind.systemImage)
                                Text(action.kind.displayName)
                                Spacer()
                                Text(action.summary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Button {
                                    documentController.moveAction(id: action.id, offset: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                Button {
                                    documentController.moveAction(id: action.id, offset: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == documentController.document.actions.count - 1)
                                Button(role: .destructive) {
                                    documentController.removeAction(id: action.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
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
                    guard permissions.accessibilityGranted else {
                        permissions.openAccessibilitySettings()
                        return
                    }
                    player.play(actions: documentController.document.actions)
                }
                .buttonStyle(.borderedProminent)
                .disabled(player.state == .running || documentController.document.actions.isEmpty)

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

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            documentController.appendRecordedActions(recorder.actions)
            return
        }
        guard permissions.accessibilityGranted else {
            permissions.openAccessibilitySettings()
            return
        }
        recorder.start(mode: recordingMode)
    }

    private func permissionRow(
        _ title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            Text(granted ? "허용됨" : "설정 필요")
                .foregroundStyle(.secondary)
            Button("설정 열기", action: action)
                .disabled(granted)
        }
    }
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
        switch kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            guard let point = mouse?.start else { return "" }
            return "(\(Int(point.x)), \(Int(point.y)))"
        case .drag:
            guard let start = mouse?.start, let end = mouse?.end else { return "" }
            return "(\(Int(start.x)), \(Int(start.y))) → (\(Int(end.x)), \(Int(end.y)))"
        case .scroll:
            return "x \(Int(mouse?.scrollDeltaX ?? 0)), y \(Int(mouse?.scrollDeltaY ?? 0))"
        case .keyboard:
            return keyboard?.characters ?? "키 코드 \(keyboard?.keyCode ?? 0)"
        case .wait:
            return "\(wait?.milliseconds ?? 0)ms"
        case .capture:
            return capture?.destinationDirectory ?? ""
        case .repeatBlock:
            return "\(repeatBlock?.count ?? 0)회"
        }
    }
}
