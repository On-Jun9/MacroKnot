import AppKit
import MacroKnotCore
import SwiftUI
import UniformTypeIdentifiers

private enum DraftConflictIntent {
    case edit(UUID)
    case create
}

enum LibraryPlaybackPreviewState {
    case live
    case playing(iteration: Int, repeatCount: Int)
    case failed(String)
    case configured(rate: Double, repeatCount: Int)
}

struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var permissions: PermissionState
    @EnvironmentObject private var store: MacroLibraryStore
    @StateObject private var player = InputPlayer()
    @StateObject private var globalCommandMonitor = GlobalCommandMonitor()
    @State private var searchText = ""
    @State private var playbackRate = 1.0
    @State private var repetitionMode = RepetitionMode.once
    @State private var repeatCount = 1
    @State private var isDeleteConfirmationPresented = false
    @State private var isDraftRecoveryPresented = false
    @State private var isDraftConflictPresented = false
    @State private var draftConflictIntent: DraftConflictIntent?
    @State private var localErrorMessage: String?
    private let previewState: LibraryPlaybackPreviewState

    init(
        permissions: PermissionState,
        previewState: LibraryPlaybackPreviewState = .live
    ) {
        self.permissions = permissions
        self.previewState = previewState
        switch previewState {
        case .configured(let rate, let repeatCount):
            _playbackRate = State(initialValue: rate)
            _repetitionMode = State(initialValue: .finite)
            _repeatCount = State(initialValue: max(2, repeatCount))
        case .playing(_, let repeatCount):
            _repetitionMode = State(initialValue: .finite)
            _repeatCount = State(initialValue: max(2, repeatCount))
        case .live, .failed:
            break
        }
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
                exportMacro: store.selectedRecord == nil ? nil : exportSelectedMacro,
                closeWindow: {
                    NSApplication.shared.keyWindow?.performClose(nil)
                },
                duplicateActions: nil,
                deleteMacro: store.selectedRecord == nil
                    ? nil
                    : { isDeleteConfirmationPresented = true }
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
        .alert("다른 매크로의 초안이 있습니다", isPresented: $isDraftConflictPresented) {
            Button("기존 초안 계속 편집") {
                openRecoverableDraft()
                draftConflictIntent = nil
            }
            Button(
                isDraftConflictIntentCreate ? "초안 삭제 후 새로 만들기" : "초안 삭제 후 편집",
                role: .destructive
            ) {
                replaceDraftAndOpenPendingEditor()
            }
            Button("취소", role: .cancel) {
                draftConflictIntent = nil
            }
        } message: {
            Text(
                isDraftConflictIntentCreate
                    ? "새 매크로를 만들려면 현재 저장되지 않은 초안을 먼저 삭제해야 합니다."
                    : "선택한 매크로를 편집하려면 현재 저장되지 않은 초안을 먼저 삭제해야 합니다."
            )
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
                List(selection: $store.selectedID) {
                    ForEach(
                        Array(filteredRecords.enumerated()),
                        id: \.element.id
                    ) { index, record in
                        let insets = EdgeInsets(
                            top: index == 0 ? 14 : 5,
                            leading: 14,
                            bottom: index == filteredRecords.count - 1 ? 14 : 5,
                            trailing: 14
                        )
                        LibraryRow(record: record)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .tag(record.id)
                            .listRowSeparator(.hidden)
                            .listRowInsets(insets)
                            .listRowBackground(
                                libraryRowCard(
                                    isSelected: store.selectedID == record.id,
                                    insets: insets
                                )
                            )
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first {
                        Button("편집", systemImage: "pencil") { edit(id) }
                        Button("복제", systemImage: "plus.square.on.square") {
                            _ = store.duplicate(id: id)
                        }
                        Divider()
                        Button("삭제", systemImage: "trash", role: .destructive) {
                            store.selectedID = id
                            isDeleteConfirmationPresented = true
                        }
                    }
                } primaryAction: { ids in
                    if let id = ids.first { edit(id) }
                }
                .accessibilityLabel("저장된 매크로 목록")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("실행 설정")
                    .font(.headline)
                playbackStatus
                Spacer()

                if displayedPlayerState == .running {
                    Button(role: .destructive, action: player.stop) {
                        Label("실행 중지", systemImage: "stop.fill")
                            .frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: .control)
                } else {
                    Button(action: { startPlayback(record.document) }) {
                        Label("실행 시작", systemImage: "play.fill")
                            .frame(minWidth: 84)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(record.document.actions.isEmpty || store.isRecording)
                }
            }

            HStack(spacing: 10) {
                Text("재생 속도")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                HStack(spacing: 3) {
                    ForEach(PlaybackOptions.supportedRates, id: \.self) { rate in
                        CompactChoiceButton(
                            title: rateLabel(rate),
                            isSelected: playbackRate == rate
                        ) {
                            withAnimation(.easeOut(duration: 0.14)) {
                                playbackRate = rate
                            }
                        }
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity)
                .disabled(isPlaybackRunning)
                .opacity(isPlaybackRunning ? 0.55 : 1)
            }

            HStack(spacing: 10) {
                Text("반복")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                HStack(spacing: 3) {
                    CompactChoiceButton(
                        title: "한 번",
                        isSelected: repetitionMode == .once
                    ) {
                        withAnimation(.easeOut(duration: 0.14)) {
                            repetitionMode = .once
                            repeatCount = 1
                        }
                    }
                    CompactChoiceButton(
                        title: "횟수 반복",
                        isSelected: repetitionMode == .finite
                    ) {
                        withAnimation(.easeOut(duration: 0.14)) {
                            repetitionMode = .finite
                            repeatCount = max(repeatCount, 2)
                        }
                    }
                    CompactChoiceButton(
                        title: "무한 반복",
                        isSelected: repetitionMode == .infinite
                    ) {
                        withAnimation(.easeOut(duration: 0.14)) {
                            repetitionMode = .infinite
                        }
                    }
                }
                .padding(3)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                .disabled(isPlaybackRunning)
                .opacity(isPlaybackRunning ? 0.55 : 1)

                if repetitionMode == .finite {
                    HStack(spacing: 0) {
                        Button {
                            repeatCount = max(2, repeatCount - 1)
                        } label: {
                            Image(systemName: "minus")
                                .frame(width: 28, height: 28)
                        }
                        .disabled(repeatCount <= 2)

                        TextField("반복 횟수", value: $repeatCount, format: .number)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .frame(width: 44)
                            .onSubmit {
                                repeatCount = min(max(2, repeatCount), 9_999)
                            }

                        Button {
                            repeatCount = min(9_999, repeatCount + 1)
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 28, height: 28)
                        }
                        .disabled(repeatCount >= 9_999)
                    }
                    .buttonStyle(.plain)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    .disabled(isPlaybackRunning)
                    .opacity(isPlaybackRunning ? 0.55 : 1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "clock")
                Text(playbackSummary(for: record.document))
                Spacer()
                Image(systemName: "escape")
                Text("중지: Control + Escape")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        }
    }

    private func actionPreview(_ actions: [MacroAction]) -> some View {
        let previewItems = MacroActionPreviewItem.grouped(actions)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("액션 미리보기")
                    .font(.headline)
                Spacer()
                Text(previewCountText(actionCount: actions.count, itemCount: previewItems.count))
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
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Text(item.sourceLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 42, alignment: .trailing)
                            Image(systemName: item.kind.systemImage)
                                .foregroundStyle(item.kind.tint)
                                .frame(width: 26, height: 26)
                                .background(item.kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.callout.weight(.medium))
                                Text(item.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if index < previewItems.count - 1 { Divider().padding(.leading, 80) }
                    }
                }
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08))
                }
            }
        }
    }

    private func previewCountText(actionCount: Int, itemCount: Int) -> String {
        guard actionCount != itemCount else { return "총 \(actionCount)개" }
        return "\(actionCount)개 액션 · \(itemCount)단계로 정리"
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
        case .live, .configured: return player.state
        case .playing: return .running
        case .failed(let message): return .failed(message)
        }
    }

    private var isPlaybackRunning: Bool {
        displayedPlayerState == .running
    }

    private var displayedIteration: Int {
        if case .playing(let iteration, _) = previewState { return iteration }
        return player.currentIteration
    }

    private var playbackOptions: PlaybackOptions {
        let repetition: PlaybackOptions.Repetition
        switch repetitionMode {
        case .once:
            repetition = .finite(1)
        case .finite:
            repetition = .finite(max(2, repeatCount))
        case .infinite:
            repetition = .infinite
        }
        return PlaybackOptions(
            rate: playbackRate,
            repetition: repetition
        )
    }

    // macOS List의 자체 선택 강조는 listRowBackground 아래에 그려지므로
    // 행 전체를 사이드바와 같은 재질로 덮은 뒤 그 위에 카드를 그려 가린다.
    private func libraryRowCard(isSelected: Bool, insets: EdgeInsets) -> some View {
        ZStack {
            // 불투명층이 List의 네이티브 선택 강조를 차단하고,
            // 그 위 material이 사이드바와 같은 색감을 유지한다.
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
            Rectangle()
                .fill(.thinMaterial)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if isSelected {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.10))
                }
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? Color.accentColor.opacity(0.28)
                            : Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: 1
                    )
            }
            .padding(insets)
        }
    }

    private var isDraftConflictIntentCreate: Bool {
        if case .create = draftConflictIntent { return true }
        return false
    }

    private func createMacro() {
        if let draft = store.recoverableDraft {
            // 새 매크로 초안이 이미 있으면 그 편집 창을 그대로 연다.
            if draft.mode == .create {
                openWindow(id: "macro-editor", value: draft.document.id)
                return
            }
            guard store.discardDraftIfNothingWouldBeLost() else {
                draftConflictIntent = .create
                isDraftConflictPresented = true
                return
            }
            dismissWindow(id: "macro-editor", value: draft.document.id)
        }
        guard let draft = store.beginNewDraft() else { return }
        openWindow(id: "macro-editor", value: draft.document.id)
    }

    private func edit(_ id: UUID) {
        if let draft = store.recoverableDraft, draft.document.id != id {
            guard store.discardDraftIfNothingWouldBeLost() else {
                draftConflictIntent = .edit(id)
                isDraftConflictPresented = true
                return
            }
            dismissWindow(id: "macro-editor", value: draft.document.id)
        }
        guard let draft = store.beginEditing(id: id) else {
            localErrorMessage = "선택한 매크로를 편집할 수 없습니다. 보관함을 새로고침해 주세요."
            return
        }
        openWindow(id: "macro-editor", value: draft.document.id)
    }

    private func replaceDraftAndOpenPendingEditor() {
        let intent = draftConflictIntent
        draftConflictIntent = nil
        if let oldDraftID = store.recoverableDraft?.document.id {
            dismissWindow(id: "macro-editor", value: oldDraftID)
        }
        store.discardDraft()
        switch intent {
        case .edit(let id):
            guard let draft = store.beginEditing(id: id) else {
                localErrorMessage = "선택한 매크로를 편집할 수 없습니다."
                return
            }
            openWindow(id: "macro-editor", value: draft.document.id)
        case .create:
            guard let draft = store.beginNewDraft() else { return }
            openWindow(id: "macro-editor", value: draft.document.id)
        case nil:
            break
        }
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
        // 편집 창이 열려 있으면 그 창이 초안을 쓰고 있으므로 건드리지 않는다.
        if store.openEditorDraftID == nil {
            isDraftRecoveryPresented = !store.discardDraftIfNothingWouldBeLost()
        } else {
            isDraftRecoveryPresented = false
        }
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
        if repetitionMode == .once { return "예상 실행 시간은 \(durationText)입니다." }
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MacroLibraryStore
    @ObservedObject var permissions: PermissionState
    @State private var isClosing = false
    let draftID: UUID

    var body: some View {
        if isClosing {
            Color.clear
                .frame(minWidth: 700, minHeight: 500)
        } else if let draft = store.recoverableDraft, draft.document.id == draftID {
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
                    shouldConfirmCancel: { document in
                        MacroEditorCancelPolicy.requiresConfirmation(
                            mode: draft.mode,
                            current: document,
                            original: store.records
                                .first { $0.id == draft.document.id }?
                                .document
                        )
                    },
                    onSave: { document in
                        isClosing = true
                        do {
                            try store.saveDraftToLibrary(document)
                            closeEditorWindow()
                        } catch {
                            isClosing = false
                            throw error
                        }
                    },
                    onCancel: {
                        isClosing = true
                        store.discardDraft()
                        closeEditorWindow()
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
            .onAppear {
                // 창 상태 복원으로 초안 없이 되살아난 편집 창은 스스로 닫는다.
                closeEditorWindow()
            }
        }
    }

    private func closeEditorWindow() {
        isClosing = true
        // 취소 확인 알림창의 버튼 액션 안에서 동기적으로 창을 닫으면
        // 알림창 해제와 같은 업데이트에 섞여 창 닫기가 무시되므로 한 틱 미룬다.
        DispatchQueue.main.async {
            dismiss()
        }
    }
}

private enum RepetitionMode: String, CaseIterable {
    case once
    case finite
    case infinite
}

struct CompactChoiceButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color(nsColor: .windowBackgroundColor) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .shadow(
                    color: isSelected ? Color.black.opacity(0.10) : .clear,
                    radius: 2,
                    y: 1
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LibraryRow: View {
    let record: MacroLibraryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 선택된 행은 List가 글자색을 흰색 강조로 바꾸는데, 배경은 커스텀
            // 카드라서 명시적 라벨 색으로 고정해 선택과 무관하게 유지한다.
            Text(record.document.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(Color(nsColor: .labelColor))
            HStack(spacing: 6) {
                Text("액션 \(record.document.actions.count)개")
                Text("·")
                Text(MacroDurationFormatter.concise(
                    milliseconds: record.document.actions.estimatedDurationMilliseconds
                ))
            }
            .font(.caption)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            Text(record.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
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
