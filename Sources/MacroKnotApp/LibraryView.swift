import AppKit
import MacroKnotCore
import SwiftUI
import UniformTypeIdentifiers

enum LibraryPlaybackPreviewState {
    case live
    case playing(iteration: Int)
    case failed(String)
}

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var permissions: PermissionState
    @EnvironmentObject private var store: MacroLibraryStore
    @StateObject private var player = InputPlayer()
    @StateObject private var globalCommandMonitor = GlobalCommandMonitor()
    @State private var searchText = ""
    @State private var playbackRate = 1.0
    @State private var repetitionMode = RepetitionMode.finite
    @State private var repeatCount = 1
    @State private var isDeleteConfirmationPresented = false
    @State private var isDraftRecoveryPresented = false
    @State private var localErrorMessage: String?
    private let previewState: LibraryPlaybackPreviewState

    init(
        permissions: PermissionState,
        previewState: LibraryPlaybackPreviewState = .live
    ) {
        self.permissions = permissions
        self.previewState = previewState
    }

    var body: some View {
        NavigationSplitView {
            librarySidebar
                .navigationSplitViewColumnWidth(min: 270, ideal: 300, max: 340)
        } detail: {
            if let record = store.selectedRecord {
                macroDetail(record)
            } else {
                emptyLibrary
            }
        }
        .navigationTitle("MacroKnot")
        .frame(minWidth: 840, minHeight: 580)
        .focusedSceneValue(
            \.macroCommands,
            MacroCommands(
                newMacro: createMacro,
                importMacro: importMacro,
                saveMacro: nil,
                exportMacro: store.selectedRecord == nil ? nil : exportSelectedMacro
            )
        )
        .alert("저장되지 않은 초안이 있습니다", isPresented: $isDraftRecoveryPresented) {
            Button("계속 편집") { openRecoverableDraft() }
            Button("초안 삭제", role: .destructive) { store.discardDraft() }
        } message: {
            Text("이전에 편집하던 내용을 이어서 작업할 수 있습니다.")
        }
        .alert("선택한 매크로를 삭제할까요?", isPresented: $isDeleteConfirmationPresented) {
            Button("삭제", role: .destructive, action: deleteSelectedMacro)
            Button("취소", role: .cancel) {}
        } message: {
            Text("보관함에서 삭제되며 되돌릴 수 없습니다.")
        }
        .onAppear(perform: handleAppearance)
        .onDisappear {
            globalCommandMonitor.stop()
            player.stop()
            store.setPlaybackRunning(false)
        }
        .onChange(of: player.state) { _, state in
            store.setPlaybackRunning(state == .running)
        }
        .onChange(of: permissions.accessibilityGranted) { _, granted in
            granted ? startGlobalCommandMonitor() : globalCommandMonitor.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
        .onChange(of: store.selectedID) { oldValue, newValue in
            if oldValue != newValue, displayedPlayerState == .running { player.stop() }
        }
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("보관함")
                            .font(.title2.weight(.semibold))
                        Text("저장한 매크로 \(store.records.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: createMacro) {
                        Label("새 매크로", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("새 매크로 만들기 (⌘N)")
                }

                TextField("매크로 검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Divider()

            if filteredRecords.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "저장된 매크로가 없습니다" : "검색 결과가 없습니다")
                        .font(.callout.weight(.medium))
                    if searchText.isEmpty {
                        Button("첫 매크로 만들기", action: createMacro)
                            .buttonStyle(.link)
                    }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                    ForEach(filteredRecords) { record in
                            Button {
                                store.selectedID = record.id
                            } label: {
                                LibraryRow(record: record)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(13)
                                    .background(
                                        Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 11)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 11)
                                            .stroke(
                                                store.selectedID == record.id
                                                    ? Color.accentColor.opacity(0.8)
                                                    : Color(nsColor: .separatorColor).opacity(0.45),
                                                lineWidth: store.selectedID == record.id ? 2 : 1
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("편집", systemImage: "pencil") { edit(record.id) }
                                Button("복제", systemImage: "plus.square.on.square") {
                                    _ = store.duplicate(id: record.id)
                                }
                                Divider()
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    store.selectedID = record.id
                                    isDeleteConfirmationPresented = true
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }

            Divider()
            HStack {
                Button("가져오기…", systemImage: "square.and.arrow.down", action: importMacro)
                    .buttonStyle(.plain)
                Spacer()
                SettingsLink {
                    Label("설정", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.thinMaterial)
    }

    private func macroDetail(_ record: MacroLibraryRecord) -> some View {
        VStack(spacing: 0) {
            detailHeader(record)
            Divider()
            if let errorMessage = activeErrorMessage {
                LibraryFeedbackBanner(
                    title: "실행할 수 없습니다",
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
            } else if !permissions.accessibilityGranted {
                LibraryFeedbackBanner(
                    title: "손쉬운 사용 권한이 필요합니다",
                    message: "입력 재생과 전역 단축키를 사용하려면 시스템 설정에서 권한을 켜 주세요.",
                    systemImage: "hand.raised.fill",
                    tint: .orange,
                    actionTitle: "권한 설정",
                    action: permissions.openAccessibilitySettings
                )
            } else if record.document.actions.containsCaptureAction,
                      !permissions.screenCaptureGranted {
                LibraryFeedbackBanner(
                    title: "화면 캡처 권한이 필요합니다",
                    message: "이 매크로의 캡처 액션을 실행하려면 화면 기록 권한을 켜 주세요.",
                    systemImage: "camera.fill",
                    tint: .orange,
                    actionTitle: "권한 설정",
                    action: permissions.openScreenCaptureSettings
                )
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    playbackCard(record)
                    actionPreview(record.document.actions)
                }
                .padding(24)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func detailHeader(_ record: MacroLibraryRecord) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(record.document.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label("액션 \(record.document.actions.count)개", systemImage: "list.bullet")
                    Text("·")
                    Text("예상 \(durationText(for: record.document))")
                    Text("·")
                    Text(record.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("편집", systemImage: "pencil") { edit(record.id) }
            Menu {
                Button("복제", systemImage: "plus.square.on.square") {
                    _ = store.duplicate(id: record.id)
                }
                Button("내보내기…", systemImage: "square.and.arrow.up", action: exportSelectedMacro)
                Divider()
                Button("삭제…", systemImage: "trash", role: .destructive) {
                    isDeleteConfirmationPresented = true
                }
            } label: {
                Label("추가 작업", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func playbackCard(_ record: MacroLibraryRecord) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("실행 설정", systemImage: "play.circle")
                    .font(.headline)
                Spacer()
                playbackStatus
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("재생 속도")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("재생 속도", selection: $playbackRate) {
                        ForEach(PlaybackOptions.supportedRates, id: \.self) { rate in
                            Text(rateLabel(rate)).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 88)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("반복")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("반복 방식", selection: $repetitionMode) {
                        Text("횟수 지정").tag(RepetitionMode.finite)
                        Text("무한 반복").tag(RepetitionMode.infinite)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 155)
                }

                if repetitionMode == .finite {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("실행 횟수")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Stepper("\(repeatCount)회", value: $repeatCount, in: 1...9_999)
                            .frame(width: 96)
                    }
                }

                Spacer()

                if displayedPlayerState == .running {
                    Button(role: .destructive, action: player.stop) {
                        Label("실행 중지", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: .control)
                } else {
                    Button(action: { startPlayback(record.document) }) {
                        Label("매크로 실행", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(record.document.actions.isEmpty || store.isRecording)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(playbackSummary(for: record.document))
                Spacer()
                Text("중지: Control + Escape")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private func actionPreview(_ actions: [MacroAction]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("액션 미리보기")
                    .font(.headline)
                Spacer()
                Text("총 \(actions.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if actions.isEmpty {
                ContentUnavailableView(
                    "액션이 없습니다",
                    systemImage: "list.bullet.rectangle",
                    description: Text("편집 창에서 녹화하거나 액션을 추가해 주세요.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(actions.prefix(8).enumerated()), id: \.element.id) { index, action in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 24, alignment: .trailing)
                            Image(systemName: action.kind.systemImage)
                                .foregroundStyle(action.kind.tint)
                                .frame(width: 26, height: 26)
                                .background(action.kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(action.kind.displayName)
                                    .font(.callout.weight(.medium))
                                Text(action.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < min(actions.count, 8) - 1 { Divider().padding(.leading, 62) }
                    }
                    if actions.count > 8 {
                        Divider()
                        Text("외 \(actions.count - 8)개 액션")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                    }
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08))
                }
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("매크로 보관함", systemImage: "square.grid.2x2")
        } description: {
            Text("녹화하거나 직접 구성한 매크로를 이곳에서 저장하고 실행할 수 있습니다.")
        } actions: {
            Button(action: createMacro) {
                Label("새 매크로 만들기", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            Button("파일 가져오기…", action: importMacro)
        }
    }

    @ViewBuilder
    private var playbackStatus: some View {
        switch displayedPlayerState {
        case .running:
            Label("\(displayedIteration)번째 실행 중", systemImage: "play.circle.fill")
                .foregroundStyle(.indigo)
        case .completed:
            Label("실행 완료", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .stopped:
            Label("중지됨", systemImage: "stop.circle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Label("실행 실패", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .idle:
            Label("실행 준비", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var filteredRecords: [MacroLibraryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.records }
        return store.records.filter { $0.document.name.localizedCaseInsensitiveContains(query) }
    }

    private var activeErrorMessage: String? {
        if case .failed(let message) = previewState { return message }
        if case .failed(let message) = player.state { return message }
        return localErrorMessage ?? store.errorMessage ?? globalCommandMonitor.errorMessage
    }

    private var displayedPlayerState: InputPlayer.State {
        switch previewState {
        case .live: return player.state
        case .playing: return .running
        case .failed(let message): return .failed(message)
        }
    }

    private var displayedIteration: Int {
        if case .playing(let iteration) = previewState { return iteration }
        return player.currentIteration
    }

    private var playbackOptions: PlaybackOptions {
        PlaybackOptions(
            rate: playbackRate,
            repetition: repetitionMode == .infinite ? .infinite : .finite(repeatCount)
        )
    }

    private func createMacro() {
        guard let draft = store.beginNewDraft() else { return }
        openWindow(id: "macro-editor", value: draft.document.id)
    }

    private func edit(_ id: UUID) {
        guard let draft = store.beginEditing(id: id) else {
            openRecoverableDraft()
            return
        }
        openWindow(id: "macro-editor", value: draft.document.id)
    }

    private func openRecoverableDraft() {
        guard let id = store.recoverableDraft?.document.id else { return }
        openWindow(id: "macro-editor", value: id)
    }

    private func deleteSelectedMacro() {
        guard let id = store.selectedID else { return }
        player.stop()
        store.delete(id: id)
    }

    private func importMacro() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = store.importDocument(from: url)
    }

    private func exportSelectedMacro() {
        guard let record = store.selectedRecord else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFileName(record.document.name) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportDocument(id: record.id, to: url)
            localErrorMessage = nil
        } catch {
            localErrorMessage = "매크로를 내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func startPlayback(_ document: MacroDocument) {
        guard !store.isRecording else { return }
        guard permissions.accessibilityGranted else {
            permissions.openAccessibilitySettings()
            return
        }
        if document.actions.containsCaptureAction, !permissions.screenCaptureGranted {
            permissions.openScreenCaptureSettings()
            return
        }
        localErrorMessage = nil
        player.play(document: document, options: playbackOptions)
    }

    private func handleAppearance() {
        permissions.refresh()
        isDraftRecoveryPresented = store.recoverableDraft != nil
        startGlobalCommandMonitor()
        DispatchQueue.main.async {
            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func startGlobalCommandMonitor() {
        guard permissions.accessibilityGranted else { return }
        globalCommandMonitor.onCommand = { command in
            switch command {
            case .toggleRecording:
                guard displayedPlayerState != .running else { return false }
                if let draftID = store.recoverableDraft?.document.id,
                   store.openEditorDraftID == draftID {
                    NotificationCenter.default.post(name: .macroKnotToggleEditorRecording, object: nil)
                } else if let draft = store.beginNewDraft(startRecording: true) {
                    openWindow(id: "macro-editor", value: draft.document.id)
                } else {
                    return false
                }
                return true
            case .play:
                guard !store.isRecording, displayedPlayerState != .running,
                      let document = store.selectedRecord?.document,
                      !document.actions.isEmpty else { return false }
                startPlayback(document)
                return true
            }
        }
        globalCommandMonitor.start()
    }

    private func durationText(for document: MacroDocument) -> String {
        MacroDurationFormatter.concise(milliseconds: document.actions.estimatedDurationMilliseconds)
    }

    private func playbackSummary(for document: MacroDocument) -> String {
        let duration = Double(document.actions.estimatedDurationMilliseconds) / playbackRate
        let durationText = MacroDurationFormatter.concise(milliseconds: boundedMilliseconds(duration))
        if repetitionMode == .infinite { return "약 \(durationText)마다 계속 반복합니다." }
        if repeatCount == 1 { return "예상 실행 시간은 \(durationText)입니다." }
        let total = boundedMilliseconds(duration * Double(repeatCount))
        return "\(repeatCount)회 반복 · 예상 \(MacroDurationFormatter.concise(milliseconds: total))"
    }

    private func boundedMilliseconds(_ value: Double) -> UInt64 {
        guard value.isFinite, value < Double(UInt64.max) else { return .max }
        return UInt64(max(value.rounded(), 0))
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? String(format: "%.0f×", rate) : String(format: "%g×", rate)
    }

    private func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MacroEditorWindowView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @EnvironmentObject private var store: MacroLibraryStore
    @ObservedObject var permissions: PermissionState
    let draftID: UUID

    var body: some View {
        if let draft = store.recoverableDraft, draft.document.id == draftID {
            ContentView(
                permissions: permissions,
                initialDocument: draft.document,
                editorConfiguration: MacroEditorConfiguration(
                    startRecording: store.recordingRequestedForDraftID == draftID,
                    isPlaybackRunning: { store.isPlaybackRunning },
                    onRecordingRequestHandled: {
                        _ = store.consumeRecordingRequest(for: draftID)
                    },
                    onRecordingStateChanged: store.setRecording,
                    onDraftChanged: store.autosaveDraft,
                    onSave: { document in
                        try store.saveDraftToLibrary(document)
                        dismissWindow(id: "macro-editor", value: draftID)
                    },
                    onCancel: {
                        store.discardDraft()
                        dismissWindow(id: "macro-editor", value: draftID)
                    }
                )
            )
            .navigationTitle(draft.mode == .create ? "새 매크로" : "매크로 편집")
            .onAppear { store.editorDidOpen(draftID: draftID) }
            .onDisappear { store.editorDidClose(draftID: draftID) }
        } else {
            ContentUnavailableView(
                "초안을 찾을 수 없습니다",
                systemImage: "doc.questionmark",
                description: Text("이 창을 닫고 보관함에서 다시 시작해 주세요.")
            )
            .frame(minWidth: 700, minHeight: 500)
        }
    }
}

private enum RepetitionMode: String, CaseIterable {
    case finite
    case infinite
}

private struct LibraryRow: View {
    let record: MacroLibraryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.document.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("액션 \(record.document.actions.count)개")
                Text("·")
                Text(MacroDurationFormatter.concise(
                    milliseconds: record.document.actions.estimatedDurationMilliseconds
                ))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(record.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct LibraryFeedbackBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(tint.opacity(0.08))
    }
}
