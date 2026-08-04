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

enum MacroEditorCancelPolicy {
    /// 취소가 실제 내용을 잃게 할 때만 확인창을 띄운다.
    /// 창을 연 시점이 아니라 초안의 종류를 기준으로 판단해,
    /// 복구된 초안도 세션 내 변경 여부와 무관하게 보호한다.
    static func requiresConfirmation(
        mode: MacroDraftRecord.Mode,
        current: MacroDocument,
        original: MacroDocument?
    ) -> Bool {
        switch mode {
        case .create:
            return !current.actions.isEmpty || current.name != MacroDraftRecord.defaultName
        case .edit:
            guard let original else { return true }
            return current.name != original.name || current.actions != original.actions
        }
    }
}

enum MacroEditorValidation {
    static func saveBlockingReason(for document: MacroDocument) -> String? {
        do {
            try document.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct MacroEditorConfiguration {
    let startRecording: Bool
    let isPlaybackRunning: () -> Bool
    let onRecordingRequestHandled: () -> Void
    let onRecordingStateChanged: (Bool) -> Void
    let onDraftChanged: (MacroDocument) -> Void
    let shouldConfirmCancel: (MacroDocument) -> Bool
    let onSave: (MacroDocument) throws -> Void
    let onCancel: () -> Void
}

/// 편집 창이 닫히기 전에 취소 확인을 거치도록 창 delegate에 전달 프록시를 끼운다.
/// SwiftUI가 창 닫기 가로채기 API를 제공하지 않아 사용하는 우회로,
/// 원래 delegate(SwiftUI 내부)가 모든 호출을 그대로 받도록 전부 전달하고
/// `windowShouldClose` 판단 하나만 얹는다. 뷰가 창에서 빠지면 원래 delegate를 복원한다.
private struct EditorWindowCloseConfirmation: NSViewRepresentable {
    /// 닫아도 되면 true, 확인이 필요해 닫기를 보류하면 false를 돌려준다.
    let shouldAllowClose: @MainActor () -> Bool

    final class DelegateProxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        var shouldAllowClose: (@MainActor () -> Bool)?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let allowed = MainActor.assumeIsolated {
                shouldAllowClose?() ?? true
            }
            guard allowed else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if original?.responds(to: aSelector) == true {
                return original
            }
            return super.forwardingTarget(for: aSelector)
        }
    }

    final class Coordinator {
        let proxy = DelegateProxy()
        weak var window: NSWindow?

        func install(on window: NSWindow) {
            guard window.delegate !== proxy else { return }
            self.window = window
            proxy.original = window.delegate
            window.delegate = proxy
        }

        func uninstall() {
            guard let window, window.delegate === proxy else { return }
            window.delegate = proxy.original
            self.window = nil
        }
    }

    final class AttachmentView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = AttachmentView()
        context.coordinator.proxy.shouldAllowClose = shouldAllowClose
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            if let window {
                coordinator?.install(on: window)
            } else {
                coordinator?.uninstall()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.proxy.shouldAllowClose = shouldAllowClose
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }
}

extension Notification.Name {
    static let macroKnotToggleEditorRecording = Notification.Name(
        "MacroKnotToggleEditorRecording"
    )
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @ObservedObject var permissions: PermissionState
    @StateObject private var documentController: DocumentController
    @StateObject private var recorder = InputRecorder()
    @StateObject private var player = InputPlayer()
    @StateObject private var globalCommandMonitor = GlobalCommandMonitor()
    @State private var actionEditorDraft: ActionEditorDraft?
    @State private var selectedActionIDs: Set<UUID>
    /// 새로 추가한 액션이 목록 밖에 있으면 어디에 들어갔는지 알 수 없어 그 행까지 스크롤한다.
    @State private var actionToRevealID: UUID?
    @State private var isRepeatRangePresented = false
    @State private var isDeleteAllConfirmationPresented = false
    @State private var isCancelConfirmationPresented = false
    @State private var didResolveEditor = false
    @State private var editorErrorMessage: String?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isSidebarPresented = true
    @FocusState private var isMacroNameFocused: Bool
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
        .background {
            if editorConfiguration != nil {
                EditorWindowCloseConfirmation {
                    // 저장·취소로 이미 처리됐으면 그대로 닫고,
                    // 아니면 취소 흐름(필요 시 확인창)을 거친다.
                    if didResolveEditor { return true }
                    cancelEditor()
                    return false
                }
            }
        }
        .background {
            if editorConfiguration != nil {
                EditorActionCommands(
                    onCopy: canCopySelectedActions ? copySelectedActions : nil,
                    onPaste: isRecordingPresented ? nil : pasteCopiedActions,
                    canPaste: { [weak documentController] in
                        documentController?.canPasteActions ?? false
                    },
                    onCancel: cancelEditor
                )
            }
        }
        .onExitCommand(perform: editorConfiguration == nil ? nil : cancelEditor)
        .sheet(item: $actionEditorDraft) { draft in
            ActionEditorSheet(draft: draft) { action in
                if documentController.document.actions.contains(where: { $0.id == action.id }) {
                    documentController.updateAction(action)
                } else {
                    documentController.addAction(action, after: selectedActionIDs)
                    actionToRevealID = action.id
                }
                selectedActionIDs = [action.id]
            }
        }
        .sheet(isPresented: $isRepeatRangePresented) {
            RepeatRangeSheet(actions: documentController.document.actions) { start, end, count in
                let wrappedID = try documentController.wrapActionsInRepeat(
                    from: start,
                    through: end,
                    count: count
                )
                selectedActionIDs = [wrappedID]
            }
        }
        .alert("모든 액션을 삭제할까요?", isPresented: $isDeleteAllConfirmationPresented) {
            Button("전체 삭제", role: .destructive) {
                documentController.removeAllActions()
                selectedActionIDs.removeAll()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 문서의 액션이 모두 삭제됩니다.")
        }
        .alert("초안 편집을 취소할까요?", isPresented: $isCancelConfirmationPresented) {
            Button("초안 삭제", role: .destructive) {
                didResolveEditor = true
                editorConfiguration?.onCancel()
            }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("지금까지 편집한 초안이 삭제됩니다.")
        }
        .onAppear {
            documentController.undoManager = undoManager
            handleAppearance()
        }
        .onChange(of: undoManager) { _, manager in
            documentController.undoManager = manager
        }
        .onDisappear {
            // undo 스택은 컨트롤러를 강하게 잡지 않으므로, 뷰가 내려갈 때
            // 창의 UndoManager에 남은 항목을 정리해 해제 후 접근을 막는다.
            documentController.undoManager?.removeAllActions(withTarget: documentController)
            globalCommandMonitor.stop()
            autosaveTask?.cancel()
            if recorder.isRecording {
                recorder.stop()
                documentController.isRecordingInProgress = false
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
#if DEBUG
        .onReceive(
            NotificationCenter.default.publisher(for: .debugMacroEditorAppendWaitAction)
        ) { _ in
            guard editorConfiguration != nil else { return }
            documentController.addWaitAction()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .debugMacroEditorRequestCancel)
        ) { _ in
            guard editorConfiguration != nil else { return }
            cancelEditor()
        }
#endif
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
            if editorConfiguration != nil {
                editorActionWorkspace
            } else {
                activityBanner
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
                    if editorConfiguration != nil {
                        Label(
                            "액션 \(documentController.document.actions.count)개",
                            systemImage: "list.bullet"
                        )
                        Text("·")
                            .accessibilityHidden(true)
                        Text("예상 \(estimatedDurationText)")
                        Text("·")
                            .accessibilityHidden(true)
                        Text("초안 자동 저장")
                    } else {
                        Label(documentLocationText, systemImage: "doc.text")
                        Text("·")
                            .accessibilityHidden(true)
                        Text("전체 화면 제어")
                        Text("·")
                            .accessibilityHidden(true)
                        Text("예상 \(estimatedDurationText)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            if editorConfiguration == nil {
                StatusBadge(presentation: statusPresentation)
            }
        }
        .padding(.horizontal, editorConfiguration == nil ? 22 : 24)
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
        VStack(spacing: 14) {
            recordingSetupCard
            editorActionsCard
        }
        .frame(maxWidth: 920, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var recordingSetupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("녹화 설정")
                    .font(.headline)
                editorRecordingStatus
                Spacer()

                Button(action: { toggleRecording() }) {
                    Label(
                        isRecordingPresented ? "녹화 중지" : "녹화 시작",
                        systemImage: isRecordingPresented ? "stop.fill" : "record.circle.fill"
                    )
                    .frame(minWidth: 84)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecordingPresented ? .red : .accentColor)
                .disabled(
                    !isRecordingPresented
                        && editorConfiguration?.isPlaybackRunning() == true
                )
                .help(
                    isRecordingPresented
                        ? "현재 녹화를 마칩니다"
                        : "현재 설정으로 사용자 입력 녹화를 시작합니다"
                )
            }

            EditorSettingRow(title: "마우스 기록") {
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
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(isRecordingPresented)

            EditorSettingRow(title: "창 입력") {
                Toggle("MacroKnot 창 입력 제외", isOn: $excludesEventsTargetingMacroKnot)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .disabled(isRecordingPresented)

            HStack(spacing: 7) {
                Image(systemName: "keyboard")
                Text("녹화 단축키: \(recordingShortcutTitle)")
                Spacer()
                if isRecordingPresented {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text("\(recordedActionsPresented.count)개 기록됨 · \(recordingLastEventPresented)")
                        .lineLimit(1)
                } else {
                    Image(systemName: "arrow.forward.circle")
                    Text("설정은 다음 녹화부터 적용됩니다")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private var editorActionsCard: some View {
        VStack(spacing: 0) {
            editorActionToolbar
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
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var editorActionToolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("액션 편집")
                        .font(.headline)
                    Text(actionCountText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(selectionDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            addActionMenu
                .fixedSize()
                .disabled(isRecordingPresented)

            Button("선택 편집", systemImage: "slider.horizontal.3") {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var editorRecordingStatus: some View {
        if isRecordingPresented {
            Label("녹화 중", systemImage: "record.circle.fill")
                .foregroundStyle(.red)
        } else if !permissions.accessibilityGranted {
            Label("권한 필요", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Label("녹화 준비", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
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
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var editorFooter: some View {
        HStack(spacing: 10) {
            if let editorSaveBlockingReason {
                Label(editorSaveBlockingReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Label("편집 내용은 임시 초안으로 자동 저장됩니다.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("취소") {
                cancelEditor()
            }
            Button(action: saveEditor) {
                Label("보관함에 저장", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRecordingPresented || editorSaveBlockingReason != nil)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 24)
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
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 56, height: 56)
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("첫 액션을 만들어 보세요")
                    .font(.title3.weight(.semibold))
                Text(
                    editorConfiguration == nil
                        ? "평소처럼 작업을 녹화하거나 필요한 액션을 직접 추가할 수 있습니다."
                        : "위의 녹화 설정에서 시작하거나 필요한 액션을 직접 추가할 수 있습니다."
                )
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if editorConfiguration == nil {
                Button(action: { toggleRecording() }) {
                    Label("녹화 시작", systemImage: "record.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(displayedPlayerState == .running)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
    }

    private var actionList: some View {
        ScrollViewReader { proxy in
            actionListContent
                .onChange(of: actionToRevealID) { _, id in
                    guard let id else { return }
                    // 추가된 행은 이 변경과 같은 주기에 만들어지므로 다음 주기에 스크롤한다.
                    DispatchQueue.main.async {
                        proxy.scrollTo(id)
                        actionToRevealID = nil
                    }
                }
        }
    }

    private var actionListContent: some View {
        List(selection: $selectedActionIDs) {
            ForEach(displayedActions, id: \.action.id) { item in
                if item.isLive {
                    ActionRow(item: item)
                } else {
                    ActionRow(item: item)
                        .tag(item.action.id)
                }
            }
            .onMove(perform: isRecordingPresented ? nil : moveActions)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("편집", systemImage: "slider.horizontal.3") {
                    selectedActionIDs = ids
                    editSelectedAction()
                }
                .disabled(ids.count != 1 || isRecordingPresented)
                Divider()
                Button(
                    ids.count > 1 ? "선택한 액션 \(ids.count)개 삭제" : "삭제",
                    systemImage: "trash",
                    role: .destructive
                ) {
                    documentController.removeActions(ids: ids)
                    selectedActionIDs.subtract(ids)
                }
                .disabled(isRecordingPresented)
            }
        } primaryAction: { ids in
            guard !isRecordingPresented, ids.count == 1 else { return }
            selectedActionIDs = ids
            editSelectedAction()
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

    private var editorSaveBlockingReason: String? {
        guard editorConfiguration != nil else { return nil }
        return MacroEditorValidation.saveBlockingReason(for: documentController.document)
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
            return "\(selectedActionIDs.count)개 선택 · Delete 삭제 · 드래그로 순서 변경"
        }
        guard let selectedActionIndex, let selectedAction else {
            return displayedActions.isEmpty
                ? "녹화하거나 직접 추가할 수 있습니다"
                : "선택 후 Return 편집 · Delete 삭제 · 드래그로 순서 변경"
        }
        return "\(selectedActionIndex + 1)번 · \(selectedAction.displayName) · Return 편집 · Delete 삭제"
    }

    private var deleteSelectionTitle: String {
        selectedActionIDs.count > 1
            ? "선택한 액션 \(selectedActionIDs.count)개 삭제"
            : "선택한 액션 삭제"
    }

    private var documentLocationText: String {
        if editorConfiguration != nil { return "보관함 초안" }
        return documentController.currentURL?.lastPathComponent ?? "아직 저장되지 않음"
    }

    private var canCopySelectedActions: Bool {
        !selectedActionIDs.isEmpty && !isRecordingPresented
    }

    private var focusedMacroCommands: MacroCommands {
        if editorConfiguration != nil {
            return MacroCommands(
                newMacro: nil,
                importMacro: nil,
                saveMacro: saveEditor,
                exportMacro: nil,
                closeWindow: { cancelEditor() },
                duplicateActions: canCopySelectedActions ? duplicateSelectedActions : nil,
                deleteMacro: nil
            )
        }
        return MacroCommands(
            newMacro: newDocument,
            importMacro: openDocument,
            saveMacro: documentController.saveDocument,
            exportMacro: documentController.saveDocumentAs,
            closeWindow: {
                NSApplication.shared.keyWindow?.performClose(nil)
            },
            duplicateActions: nil,
            deleteMacro: nil
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
        // 창이 열리며 이름 필드에 자동 할당된 초기 포커스를 첫 프레임 전에 해제한다.
        isMacroNameFocused = false
        NSApplication.shared.keyWindow?.makeFirstResponder(nil)
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
            didResolveEditor = true
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

    private func copySelectedActions() {
        documentController.copyActions(ids: selectedActionIDs)
    }

    private func pasteCopiedActions() {
        let pastedIDs = documentController.pasteActions(after: selectedActionIDs)
        guard !pastedIDs.isEmpty else { return }
        selectedActionIDs = Set(pastedIDs)
    }

    private func duplicateSelectedActions() {
        let duplicatedIDs = documentController.duplicateActions(ids: selectedActionIDs)
        guard !duplicatedIDs.isEmpty else { return }
        selectedActionIDs = Set(duplicatedIDs)
    }

    private func moveActions(fromOffsets: IndexSet, toOffset: Int) {
        documentController.moveActions(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    private func cancelEditor() {
        // 녹화 중이던 입력을 먼저 문서에 반영해야
        // 취소 정책이 잃을 내용으로 집계할 수 있다.
        if recorder.isRecording {
            toggleRecording()
        }
        if editorConfiguration?.shouldConfirmCancel(documentController.document) == true {
            isCancelConfirmationPresented = true
        } else {
            didResolveEditor = true
            editorConfiguration?.onCancel()
        }
    }

    private func toggleRecording(triggeredByGlobalShortcut: Bool = false) {
        if recorder.isRecording {
            recorder.stop(discardingTrailingShortcutModifiers: triggeredByGlobalShortcut)
            // 녹화로 모인 액션은 한 번의 실행 취소로 되돌릴 수 있어야 하므로
            // 문서에 반영하기 전에 녹화 상태를 먼저 해제한다.
            documentController.isRecordingInProgress = false
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
        documentController.isRecordingInProgress = recorder.isRecording
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

private struct EditorSettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            content
                .frame(maxWidth: .infinity)
        }
    }
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
