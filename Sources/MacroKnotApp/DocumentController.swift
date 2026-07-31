import AppKit
import MacroKnotCore
import UniformTypeIdentifiers

@MainActor
final class DocumentController: ObservableObject {
    @Published var document = MacroDocument(name: "새 매크로")
    @Published private(set) var currentURL: URL?
    @Published private(set) var errorMessage: String?
    // 다른 앱의 복사로 pasteboard가 교체될 수 있으므로 캐시하지 않고 실시간으로 조회한다.
    var canPasteActions: Bool {
        ActionPasteboard.containsActions(in: pasteboard)
    }

    /// 편집 창의 `\.undoManager`를 그대로 사용한다.
    weak var undoManager: UndoManager?
    /// 녹화 중에는 문서를 바꾸는 조작을 실행 취소 기록에 남기지 않는다.
    var isRecordingInProgress = false

    private let pasteboard: NSPasteboard

    init(
        initialDocument: MacroDocument? = nil,
        pasteboard: NSPasteboard = .general
    ) {
        self.pasteboard = pasteboard
        if let initialDocument {
            document = initialDocument
        } else {
            document.displayConfiguration = DisplayConfigurationProvider.current()
        }
    }

    var windowTitle: String {
        currentURL?.deletingPathExtension().lastPathComponent ?? document.name
    }

    func newDocument() {
        document = MacroDocument(name: "새 매크로")
        document.displayConfiguration = DisplayConfigurationProvider.current()
        currentURL = nil
        errorMessage = nil
        RuntimeEventLogger.record("document_created", result: "PASS")
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            document = try MacroDocumentCodec.loadForEditing(from: url)
            currentURL = url
            do {
                try document.validate()
                errorMessage = nil
                logDocumentOpened(url: url, result: "PASS")
            } catch {
                errorMessage = error.localizedDescription
                logDocumentOpened(
                    url: url,
                    result: "FAIL",
                    error: error.localizedDescription
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            RuntimeEventLogger.record(
                "document_opened",
                result: "FAIL",
                fields: ["error": error.localizedDescription]
            )
        }
    }

    func saveDocument() {
        if let currentURL {
            save(to: currentURL)
        } else {
            saveDocumentAs()
        }
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url)
    }

    func appendRecordedActions(_ actions: [MacroAction]) {
        guard !actions.isEmpty else { return }
        registerUndoSnapshot(actionName: "녹화 액션 추가")
        ensureDisplayConfiguration(for: actions)
        document.actions.append(contentsOf: actions)
    }

    func addWaitAction(milliseconds: UInt64 = 1_000) {
        registerUndoSnapshot(actionName: "액션 추가")
        document.actions.append(.wait(milliseconds: milliseconds))
    }

    func addAction(_ action: MacroAction) {
        registerUndoSnapshot(actionName: "액션 추가")
        ensureDisplayConfiguration(for: [action])
        document.actions.append(action)
        errorMessage = nil
        logActionChange("action_added", action: action)
    }

    func updateAction(_ action: MacroAction) {
        guard let index = document.actions.firstIndex(where: { $0.id == action.id }) else {
            return
        }
        registerUndoSnapshot(actionName: "액션 편집")
        document.actions[index] = action
        ensureDisplayConfiguration(for: document.actions)
        errorMessage = nil
        logActionChange("action_updated", action: action)
    }

    func wrapActionsInRepeat(from startIndex: Int, through endIndex: Int, count: Int) throws {
        guard count > 0,
              startIndex >= 0,
              endIndex >= startIndex,
              document.actions.indices.contains(startIndex),
              document.actions.indices.contains(endIndex) else {
            throw ActionEditingError.invalidRepeatRange
        }
        let selected = Array(document.actions[startIndex...endIndex])
        let repeatAction = MacroAction.repeatBlock(count: count, actions: selected)
        try repeatAction.validate()
        registerUndoSnapshot(actionName: "범위 반복 묶기")
        document.actions.replaceSubrange(startIndex...endIndex, with: [repeatAction])
        errorMessage = nil
        RuntimeEventLogger.record(
            "repeat_range_created",
            result: "PASS",
            fields: [
                "action_count": String(selected.count),
                "repeat_count": String(count),
            ]
        )
    }

    func validationMessage(for action: MacroAction) -> String? {
        do {
            try action.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeAction(id: UUID) {
        let removedKind = document.actions.first(where: { $0.id == id })?.kind.rawValue
        registerUndoSnapshot(actionName: "액션 삭제")
        document.actions.removeAll { $0.id == id }
        RuntimeEventLogger.record(
            "action_removed",
            result: "PASS",
            fields: ["kind": removedKind ?? "unknown"]
        )
    }

    func removeActions(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if ids.count == 1, let id = ids.first {
            removeAction(id: id)
            return
        }
        let removedActions = document.actions.filter { ids.contains($0.id) }
        guard !removedActions.isEmpty else { return }
        registerUndoSnapshot(actionName: "액션 삭제")
        document.actions.removeAll { ids.contains($0.id) }
        RuntimeEventLogger.record(
            "actions_removed",
            result: "PASS",
            fields: [
                "action_count": String(removedActions.count),
                "kinds": removedActions.map { $0.kind.rawValue }.joined(separator: ","),
            ]
        )
    }

    func removeAllActions() {
        guard !document.actions.isEmpty else { return }
        let removedCount = document.actions.count
        registerUndoSnapshot(actionName: "모든 액션 삭제")
        document.actions.removeAll()
        errorMessage = nil
        RuntimeEventLogger.record(
            "actions_cleared",
            result: "PASS",
            fields: ["action_count": String(removedCount)]
        )
    }

    func moveAction(id: UUID, offset: Int) {
        guard let source = document.actions.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard document.actions.indices.contains(destination) else { return }
        registerUndoSnapshot(actionName: "액션 순서 변경")
        document.actions.swapAt(source, destination)
        RuntimeEventLogger.record(
            "action_moved",
            result: "PASS",
            fields: ["from": String(source + 1), "to": String(destination + 1)]
        )
    }

    func moveActions(fromOffsets: IndexSet, toOffset: Int) {
        let validOffsets = fromOffsets.filter { document.actions.indices.contains($0) }
        guard !validOffsets.isEmpty,
              (0...document.actions.count).contains(toOffset) else { return }

        let movedActions = validOffsets.map { document.actions[$0] }
        registerUndoSnapshot(actionName: "액션 순서 변경")
        for index in validOffsets.reversed() {
            document.actions.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.count { $0 < toOffset }
        let insertionIndex = min(
            max(toOffset - removedBeforeDestination, 0),
            document.actions.endIndex
        )
        document.actions.insert(contentsOf: movedActions, at: insertionIndex)
        RuntimeEventLogger.record(
            "actions_reordered",
            result: "PASS",
            fields: [
                "action_count": String(movedActions.count),
                "destination": String(insertionIndex + 1),
            ]
        )
    }

    func copyActions(ids: Set<UUID>) {
        let copied = document.actions.filter { ids.contains($0.id) }
        guard !copied.isEmpty,
              ActionPasteboard.write(copied, to: pasteboard) else { return }
        RuntimeEventLogger.record(
            "actions_copied",
            result: "PASS",
            fields: ["action_count": String(copied.count)]
        )
    }

    /// 붙여넣은 액션의 식별자를 돌려준다. 붙여넣을 내용이 없으면 빈 배열이다.
    @discardableResult
    func pasteActions(after ids: Set<UUID>) -> [UUID] {
        let pasted = ActionPasteboard.read(from: pasteboard).map { $0.withNewIdentifiers() }
        guard !pasted.isEmpty else { return [] }
        insertCopies(pasted, after: ids, actionName: "액션 붙여넣기")
        RuntimeEventLogger.record(
            "actions_pasted",
            result: "PASS",
            fields: ["action_count": String(pasted.count)]
        )
        return pasted.map(\.id)
    }

    /// 복제한 액션의 식별자를 돌려준다. 선택이 비어 있으면 빈 배열이다.
    @discardableResult
    func duplicateActions(ids: Set<UUID>) -> [UUID] {
        let duplicated = document.actions
            .filter { ids.contains($0.id) }
            .map { $0.withNewIdentifiers() }
        guard !duplicated.isEmpty else { return [] }
        insertCopies(duplicated, after: ids, actionName: "액션 복제")
        RuntimeEventLogger.record(
            "actions_duplicated",
            result: "PASS",
            fields: ["action_count": String(duplicated.count)]
        )
        return duplicated.map(\.id)
    }

    private func insertCopies(
        _ copies: [MacroAction],
        after ids: Set<UUID>,
        actionName: String
    ) {
        let lastSelectedIndex = document.actions.lastIndex { ids.contains($0.id) }
        let insertionIndex = lastSelectedIndex.map { $0 + 1 } ?? document.actions.endIndex
        registerUndoSnapshot(actionName: actionName)
        ensureDisplayConfiguration(for: copies)
        document.actions.insert(contentsOf: copies, at: insertionIndex)
        errorMessage = nil
    }

    /// 변경 직전 액션 상태를 실행 취소로 등록한다.
    /// 복원 메서드가 복원 직전 상태를 다시 등록하므로 재실행도 같은 경로로 성립한다.
    private func registerUndoSnapshot(actionName: String) {
        guard !isRecordingInProgress else { return }
        pushUndoSnapshot(actionName: actionName)
    }

    private func pushUndoSnapshot(actionName: String) {
        guard let undoManager else { return }
        let snapshot = ActionsSnapshot(
            actions: document.actions,
            displayConfiguration: document.displayConfiguration
        )
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.restore(snapshot, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    /// 매크로 이름은 실행 취소 대상이 아니므로 스냅샷에서 되돌리지 않는다.
    private func restore(_ snapshot: ActionsSnapshot, actionName: String) {
        pushUndoSnapshot(actionName: actionName)
        document.actions = snapshot.actions
        document.displayConfiguration = snapshot.displayConfiguration
        errorMessage = nil
    }

    private func save(to url: URL) {
        do {
            try MacroDocumentCodec.save(document, to: url)
            currentURL = url
            errorMessage = nil
            RuntimeEventLogger.record(
                "document_saved",
                result: "PASS",
                fields: [
                    "action_count": String(document.actions.count),
                    "file": url.lastPathComponent,
                ]
            )
        } catch {
            errorMessage = error.localizedDescription
            RuntimeEventLogger.record(
                "document_saved",
                result: "FAIL",
                fields: ["error": error.localizedDescription]
            )
        }
    }

    private func ensureDisplayConfiguration(for actions: [MacroAction]) {
        guard actions.contains(where: \.containsCoordinateActions),
              document.displayConfiguration == nil else { return }
        document.displayConfiguration = DisplayConfigurationProvider.current()
    }

    private func logActionChange(_ event: String, action: MacroAction) {
        RuntimeEventLogger.record(
            event,
            result: "PASS",
            fields: ["kind": action.kind.rawValue]
        )
    }

    private func logDocumentOpened(
        url: URL,
        result: String,
        error: String? = nil
    ) {
        var fields = [
            "action_count": String(document.actions.count),
            "file": url.lastPathComponent,
        ]
        fields["error"] = error
        RuntimeEventLogger.record("document_opened", result: result, fields: fields)
    }

    private func suggestedFileName() -> String {
        let trimmed = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "새 매크로" : trimmed
        return "\(base).json"
    }
}

private struct ActionsSnapshot: Sendable {
    let actions: [MacroAction]
    let displayConfiguration: DisplayConfiguration?
}

extension MacroAction {
    /// 붙여넣기·복제로 만든 액션이 원본과 같은 식별자를 쓰지 않게 한다.
    fileprivate func withNewIdentifiers() -> MacroAction {
        var copy = self
        copy.id = UUID()
        if var repeatPayload = copy.repeatBlock {
            repeatPayload.actions = repeatPayload.actions.map { $0.withNewIdentifiers() }
            copy.repeatBlock = repeatPayload
        }
        return copy
    }
}

enum ActionEditingError: LocalizedError {
    case invalidRepeatRange

    var errorDescription: String? {
        "반복할 액션 범위와 횟수를 확인하십시오."
    }
}
