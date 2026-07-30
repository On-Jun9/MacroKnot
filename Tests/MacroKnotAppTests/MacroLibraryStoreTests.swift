import Foundation
import MacroKnotCore
import Testing
@testable import MacroKnotApp

@MainActor
@Test
func savesLoadsEditsAndDeletesLibraryRecords() throws {
    let fixture = try LibraryStorageFixture()
    let firstDate = Date(timeIntervalSince1970: 1_000)
    let secondDate = Date(timeIntervalSince1970: 2_000)
    var dates = [firstDate, secondDate].makeIterator()
    let store = MacroLibraryStore(storage: fixture.storage, now: { dates.next() ?? secondDate })

    let draft = try #require(store.beginNewDraft())
    var document = draft.document
    document.name = "업무 자동화"
    document.actions = [.wait(milliseconds: 100)]
    store.autosaveDraft(document)
    try store.saveDraftToLibrary(document)

    #expect(store.records.count == 1)
    #expect(store.selectedID == document.id)
    #expect(store.records[0].createdAt == firstDate)
    #expect(store.records[0].modifiedAt == secondDate)
    #expect(store.recoverableDraft == nil)

    let reloaded = MacroLibraryStore(storage: fixture.storage)
    #expect(reloaded.records.first?.document == document)
    reloaded.delete(id: document.id)
    #expect(reloaded.records.isEmpty)
}

@MainActor
@Test
func recoversAndDiscardsHiddenDraft() throws {
    let fixture = try LibraryStorageFixture()
    let store = MacroLibraryStore(storage: fixture.storage)
    var draft = try #require(store.beginNewDraft())
    draft.document.name = "복구할 초안"
    store.autosaveDraft(draft.document)

    let relaunched = MacroLibraryStore(storage: fixture.storage)
    #expect(relaunched.recoverableDraft?.document.name == "복구할 초안")
    #expect(relaunched.records.isEmpty)

    relaunched.discardDraft()
    #expect(relaunched.recoverableDraft == nil)
    #expect(try fixture.storage.loadDraft() == nil)
}

@MainActor
@Test
func importsDuplicateIdentityWithoutOverwritingExistingMacro() throws {
    let fixture = try LibraryStorageFixture()
    let store = MacroLibraryStore(storage: fixture.storage)
    let draft = try #require(store.beginNewDraft())
    var document = draft.document
    document.name = "가져오기 기준"
    document.actions = [.wait(milliseconds: 100)]
    try store.saveDraftToLibrary(document)

    let importURL = fixture.rootURL.appending(path: "import.json")
    try MacroDocumentCodec.save(document, to: importURL)
    let importedID = try #require(store.importDocument(from: importURL))

    #expect(importedID != document.id)
    #expect(store.records.count == 2)
    #expect(Set(store.records.map(\.id)).count == 2)
}

@MainActor
@Test
func duplicatesAndExportsStoredMacro() throws {
    let fixture = try LibraryStorageFixture()
    let store = MacroLibraryStore(storage: fixture.storage)
    let draft = try #require(store.beginNewDraft())
    var document = draft.document
    document.name = "원본"
    document.actions = [.wait(milliseconds: 100)]
    try store.saveDraftToLibrary(document)

    let duplicateID = try #require(store.duplicate(id: document.id))
    #expect(store.records.first(where: { $0.id == duplicateID })?.document.name == "원본 복사본")

    let exportURL = fixture.rootURL.appending(path: "export.json")
    try store.exportDocument(id: duplicateID, to: exportURL)
    #expect(try MacroDocumentCodec.load(from: exportURL).id == duplicateID)
}

@MainActor
@Test
func loadsSelectedLibraryDocumentForEditingAndRejectsDifferentDraft() throws {
    let fixture = try LibraryStorageFixture()
    let store = MacroLibraryStore(storage: fixture.storage)
    let originalDraft = try #require(store.beginNewDraft())
    var original = originalDraft.document
    original.name = "편집할 매크로"
    original.actions = [.wait(milliseconds: 200)]
    try store.saveDraftToLibrary(original)

    let editingDraft = try #require(store.beginEditing(id: original.id))
    #expect(editingDraft.mode == .edit)
    #expect(editingDraft.document == original)

    store.discardDraft()
    let unrelatedDraft = try #require(store.beginNewDraft())
    #expect(unrelatedDraft.document.id != original.id)
    #expect(store.beginEditing(id: original.id) == nil)
    #expect(store.recoverableDraft?.document.id == unrelatedDraft.document.id)
}

private struct LibraryStorageFixture {
    let rootURL: URL
    let storage: MacroLibraryStorage

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        storage = MacroLibraryStorage(rootURL: rootURL)
    }
}
