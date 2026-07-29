import AppKit
import MacroKnotCore
import UniformTypeIdentifiers

@MainActor
final class DocumentController: ObservableObject {
    @Published var document = MacroDocument(name: "새 매크로")
    @Published private(set) var currentURL: URL?
    @Published private(set) var errorMessage: String?

    var windowTitle: String {
        currentURL?.deletingPathExtension().lastPathComponent ?? document.name
    }

    func newDocument() {
        document = MacroDocument(name: "새 매크로")
        currentURL = nil
        errorMessage = nil
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            document = try MacroDocumentCodec.load(from: url)
            currentURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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
        document.actions.append(contentsOf: actions)
    }

    func addWaitAction(milliseconds: UInt64 = 1_000) {
        document.actions.append(.wait(milliseconds: milliseconds))
    }

    func removeAction(id: UUID) {
        document.actions.removeAll { $0.id == id }
    }

    func moveAction(id: UUID, offset: Int) {
        guard let source = document.actions.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard document.actions.indices.contains(destination) else { return }
        document.actions.swapAt(source, destination)
    }

    private func save(to url: URL) {
        do {
            try MacroDocumentCodec.save(document, to: url)
            currentURL = url
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func suggestedFileName() -> String {
        let trimmed = document.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "새 매크로" : trimmed
        return "\(base).json"
    }
}
