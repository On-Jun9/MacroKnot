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

enum MacroEditorChangeDetection {
    static func hasUnsavedChanges(
        initial: MacroDocument?,
        current: MacroDocument
    ) -> Bool {
        guard let initial else { return true }
        return current != initial
    }
}

struct MacroEditorConfiguration {
    let startRecording: Bool
    let isPlaybackRunning: () -> Bool
    let onRecordingRequestHandled: () -> Void
    let onRecordingStateChanged: (Bool) -> Void
    let onDraftChanged: (MacroDocument) -> Void
    let onSave: (MacroDocument) throws -> Void
    let onCancel: () -> Void
    let onClose: () -> Void
}

extension Notification.Name {
    static let macroKnotToggleEditorRecording = Notification.Name(
        "MacroKnotToggleEditorRecording"
    )
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var permissions: PermissionState
    @StateObject private var documentController: DocumentController
    @StateObject private var recorder = InputRecorder()
    @StateObject private var player = InputPlayer()
    @StateObject private var globalCommandMonitor = GlobalCommandMonitor()
    @State private var actionEditorDraft: ActionEditorDraft?
    @State private var selectedActionIDs: Set<UUID>
    @State private var isRepeatRangePresented = false
    @State private var isDeleteAllConfirmationPresented = false
    @State private var isCancelConfirmationPresented = false
    @State private var editorErrorMessage: String?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isSidebarPresented = true
    @FocusState private var isMacroNameFocused: Bool
    @State private var initialDocumentSnapshot: MacroDocument?
    @AppStorage(AppPreferenceKeys.excludesEventsTargetingMacroKnot)
    private var excludesEventsTargetingMacroKnot = true
    @AppStorage(AppPreferenceKeys.recordingMode)
    private var recordingModeRawValue = AppPreferenceDefaults.recordingMode.rawValue
    @AppStorage(AppPreferenceKeys.recordingShortcut)
    private var recordingShortcutRawValue = AppPreferenceDefaults.recordingShortcut.rawValue
    @AppStorage(AppPreferenceKeys.playbackShortcut)
    private var playbackShortcutRawValue = AppPreferenceDefaults.playbackShortcut.rawValue

    private let previewState: WorkspacePreviewState
    private let editorConfiguration: MacroEditorConfiguration?

    init(
        permissions: PermissionState,
        initialDocument: MacroDocument? = nil,
        initialSelectedActionIDs: Set<UUID> = [],
        previewState: WorkspacePreviewState = .live,
        editorConfiguration: MacroEditorConfiguration? = nil
    ) {
        self.permissions = permissions
        self.previewState = previewState
        self.editorConfiguration = editorConfiguration
        _documentController = StateObject(
            wrappedValue: DocumentController(initialDocument: initialDocument)
        )
        _selectedActionIDs = State(initialValue: initialSelectedActionIDs)
        _initialDocumentSnapshot = State(initialValue: initialDocument)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Divider()
                feedbackBanner
                if editorConfiguration != nil {
                    workspace
                        .frame(minWidth: 560)
                } else {
                    HSplitView {
                        if isSidebarPresented {
                            controlSidebar
                                .frame(minWidth: 270, idealWidth: 300, maxWidth: 340)
                        }
                        workspace
                            .frame(minWidth: 560)
                    }
                }
            }
            .navigationTitle(
                editorConfiguration == nil ? documentController.windowTitle : "매크로 편집"
            )
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
                selectedActionIDs = [action.id]
            }
        }
        .sheet(isPresented: $isRepeatRangePresented) {
            RepeatRangeSheet(actions: documentController.document.actions) { start, end, count in
                try documentController.wrapActionsInRepeat(
                    from: start,
                    through: end,
                    count: count
                )
                selectedActionIDs = Set(
                    documentController.document.actions[start...end].map(\.id)
                )
            }
        }
        .alert("모든 액션을 삭제할까요?", isPresented: $isDeleteAllConfirmationPresented) {
            Button("전체 삭제", role: .destructive) {
                documentController.removeAllActions()
                selectedActionIDs.removeAll()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 문서의 액션이 모두 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .alert("초안 편집을 취소할까요?", isPresented: $isCancelConfirmationPresented) {
            Button("초안 삭제", role: .destructive) {
                editorConfiguration?.onCancel()
            }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("지금까지 편집한 초안이 삭제됩니다.")
        }
        .onAppear(perform: handleAppearance)
        .onDisappear {
            globalCommandMonitor.stop()
            autosaveTask?.cancel()
            if recorder.isRecording {
                recorder.stop()
                documentController.appendRecordedActions(recorder.actions)
                editorConfiguration?.onRecordingStateChanged(false)
            }
            if editorConfiguration != nil {
                editorConfiguration?.onDraftChanged(documentController.document)
            }
        }
        .onChange(of: permissions.accessibilityGranted) { _, granted in
            if granted, editorConfiguration == nil {
                startGlobalCommandMonitor()
            } else {
                globalCommandMonitor.stop()
            }
        }
        .onChange(of: recorder.isRecording) { _, isRecording in
            editorConfiguration?.onRecordingStateChanged(isRecording)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                permissions.refresh()
            }
        }
        .onChange(of: documentController.document.actions.map(\.id)) { _, actionIDs in
            selectedActionIDs.formIntersection(actionIDs)
        }
        .onChange(of: documentController.document) { _, document in
            scheduleDraftAutosave(document)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macroKnotToggleEditorRecording)) { _ in
            guard editorConfiguration != nil else { return }
            toggleRecording(triggeredByGlobalShortcut: true)
        }
        .focusedSceneValue(
            \.macroCommands,
            focusedMacroCommands
        )
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        if editorConfiguration == nil {
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
        }

        if editorConfiguration == nil {
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

                if displayedPlayerState == .running {
                    Button(role: .destructive, action: player.stop) {
                        Label("중지", systemImage: "stop.fill")
                    }
                    .keyboardShortcut(.escape, modifiers: .control)
                }

                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider()
            activityBanner
            if editorConfiguration != nil {
                editorActionWorkspace
            } else {
                actionWorkspace
            }
            if editorConfiguration != nil {
                Divider()
                editorFooter
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var workspaceHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                TextField("매크로 이름", text: $documentController.document.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .focused($isMacroNameFocused)
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
            actionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorActionWorkspace: some View {
        VStack(spacing: 0) {
            actionToolbar
            Divider()
            recordingSettingsBar
            Divider()
            actionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var actionContent: some View {
        if displayedActions.isEmpty {
            emptyActionView
        } else {
            actionList
        }
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

            if editorConfiguration != nil {
                Button(action: { toggleRecording() }) {
                    Label(
                        isRecordingPresented ? "녹화 중지" : "녹화 시작",
                        systemImage: isRecordingPresented ? "stop.fill" : "record.circle.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .fixedSize()
                .disabled(!isRecordingPresented && editorConfiguration?.isPlaybackRunning() == true)
                .help(isRecordingPresented ? "현재 녹화를 마칩니다" : "사용자 입력 녹화를 시작합니다")

            }

            addActionMenu
                .fixedSize()
                .disabled(isRecordingPresented)

            Button("편집", systemImage: "slider.horizontal.3") {
                editSelectedAction()
            }
            .disabled(selectedAction == nil || isRecordingPresented)
            .help("선택한 액션 편집")

            Menu {
                Button(deleteSelectionTitle, systemImage: "trash", role: .destructive) {
                    removeSelectedActions()
                }
                .disabled(selectedActionIDs.isEmpty || isRecordingPresented)

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
            .menuIndicator(.hidden)
            .help("액션 추가 작업")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var recordingSettingsBar: some View {
        HStack(spacing: 12) {
            Text("마우스 기록")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 3) {
                CompactChoiceButton(
                    title: "주요 동작만",
                    isSelected: recordingMode == .meaningfulActionsOnly
                ) {
                    recordingModeRawValue = InputRecordingMode.meaningfulActionsOnly.rawValue
                }
                CompactChoiceButton(
                    title: "모든 움직임",
                    isSelected: recordingMode == .allMouseMovement
                ) {
                    recordingModeRawValue = InputRecordingMode.allMouseMovement.rawValue
                }
            }
            .padding(3)
            .frame(width: 230)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))

            Spacer()

            Toggle("MacroKnot 창 입력 제외", isOn: $excludesEventsTargetingMacroKnot)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .disabled(isRecordingPresented)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.025))
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            Text("편집 내용은 임시 초안으로 자동 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("취소") {
                cancelEditor()
            }
            Button(action: saveEditor) {
                Label("보관함에 저장", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRecordingPresented)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
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
                    Label("녹화 시작", systemImage: "record.circle.fill")
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
        List(selection: $selectedActionIDs) {
            ForEach(displayedActions, id: \.action.id) { item in
                if item.isLive {
                    ActionRow(item: item)
                } else {
                    ActionRow(item: item)
                        .tag(item.action.id)
                        .contextMenu {
                            Button("편집", systemImage: "slider.horizontal.3") {
                                selectedActionIDs = [item.action.id]
                                actionEditorDraft = ActionEditorDraft(action: item.action)
                            }
                            .disabled(isRecordingPresented)
                            Divider()
                            Button(contextDeleteTitle(for: item.action.id), systemImage: "trash", role: .destructive) {
                                let ids = selectedActionIDs.contains(item.action.id)
                                    ? selectedActionIDs
                                    : [item.action.id]
                                documentController.removeActions(ids: ids)
                                selectedActionIDs.subtract(ids)
                            }
                            .disabled(isRecordingPresented)
                        }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(
            editorConfiguration == nil
                ? Color(nsColor: .textBackgroundColor)
                : Color(nsColor: .controlBackgroundColor)
        )
        .accessibilityLabel("매크로 액션 목록")
        .onDeleteCommand {
            guard !selectedActionIDs.isEmpty, !isRecordingPresented else { return }
            removeSelectedActions()
        }
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

                if editorConfiguration == nil {
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
                }

                if editorConfiguration == nil {
                    SidebarSection(title: "빠른 실행", systemImage: "keyboard") {
                        SidebarInfoRow(title: "녹화", value: recordingShortcutTitle)
                        SidebarInfoRow(title: "재생", value: playbackShortcutTitle)
                        SidebarInfoRow(title: "강제 중지", value: "Control + Escape")
                        SettingsLink {
                            Label("단축키 및 권한 설정", systemImage: "gearshape")
                        }
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
        if let editorErrorMessage {
            return editorErrorMessage
        }
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
        guard selectedActionIDs.count == 1, let selectedActionID = selectedActionIDs.first else {
            return nil
        }
        return documentController.document.actions.first { $0.id == selectedActionID }
    }

    private var selectedActionIndex: Int? {
        guard let selectedActionID = selectedActionIDs.first, selectedActionIDs.count == 1 else {
            return nil
        }
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
        if selectedActionIDs.count > 1 {
            return "\(selectedActionIDs.count)개 액션 선택됨 · Command/Shift로 선택 조정"
        }
        guard let selectedActionIndex, let selectedAction else {
            return displayedActions.isEmpty ? "녹화하거나 직접 추가할 수 있습니다" : "액션을 선택하면 편집할 수 있습니다"
        }
        return "\(selectedActionIndex + 1)번 · \(selectedAction.displayName) 선택됨"
    }

    private var deleteSelectionTitle: String {
        selectedActionIDs.count > 1
            ? "선택한 액션 \(selectedActionIDs.count)개 삭제"
            : "선택한 액션 삭제"
    }

    private func contextDeleteTitle(for id: UUID) -> String {
        selectedActionIDs.contains(id) && selectedActionIDs.count > 1
            ? "선택한 액션 \(selectedActionIDs.count)개 삭제"
            : "삭제"
    }

    private var documentLocationText: String {
        if editorConfiguration != nil { return "보관함 초안" }
        return documentController.currentURL?.lastPathComponent ?? "아직 저장되지 않음"
    }

    private var focusedMacroCommands: MacroCommands {
        if editorConfiguration != nil {
            return MacroCommands(
                newMacro: nil,
                importMacro: nil,
                saveMacro: saveEditor,
                exportMacro: nil,
                closeWindow: editorConfiguration?.onClose
            )
        }
        return MacroCommands(
            newMacro: newDocument,
            importMacro: openDocument,
            saveMacro: documentController.saveDocument,
            exportMacro: documentController.saveDocumentAs,
            closeWindow: {
                NSApplication.shared.keyWindow?.performClose(nil)
            }
        )
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
        if editorConfiguration == nil {
            startGlobalCommandMonitor()
        } else if editorConfiguration?.startRecording == true {
            DispatchQueue.main.async {
                editorConfiguration?.onRecordingRequestHandled()
                toggleRecording(triggeredByGlobalShortcut: true)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            isMacroNameFocused = false
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func saveEditor() {
        guard let editorConfiguration else { return }
        if recorder.isRecording {
            toggleRecording()
        }
        do {
            autosaveTask?.cancel()
            try documentController.document.validate()
            try editorConfiguration.onSave(documentController.document)
            editorErrorMessage = nil
        } catch {
            editorErrorMessage = error.localizedDescription
        }
    }

    private func scheduleDraftAutosave(_ document: MacroDocument) {
        guard let editorConfiguration else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            editorConfiguration.onDraftChanged(document)
        }
    }

    private func newDocument() {
        documentController.newDocument()
        selectedActionIDs.removeAll()
    }

    private func openDocument() {
        documentController.openDocument()
        selectedActionIDs.removeAll()
    }

    private func editSelectedAction() {
        guard let selectedAction else { return }
        actionEditorDraft = ActionEditorDraft(action: selectedAction)
    }

    private func removeSelectedActions() {
        guard !selectedActionIDs.isEmpty else { return }
        documentController.removeActions(ids: selectedActionIDs)
        selectedActionIDs.removeAll()
    }

    private var hasUnsavedChanges: Bool {
        MacroEditorChangeDetection.hasUnsavedChanges(
            initial: initialDocumentSnapshot,
            current: documentController.document
        )
    }

    private func cancelEditor() {
        if hasUnsavedChanges {
            isCancelConfirmationPresented = true
        } else {
            editorConfiguration?.onCancel()
        }
    }

    private func toggleRecording(triggeredByGlobalShortcut: Bool = false) {
        if recorder.isRecording {
            recorder.stop(discardingTrailingShortcutModifiers: triggeredByGlobalShortcut)
            let recordedActions = recorder.actions
            documentController.appendRecordedActions(recordedActions)
            selectedActionIDs = Set(recordedActions.last.map { [$0.id] } ?? [])
            editorConfiguration?.onRecordingStateChanged(false)
            return
        }
        guard editorConfiguration?.isPlaybackRunning() != true else { return }
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
        editorConfiguration?.onRecordingStateChanged(recorder.isRecording)
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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
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
