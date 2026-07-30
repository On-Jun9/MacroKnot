import AppKit
import Foundation
import MacroKnotCore
import SwiftUI

enum WorkspacePreviewState {
    case live
    case recording(actions: [MacroAction], lastEvent: String)
    case playing
    case failed(String)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var permissions: PermissionState
    @StateObject private var documentController: DocumentController
    @StateObject private var recorder = InputRecorder()
    @StateObject private var player = InputPlayer()
    @StateObject private var globalCommandMonitor = GlobalCommandMonitor()
    @State private var actionEditorDraft: ActionEditorDraft?
    @State private var selectedActionID: UUID?
    @State private var isRepeatRangePresented = false
    @State private var isDeleteAllConfirmationPresented = false
    @State private var isSidebarPresented = true
    @AppStorage(AppPreferenceKeys.excludesEventsTargetingMacroKnot)
    private var excludesEventsTargetingMacroKnot = true
    @AppStorage(AppPreferenceKeys.recordingMode)
    private var recordingModeRawValue = AppPreferenceDefaults.recordingMode.rawValue
    @AppStorage(AppPreferenceKeys.recordingShortcut)
    private var recordingShortcutRawValue = AppPreferenceDefaults.recordingShortcut.rawValue
    @AppStorage(AppPreferenceKeys.playbackShortcut)
    private var playbackShortcutRawValue = AppPreferenceDefaults.playbackShortcut.rawValue

    private let previewState: WorkspacePreviewState

    init(
        permissions: PermissionState,
        initialDocument: MacroDocument? = nil,
        previewState: WorkspacePreviewState = .live
    ) {
        self.permissions = permissions
        self.previewState = previewState
        _documentController = StateObject(
            wrappedValue: DocumentController(initialDocument: initialDocument)
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Divider()
                feedbackBanner
                HSplitView {
                    if isSidebarPresented {
                        controlSidebar
                            .frame(minWidth: 270, idealWidth: 300, maxWidth: 340)
                    }
                    workspace
                        .frame(minWidth: 560)
                }
            }
            .navigationTitle(documentController.windowTitle)
            .toolbar { workspaceToolbar }
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .frame(minWidth: 900, minHeight: 620)
        .sheet(item: $actionEditorDraft) { draft in
            ActionEditorSheet(draft: draft) { action in
                if documentController.document.actions.contains(where: { $0.id == action.id }) {
                    documentController.updateAction(action)
                } else {
                    documentController.addAction(action)
                }
                selectedActionID = action.id
            }
        }
        .sheet(isPresented: $isRepeatRangePresented) {
            RepeatRangeSheet(actions: documentController.document.actions) { start, end, count in
                try documentController.wrapActionsInRepeat(
                    from: start,
                    through: end,
                    count: count
                )
                selectedActionID = documentController.document.actions[safe: start]?.id
            }
        }
        .alert("모든 액션을 삭제할까요?", isPresented: $isDeleteAllConfirmationPresented) {
            Button("전체 삭제", role: .destructive) {
                documentController.removeAllActions()
                selectedActionID = nil
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 문서의 액션이 모두 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .onAppear(perform: handleAppearance)
        .onDisappear(perform: globalCommandMonitor.stop)
        .onChange(of: permissions.accessibilityGranted) { _, granted in
            if granted {
                startGlobalCommandMonitor()
            } else {
                globalCommandMonitor.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                permissions.refresh()
            }
        }
        .onChange(of: documentController.document.actions.map(\.id)) { _, actionIDs in
            guard let selectedActionID, !actionIDs.contains(selectedActionID) else { return }
            self.selectedActionID = nil
        }
        .focusedSceneValue(
            \.documentFileCommands,
            DocumentFileCommands(
                newDocument: newDocument,
                openDocument: openDocument,
                saveDocument: documentController.saveDocument,
                saveDocumentAs: documentController.saveDocumentAs
            )
        )
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isSidebarPresented.toggle()
                }
            } label: {
                Label(
                    isSidebarPresented ? "사이드바 가리기" : "사이드바 보기",
                    systemImage: "sidebar.leading"
                )
            }
            .help(isSidebarPresented ? "사이드바 가리기" : "사이드바 보기")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { toggleRecording() }) {
                Label(
                    isRecordingPresented ? "녹화 중지" : "녹화 시작",
                    systemImage: isRecordingPresented ? "stop.fill" : "record.circle"
                )
            }
            .tint(.red)
            .disabled(!isRecordingPresented && displayedPlayerState == .running)
            .help(isRecordingPresented ? "현재 녹화를 마칩니다" : "사용자 입력 녹화를 시작합니다")

            Button(action: startPlayback) {
                Label(
                    displayedPlayerState == .running ? "실행 중" : "재생",
                    systemImage: "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartPlayback)
            .help("현재 액션을 처음부터 재생합니다")

            if displayedPlayerState == .running {
                Button(role: .destructive, action: player.stop) {
                    Label("중지", systemImage: "stop.fill")
                }
                .keyboardShortcut(.escape, modifiers: .control)
                .help("재생 중지 (⌃Esc)")
            }

            SettingsLink {
                Label("설정", systemImage: "gearshape")
            }
            .help("MacroKnot 설정")
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            activityBanner
            actionWorkspace
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("매크로 이름", text: $documentController.document.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .accessibilityLabel("매크로 이름")

                HStack(spacing: 8) {
                    Label(documentLocationText, systemImage: "doc.text")
                    Text("·")
                        .accessibilityHidden(true)
                    Text("전체 화면 제어")
                    Text("·")
                        .accessibilityHidden(true)
                    Text("예상 \(estimatedDurationText)")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            StatusBadge(presentation: statusPresentation)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let activeErrorMessage {
            FeedbackBanner(
                title: "작업을 완료하지 못했습니다",
                message: activeErrorMessage,
                systemImage: "xmark.octagon.fill",
                tint: .red
            )
        } else if !permissions.accessibilityGranted,
            !isRecordingPresented,
            displayedPlayerState != .running
        {
            FeedbackBanner(
                title: "입력 녹화와 재생을 사용하려면 권한이 필요합니다",
                message: "시스템 설정에서 MacroKnot의 손쉬운 사용 권한을 켜 주세요.",
                systemImage: "hand.raised.fill",
                tint: .orange,
                actionTitle: "권한 설정",
                action: permissions.openAccessibilitySettings
            )
        } else if requiresScreenCapturePermission,
            displayedPlayerState != .running
        {
            FeedbackBanner(
                title: "캡처 액션을 실행하려면 권한이 필요합니다",
                message: "시스템 설정에서 MacroKnot의 화면 및 시스템 오디오 녹음 권한을 켜 주세요.",
                systemImage: "camera.fill",
                tint: .orange,
                actionTitle: "권한 설정",
                action: permissions.openScreenCaptureSettings
            )
        }
    }

    @ViewBuilder
    private var activityBanner: some View {
        if isRecordingPresented {
            ActivityBanner(
                title: "입력을 녹화하고 있습니다",
                detail: "\(recordedActionsPresented.count)개 기록됨 · \(recordingLastEventPresented)",
                systemImage: "record.circle.fill",
                tint: .red,
                actionTitle: "녹화 중지",
                action: { toggleRecording() }
            )
        } else if displayedPlayerState == .running {
            ActivityBanner(
                title: "매크로를 실행하고 있습니다",
                detail: "어느 앱에서든 Control + Escape를 누르면 즉시 중지됩니다.",
                systemImage: "play.circle.fill",
                tint: .indigo,
                showsProgress: true,
                actionTitle: "중지",
                action: player.stop
            )
        }
    }

    private var actionWorkspace: some View {
        VStack(spacing: 0) {
            actionToolbar
            Divider()
            if displayedActions.isEmpty {
                emptyActionView
            } else {
                actionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionToolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("액션")
                        .font(.headline)
                    Text("\(actionCountText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(selectionDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            addActionMenu
                .disabled(isRecordingPresented)

            Button("편집", systemImage: "slider.horizontal.3") {
                editSelectedAction()
            }
            .disabled(selectedAction == nil || isRecordingPresented)
            .help("선택한 액션 편집")

            Button {
                moveSelectedAction(offset: -1)
            } label: {
                Label("위로 이동", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(!canMoveSelectedAction(offset: -1) || isRecordingPresented)
            .help("선택한 액션을 위로 이동")

            Button {
                moveSelectedAction(offset: 1)
            } label: {
                Label("아래로 이동", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(!canMoveSelectedAction(offset: 1) || isRecordingPresented)
            .help("선택한 액션을 아래로 이동")

            Menu {
                Button("선택한 액션 삭제", systemImage: "trash", role: .destructive) {
                    removeSelectedAction()
                }
                .disabled(selectedAction == nil || isRecordingPresented)

                Button("범위를 반복으로 묶기…", systemImage: "repeat") {
                    isRepeatRangePresented = true
                }
                .disabled(documentController.document.actions.isEmpty || isRecordingPresented)

                Divider()

                Button("모든 액션 삭제…", systemImage: "trash.slash", role: .destructive) {
                    isDeleteAllConfirmationPresented = true
                }
                .disabled(documentController.document.actions.isEmpty || isRecordingPresented)
            } label: {
                Label("추가 작업", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .help("액션 추가 작업")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var addActionMenu: some View {
        Menu {
            Section("포인터") {
                ForEach(
                    [MacroAction.Kind.click, .doubleClick, .rightClick, .mouseMove, .drag, .scroll],
                    id: \.self
                ) { kind in
                    actionMenuButton(kind)
                }
            }
            Section("입력과 흐름") {
                ForEach([MacroAction.Kind.keyboard, .wait, .repeatBlock], id: \.self) { kind in
                    actionMenuButton(kind)
                }
            }
            Section("결과") {
                actionMenuButton(.capture)
            }
        } label: {
            Label("액션 추가", systemImage: "plus")
        }
        .menuIndicator(.visible)
        .help("직접 액션 추가")
    }

    private func actionMenuButton(_ kind: MacroAction.Kind) -> some View {
        Button {
            actionEditorDraft = ActionEditorDraft(kind: kind)
        } label: {
            Label(kind.displayName, systemImage: kind.systemImage)
        }
    }

    private var emptyActionView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("첫 액션을 만들어 보세요")
                    .font(.title3.weight(.semibold))
                Text("평소처럼 작업을 녹화하거나 필요한 액션을 직접 추가할 수 있습니다.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button(action: { toggleRecording() }) {
                    Label("녹화 시작", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(displayedPlayerState == .running)

                addActionMenu
            }

            Text("녹화 단축키: \(recordingShortcutTitle)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
    }

    private var actionList: some View {
        List(selection: $selectedActionID) {
            ForEach(displayedActions, id: \.action.id) { item in
                if item.isLive {
                    ActionRow(item: item)
                } else {
                    ActionRow(item: item)
                        .tag(item.action.id)
                        .contextMenu {
                            Button("편집", systemImage: "slider.horizontal.3") {
                                actionEditorDraft = ActionEditorDraft(action: item.action)
                            }
                            .disabled(isRecordingPresented)
                            Button("위로 이동", systemImage: "chevron.up") {
                                documentController.moveAction(id: item.action.id, offset: -1)
                            }
                            .disabled(item.position == 0 || isRecordingPresented)
                            Button("아래로 이동", systemImage: "chevron.down") {
                                documentController.moveAction(id: item.action.id, offset: 1)
                            }
                            .disabled(
                                item.position == documentController.document.actions.count - 1
                                    || isRecordingPresented
                            )
                            Divider()
                            Button("삭제", systemImage: "trash", role: .destructive) {
                                documentController.removeAction(id: item.action.id)
                                if selectedActionID == item.action.id {
                                    selectedActionID = nil
                                }
                            }
                            .disabled(isRecordingPresented)
                        }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityLabel("매크로 액션 목록")
    }

    private var controlSidebar: some View {
        ScrollView {
            VStack(spacing: 14) {
                SidebarSection(title: "문서", systemImage: "doc.text") {
                    SidebarInfoRow(title: "저장 위치", value: documentLocationText)
                    SidebarInfoRow(title: "제어 범위", value: "전체 화면")
                    SidebarInfoRow(title: "액션", value: actionCountText)
                    SidebarInfoRow(title: "예상 시간", value: estimatedDurationText)
                    SidebarInfoRow(
                        title: "형식",
                        value: "버전 \(documentController.document.formatVersion)"
                    )
                }

                SidebarSection(title: "녹화 옵션", systemImage: "record.circle") {
                    Picker("마우스 입력", selection: recordingModeBinding) {
                        Text("주요 동작만").tag(InputRecordingMode.meaningfulActionsOnly)
                        Text("모든 움직임").tag(InputRecordingMode.allMouseMovement)
                    }
                    .pickerStyle(.menu)
                    .disabled(isRecordingPresented)

                    Text(recordingModeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("MacroKnot 창의 입력 제외", isOn: $excludesEventsTargetingMacroKnot)
                        .disabled(isRecordingPresented)
                    Text("변경한 옵션은 다음 녹화부터 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                SidebarSection(title: "권한", systemImage: "checkmark.shield") {
                    PermissionIndicator(
                        title: "손쉬운 사용",
                        granted: permissions.accessibilityGranted,
                        action: permissions.openAccessibilitySettings
                    )
                    PermissionIndicator(
                        title: "화면 캡처",
                        granted: permissions.screenCaptureGranted,
                        action: permissions.openScreenCaptureSettings
                    )
                    Button("상태 새로고침", systemImage: "arrow.clockwise", action: permissions.refresh)
                        .buttonStyle(.link)
                }

                SidebarSection(title: "빠른 실행", systemImage: "keyboard") {
                    SidebarInfoRow(title: "녹화", value: recordingShortcutTitle)
                    SidebarInfoRow(title: "재생", value: playbackShortcutTitle)
                    SidebarInfoRow(title: "강제 중지", value: "Control + Escape")
                    SettingsLink {
                        Label("단축키 및 권한 설정", systemImage: "gearshape")
                    }
                }
            }
            .padding(14)
        }
        .background(.thinMaterial)
        .accessibilityLabel("매크로 제어 사이드바")
    }

    private var statusPresentation: WorkspaceStatusPresentation {
        if let activeErrorMessage {
            return WorkspaceStatusPresentation(
                label: "확인 필요",
                detail: activeErrorMessage,
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
        if isRecordingPresented {
            return WorkspaceStatusPresentation(
                label: "녹화 중",
                detail: "입력을 기록하고 있습니다",
                systemImage: "record.circle.fill",
                tint: .red
            )
        }
        switch displayedPlayerState {
        case .running:
            return WorkspaceStatusPresentation(
                label: "실행 중",
                detail: "매크로를 재생하고 있습니다",
                systemImage: "play.circle.fill",
                tint: .indigo
            )
        case .completed:
            return WorkspaceStatusPresentation(
                label: "완료",
                detail: "매크로 실행을 마쳤습니다",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        case .stopped:
            return WorkspaceStatusPresentation(
                label: "중지됨",
                detail: "매크로 실행을 중지했습니다",
                systemImage: "stop.circle.fill",
                tint: .orange
            )
        case .failed:
            return WorkspaceStatusPresentation(
                label: "실패",
                detail: activeErrorMessage ?? "매크로 실행에 실패했습니다",
                systemImage: "xmark.octagon.fill",
                tint: .red
            )
        case .idle:
            if !permissions.accessibilityGranted {
                return WorkspaceStatusPresentation(
                    label: "권한 필요",
                    detail: "손쉬운 사용 권한을 설정해 주세요",
                    systemImage: "hand.raised.fill",
                    tint: .orange
                )
            }
            if requiresScreenCapturePermission {
                return WorkspaceStatusPresentation(
                    label: "캡처 권한 필요",
                    detail: "화면 캡처 권한을 설정해 주세요",
                    systemImage: "camera.fill",
                    tint: .orange
                )
            }
            return WorkspaceStatusPresentation(
                label: "준비됨",
                detail: documentController.document.actions.isEmpty
                    ? "녹화하거나 액션을 추가해 주세요"
                    : "녹화 또는 재생을 시작할 수 있습니다",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private var activeErrorMessage: String? {
        if case .failed(let message) = previewState {
            return message
        }
        if case .failed(let message) = player.state {
            return message
        }
        return documentController.errorMessage
            ?? recorder.errorMessage
            ?? globalCommandMonitor.errorMessage
    }

    private var displayedPlayerState: InputPlayer.State {
        switch previewState {
        case .playing: return .running
        case .failed(let message): return .failed(message)
        case .live, .recording: return player.state
        }
    }

    private var isRecordingPresented: Bool {
        if case .recording = previewState { return true }
        return recorder.isRecording
    }

    private var recordedActionsPresented: [MacroAction] {
        if case .recording(let actions, _) = previewState { return actions }
        return recorder.actions
    }

    private var recordingLastEventPresented: String {
        if case .recording(_, let lastEvent) = previewState { return lastEvent }
        return recorder.lastEvent
    }

    private var displayedActions: [DisplayedAction] {
        let saved = documentController.document.actions.enumerated().map { index, action in
            DisplayedAction(action: action, isLive: false, position: index)
        }
        guard isRecordingPresented else { return saved }
        let visibleRecordedActions = recordedActionsPresented.suffix(Self.liveActionLimit)
        let firstVisiblePosition = saved.count + recordedActionsPresented.count - visibleRecordedActions.count
        let live = visibleRecordedActions.enumerated().map { offset, action in
            DisplayedAction(
                action: action,
                isLive: true,
                position: firstVisiblePosition + offset
            )
        }
        return saved + live
    }

    private var selectedAction: MacroAction? {
        guard let selectedActionID else { return nil }
        return documentController.document.actions.first { $0.id == selectedActionID }
    }

    private var selectedActionIndex: Int? {
        guard let selectedActionID else { return nil }
        return documentController.document.actions.firstIndex { $0.id == selectedActionID }
    }

    private var canStartPlayback: Bool {
        !isRecordingPresented
            && displayedPlayerState != .running
            && !documentController.document.actions.isEmpty
    }

    private var requiresScreenCapturePermission: Bool {
        documentController.document.actions.containsCaptureAction
            && !permissions.screenCaptureGranted
    }

    private var actionCountText: String {
        guard isRecordingPresented else {
            return "\(documentController.document.actions.count)개"
        }
        return "\(documentController.document.actions.count)개 + 녹화 중 \(recordedActionsPresented.count)개"
    }

    private var estimatedDurationText: String {
        MacroDurationFormatter.concise(
            milliseconds: documentController.document.actions.estimatedDurationMilliseconds
        )
    }

    private var selectionDescription: String {
        if isRecordingPresented {
            if recordedActionsPresented.count > Self.liveActionLimit {
                return "녹화 중 · 최근 \(Self.liveActionLimit)개 액션 표시"
            }
            return "새 액션이 목록에 실시간으로 추가됩니다"
        }
        guard let selectedActionIndex, let selectedAction else {
            return displayedActions.isEmpty ? "녹화하거나 직접 추가할 수 있습니다" : "액션을 선택하면 편집할 수 있습니다"
        }
        return "\(selectedActionIndex + 1)번 · \(selectedAction.displayName) 선택됨"
    }

    private var documentLocationText: String {
        documentController.currentURL?.lastPathComponent ?? "아직 저장되지 않음"
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

    private var recordingModeDescription: String {
        switch recordingMode {
        case .meaningfulActionsOnly:
            return "클릭·스크롤·드래그를 기록하고 단순 포인터 이동은 제외합니다."
        case .allMouseMovement:
            return "포인터가 움직이는 모든 경로를 액션으로 기록합니다."
        }
    }

    private var recordingShortcutTitle: String {
        (RecordingShortcutChoice(rawValue: recordingShortcutRawValue)
            ?? AppPreferenceDefaults.recordingShortcut).title
    }

    private var playbackShortcutTitle: String {
        (PlaybackShortcutChoice(rawValue: playbackShortcutRawValue)
            ?? AppPreferenceDefaults.playbackShortcut).title
    }

    private static let liveActionLimit = 200

    private func handleAppearance() {
        startGlobalCommandMonitor()
        DispatchQueue.main.async {
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func newDocument() {
        documentController.newDocument()
        selectedActionID = nil
    }

    private func openDocument() {
        documentController.openDocument()
        selectedActionID = nil
    }

    private func editSelectedAction() {
        guard let selectedAction else { return }
        actionEditorDraft = ActionEditorDraft(action: selectedAction)
    }

    private func moveSelectedAction(offset: Int) {
        guard let selectedActionID else { return }
        documentController.moveAction(id: selectedActionID, offset: offset)
    }

    private func canMoveSelectedAction(offset: Int) -> Bool {
        guard let selectedActionIndex else { return false }
        return documentController.document.actions.indices.contains(selectedActionIndex + offset)
    }

    private func removeSelectedAction() {
        guard let selectedActionID else { return }
        documentController.removeAction(id: selectedActionID)
        self.selectedActionID = nil
    }

    private func toggleRecording(triggeredByGlobalShortcut: Bool = false) {
        if recorder.isRecording {
            recorder.stop(discardingTrailingShortcutModifiers: triggeredByGlobalShortcut)
            let recordedActions = recorder.actions
            documentController.appendRecordedActions(recordedActions)
            selectedActionID = recordedActions.last?.id
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

    private func startPlayback() {
        guard !recorder.isRecording,
            player.state != .running,
            !documentController.document.actions.isEmpty
        else { return }
        guard permissions.accessibilityGranted else {
            permissions.openAccessibilitySettings()
            return
        }
        guard !requiresScreenCapturePermission else {
            permissions.openScreenCaptureSettings()
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
    let position: Int
}

private struct ActionRow: View {
    let item: DisplayedAction

    var body: some View {
        HStack(spacing: 12) {
            Text("\(item.position + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(item.action.kind.tint.opacity(0.13))
                Image(systemName: item.action.kind.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(item.action.kind.tint)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.action.kind.displayName)
                        .fontWeight(.medium)
                    if item.isLive {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.red)
                                .frame(width: 5, height: 5)
                            Text("녹화 중")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.10), in: Capsule())
                    }
                }
                Text(item.action.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if !item.isLive,
                let error = validationMessage
            {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
                    .accessibilityLabel("오류: \(error)")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.position + 1)번, \(item.action.kind.displayName), \(item.action.summary)"
        )
    }

    private var validationMessage: String? {
        do {
            try item.action.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct WorkspaceStatusPresentation {
    let label: String
    let detail: String
    let systemImage: String
    let tint: Color
}

private struct StatusBadge: View {
    let presentation: WorkspaceStatusPresentation

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.tint)
            Text(presentation.label)
                .foregroundStyle(.primary)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(presentation.tint.opacity(0.12), in: Capsule())
        .help(presentation.detail)
        .accessibilityLabel("상태: \(presentation.label). \(presentation.detail)")
    }
}

private struct FeedbackBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.22))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ActivityBanner: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    var showsProgress = false
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(tint)
            } else {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .tint(tint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(tint.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.16))
                .frame(height: 1)
        }
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }
}

private struct SidebarInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.callout)
    }
}

private struct PermissionIndicator: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
                .font(.callout)
            Spacer()
            if granted {
                Text("허용됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("설정", action: action)
                    .buttonStyle(.link)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(granted ? "허용됨" : "설정 필요")")
    }
}

extension MacroAction {
    fileprivate var displayName: String {
        kind.displayName
    }
}

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
