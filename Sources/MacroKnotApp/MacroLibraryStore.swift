import Combine
import Foundation
import MacroKnotCore

struct MacroLibraryRecord: Codable, Equatable, Identifiable, Sendable {
    static let currentStorageVersion = 1

    var storageVersion = Self.currentStorageVersion
    var document: MacroDocument
    var createdAt: Date
    var modifiedAt: Date

    var id: UUID { document.id }
}

struct MacroDraftRecord: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case create
        case edit
    }

    static let currentStorageVersion = 1
    static let defaultName = "새 매크로"

    var storageVersion = Self.currentStorageVersion
    var mode: Mode
    var document: MacroDocument
    var originalCreatedAt: Date?
    var updatedAt: Date
}

struct MacroLibraryLoadResult {
    var records: [MacroLibraryRecord]
    var failures: [String]
}

struct MacroLibraryStorage {
    let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = URL.applicationSupportDirectory
            .appending(path: "MacroKnot", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    var libraryURL: URL {
        rootURL.appending(path: "Library", directoryHint: .isDirectory)
    }

    var draftsURL: URL {
        rootURL.appending(path: "Drafts", directoryHint: .isDirectory)
    }

    var currentDraftURL: URL {
        draftsURL.appending(path: "current.json", directoryHint: .notDirectory)
    }

    func loadLibrary() throws -> MacroLibraryLoadResult {
        try prepareDirectories()
        let urls = try fileManager.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var records: [MacroLibraryRecord] = []
        var failures: [String] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            do {
                let record = try decoder.decode(
                    MacroLibraryRecord.self,
                    from: Data(contentsOf: url)
                )
                guard record.storageVersion == MacroLibraryRecord.currentStorageVersion,
                      record.id.uuidString == url.deletingPathExtension().lastPathComponent else {
                    throw MacroLibraryStorageError.invalidRecord(url.lastPathComponent)
                }
                try record.document.validate()
                records.append(record)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        records.sort {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.document.name.localizedStandardCompare($1.document.name) == .orderedAscending
        }
        return MacroLibraryLoadResult(records: records, failures: failures)
    }

    func save(_ record: MacroLibraryRecord) throws {
        try prepareDirectories()
        guard record.storageVersion == MacroLibraryRecord.currentStorageVersion else {
            throw MacroLibraryStorageError.unsupportedStorageVersion(record.storageVersion)
        }
        try record.document.validate()
        try encoder.encode(record).write(to: recordURL(for: record.id), options: .atomic)
    }

    func delete(id: UUID) throws {
        let url = recordURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func loadDraft() throws -> MacroDraftRecord? {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: currentDraftURL.path) else { return nil }
        let draft = try decoder.decode(
            MacroDraftRecord.self,
            from: Data(contentsOf: currentDraftURL)
        )
        guard draft.storageVersion == MacroDraftRecord.currentStorageVersion else {
            throw MacroLibraryStorageError.unsupportedStorageVersion(draft.storageVersion)
        }
        return draft
    }

    func saveDraft(_ draft: MacroDraftRecord) throws {
        try prepareDirectories()
        guard draft.storageVersion == MacroDraftRecord.currentStorageVersion else {
            throw MacroLibraryStorageError.unsupportedStorageVersion(draft.storageVersion)
        }
        try encoder.encode(draft).write(to: currentDraftURL, options: .atomic)
    }

    func deleteDraft() throws {
        guard fileManager.fileExists(atPath: currentDraftURL.path) else { return }
        try fileManager.removeItem(at: currentDraftURL)
    }

    private func recordURL(for id: UUID) -> URL {
        libraryURL.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: draftsURL, withIntermediateDirectories: true)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
final class MacroLibraryStore: ObservableObject {
    @Published private(set) var records: [MacroLibraryRecord] = []
    @Published var selectedID: UUID?
    @Published private(set) var recoverableDraft: MacroDraftRecord?
    @Published private(set) var errorMessage: String?
    @Published private(set) var recordingRequestedForDraftID: UUID?
    @Published private(set) var openEditorDraftID: UUID?
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaybackRunning = false

    private let storage: MacroLibraryStorage
    private let now: () -> Date

    init(
        storage: MacroLibraryStorage = MacroLibraryStorage(),
        now: @escaping () -> Date = Date.init
    ) {
        self.storage = storage
        self.now = now
        reload()
        loadRecoverableDraft()
    }

    init(
        previewRecords: [MacroLibraryRecord],
        selectedID: UUID? = nil,
        recoverableDraft: MacroDraftRecord? = nil,
        errorMessage: String? = nil
    ) {
        storage = MacroLibraryStorage(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "MacroKnotPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
        )
        now = Date.init
        records = previewRecords
        self.selectedID = selectedID ?? previewRecords.first?.id
        self.recoverableDraft = recoverableDraft
        self.errorMessage = errorMessage
    }

    var selectedRecord: MacroLibraryRecord? {
        guard let selectedID else { return nil }
        return records.first { $0.id == selectedID }
    }

    @discardableResult
    func beginNewDraft(startRecording: Bool = false) -> MacroDraftRecord? {
        if let recoverableDraft {
            if startRecording {
                recordingRequestedForDraftID = recoverableDraft.document.id
            }
            return recoverableDraft
        }
        let timestamp = now()
        let draft = MacroDraftRecord(
            mode: .create,
            document: MacroDocument(name: MacroDraftRecord.defaultName),
            originalCreatedAt: timestamp,
            updatedAt: timestamp
        )
        let result = persistNewDraft(draft)
        if startRecording {
            recordingRequestedForDraftID = result?.document.id
        }
        return result
    }

    @discardableResult
    func beginEditing(id: UUID) -> MacroDraftRecord? {
        if let recoverableDraft {
            return recoverableDraft.document.id == id ? recoverableDraft : nil
        }
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        let draft = MacroDraftRecord(
            mode: .edit,
            document: record.document,
            originalCreatedAt: record.createdAt,
            updatedAt: now()
        )
        return persistNewDraft(draft)
    }

    func autosaveDraft(_ document: MacroDocument) {
        guard var draft = recoverableDraft, draft.document.id == document.id else { return }
        draft.document = document
        draft.updatedAt = now()
        do {
            try storage.saveDraft(draft)
            recoverableDraft = draft
            errorMessage = nil
        } catch {
            errorMessage = "초안을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveDraftToLibrary(_ document: MacroDocument) throws {
        guard let draft = recoverableDraft, draft.document.id == document.id else {
            throw MacroLibraryStorageError.draftNotFound
        }
        try document.validate()
        let timestamp = now()
        let createdAt = draft.originalCreatedAt
            ?? records.first(where: { $0.id == document.id })?.createdAt
            ?? timestamp
        try storage.save(
            MacroLibraryRecord(
                document: document,
                createdAt: createdAt,
                modifiedAt: timestamp
            )
        )
        try storage.deleteDraft()
        recoverableDraft = nil
        recordingRequestedForDraftID = nil
        reload(selecting: document.id)
    }

    /// 삭제해도 잃을 내용이 없는 초안이면 조용히 정리한다.
    /// 정리했거나 초안이 없으면 true, 실제 내용이 있어 확인이 필요하면 false.
    func discardDraftIfNothingWouldBeLost() -> Bool {
        guard let draft = recoverableDraft else { return true }
        let original = records.first { $0.id == draft.document.id }?.document
        if MacroEditorCancelPolicy.requiresConfirmation(
            mode: draft.mode,
            current: draft.document,
            original: original
        ) {
            return false
        }
        discardDraft()
        return true
    }

    func discardDraft() {
        do {
            try storage.deleteDraft()
            recoverableDraft = nil
            recordingRequestedForDraftID = nil
            errorMessage = nil
        } catch {
            errorMessage = "초안을 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func delete(id: UUID) {
        do {
            try storage.delete(id: id)
            reload(selecting: selectedID == id ? nil : selectedID)
        } catch {
            errorMessage = "매크로를 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func duplicate(id: UUID) -> UUID? {
        guard let source = records.first(where: { $0.id == id }) else { return nil }
        var document = source.document
        document.id = UUID()
        document.name = "\(source.document.name) 복사본"
        let timestamp = now()
        do {
            try storage.save(
                MacroLibraryRecord(
                    document: document,
                    createdAt: timestamp,
                    modifiedAt: timestamp
                )
            )
            reload(selecting: document.id)
            return document.id
        } catch {
            errorMessage = "매크로를 복제하지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func importDocument(from url: URL) -> UUID? {
        do {
            var document = try MacroDocumentCodec.load(from: url)
            if records.contains(where: { $0.id == document.id }) {
                document.id = UUID()
            }
            let timestamp = now()
            try storage.save(
                MacroLibraryRecord(
                    document: document,
                    createdAt: timestamp,
                    modifiedAt: timestamp
                )
            )
            reload(selecting: document.id)
            return document.id
        } catch {
            errorMessage = "매크로를 가져오지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    func exportDocument(id: UUID, to url: URL) throws {
        guard let record = records.first(where: { $0.id == id }) else {
            throw MacroLibraryStorageError.recordNotFound
        }
        try MacroDocumentCodec.save(record.document, to: url)
    }

    func clearError() {
        errorMessage = nil
    }

    func consumeRecordingRequest(for draftID: UUID) -> Bool {
        guard recordingRequestedForDraftID == draftID else { return false }
        recordingRequestedForDraftID = nil
        return true
    }

    func editorDidOpen(draftID: UUID) {
        openEditorDraftID = draftID
    }

    func editorDidClose(draftID: UUID) {
        if openEditorDraftID == draftID {
            openEditorDraftID = nil
        }
    }

    func setRecording(_ isRecording: Bool) {
        self.isRecording = isRecording
    }

    func setPlaybackRunning(_ isPlaybackRunning: Bool) {
        self.isPlaybackRunning = isPlaybackRunning
    }

    private func persistNewDraft(_ draft: MacroDraftRecord) -> MacroDraftRecord? {
        do {
            try storage.saveDraft(draft)
            recoverableDraft = draft
            errorMessage = nil
            return draft
        } catch {
            errorMessage = "초안을 만들지 못했습니다: \(error.localizedDescription)"
            return nil
        }
    }

    private func reload(selecting requestedID: UUID? = nil) {
        do {
            let result = try storage.loadLibrary()
            records = result.records
            let candidate = requestedID ?? selectedID
            selectedID = candidate.flatMap { id in records.contains(where: { $0.id == id }) ? id : nil }
                ?? records.first?.id
            errorMessage = result.failures.isEmpty
                ? nil
                : "읽지 못한 보관함 파일이 있습니다: \(result.failures.joined(separator: "; "))"
        } catch {
            records = []
            selectedID = nil
            errorMessage = "보관함을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func loadRecoverableDraft() {
        do {
            recoverableDraft = try storage.loadDraft()
        } catch {
            errorMessage = "임시 초안을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }
}

enum MacroLibraryStorageError: LocalizedError {
    case unsupportedStorageVersion(Int)
    case invalidRecord(String)
    case recordNotFound
    case draftNotFound

    var errorDescription: String? {
        switch self {
        case .unsupportedStorageVersion(let version):
            return "지원하지 않는 보관함 형식 버전입니다: \(version)"
        case .invalidRecord(let name):
            return "보관함 파일 정보가 올바르지 않습니다: \(name)"
        case .recordNotFound:
            return "선택한 매크로를 찾지 못했습니다."
        case .draftNotFound:
            return "저장할 초안을 찾지 못했습니다."
        }
    }
}
