import AppKit
import MacroKnotCore
import UniformTypeIdentifiers

@MainActor
final class DocumentController: ObservableObject {
    @Published var document = MacroDocument(name: "새 매크로")
    @Published private(set) var currentURL: URL?
    @Published private(set) var errorMessage: String?

    init(initialDocument: MacroDocument? = nil) {
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
        ensureDisplayConfiguration(for: actions)
        document.actions.append(contentsOf: actions)
    }

    func addWaitAction(milliseconds: UInt64 = 1_000) {
        document.actions.append(.wait(milliseconds: milliseconds))
    }

    func addAction(_ action: MacroAction) {
        ensureDisplayConfiguration(for: [action])
        document.actions.append(action)
        errorMessage = nil
        logActionChange("action_added", action: action)
    }

    func updateAction(_ action: MacroAction) {
        guard let index = document.actions.firstIndex(where: { $0.id == action.id }) else {
            return
        }
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

enum ActionEditingError: LocalizedError {
    case invalidRepeatRange

    var errorDescription: String? {
        "반복할 액션 범위와 횟수를 확인하십시오."
    }
}
