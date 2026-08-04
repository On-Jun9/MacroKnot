import AppKit
import Foundation
import MacroKnotCore
import Testing
@testable import MacroKnotApp

/// 실행 취소와 복사·붙여넣기는 창의 UndoManager와 앱 전용 pasteboard를 쓰므로
/// 시험마다 다른 pasteboard와 자체 UndoManager를 붙여 서로 간섭하지 않게 한다.
@MainActor
private struct EditingFixture {
    let controller: DocumentController
    let undoManager: UndoManager
    let pasteboard: NSPasteboard

    init(actions: [MacroAction] = []) {
        pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.macroknot.tests.\(UUID().uuidString)")
        )
        controller = DocumentController(pasteboard: pasteboard)
        controller.document.actions = actions
        // 창의 UndoManager와 같은 기본 묶음 방식을 쓰므로 시험마다
        // 실행 취소를 부르기 전에 등록되는 조작은 하나로 유지한다.
        undoManager = UndoManager()
        controller.undoManager = undoManager
    }
}

@MainActor
@Test
func undoAndRedoRestoreActionListAroundAddedAction() {
    let existing = MacroAction.wait(milliseconds: 100)
    let fixture = EditingFixture(actions: [existing])
    let added = MacroAction.wait(milliseconds: 200)

    fixture.controller.addAction(added)
    #expect(fixture.controller.document.actions.map(\.id) == [existing.id, added.id])

    fixture.undoManager.undo()
    #expect(fixture.controller.document.actions.map(\.id) == [existing.id])

    fixture.undoManager.redo()
    #expect(fixture.controller.document.actions.map(\.id) == [existing.id, added.id])
}

@MainActor
@Test
func addsActionRightAfterSelectionAndAtEndWithoutSelection() {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let third = MacroAction.wait(milliseconds: 300)
    let fixture = EditingFixture(actions: [first, second, third])

    let afterFirst = MacroAction.wait(milliseconds: 400)
    fixture.controller.addAction(afterFirst, after: [first.id])
    #expect(
        fixture.controller.document.actions.map(\.id)
            == [first.id, afterFirst.id, second.id, third.id]
    )

    // 여러 개를 고른 상태에서는 마지막으로 선택된 액션 다음에 들어간다.
    let afterSecond = MacroAction.wait(milliseconds: 500)
    fixture.controller.addAction(afterSecond, after: [first.id, second.id])
    #expect(
        fixture.controller.document.actions.map(\.id)
            == [first.id, afterFirst.id, second.id, afterSecond.id, third.id]
    )

    let appended = MacroAction.wait(milliseconds: 600)
    fixture.controller.addAction(appended, after: [])
    #expect(fixture.controller.document.actions.last?.id == appended.id)
}

@MainActor
@Test
func wrapsRangeIntoOneRepeatActionAndReturnsItsIdentifier() throws {
    let actions = (1...4).map { MacroAction.wait(milliseconds: UInt64($0) * 100) }
    let fixture = EditingFixture(actions: actions)

    // 목록 뒤쪽 두 개를 묶으면 배열이 하나로 줄어든다.
    let wrappedID = try fixture.controller.wrapActionsInRepeat(from: 2, through: 3, count: 2)

    let result = fixture.controller.document.actions
    #expect(result.count == 3)
    #expect(result[2].id == wrappedID)
    #expect(result[2].kind == .repeatBlock)
    #expect(result[2].repeatBlock?.actions.map(\.id) == [actions[2].id, actions[3].id])
    // 묶기 뒤 선택은 이 식별자만 쓰면 되므로 줄어든 배열을 다시 읽을 필요가 없다.
    #expect(result.map(\.id) == [actions[0].id, actions[1].id, wrappedID])
}

@MainActor
@Test
func undoRestoresOrderAfterMovingActions() {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let third = MacroAction.wait(milliseconds: 300)
    let fixture = EditingFixture(actions: [first, second, third])

    fixture.controller.moveActions(fromOffsets: IndexSet(integer: 0), toOffset: 3)
    #expect(fixture.controller.document.actions.map(\.id) == [second.id, third.id, first.id])

    fixture.undoManager.undo()
    #expect(fixture.controller.document.actions.map(\.id) == [first.id, second.id, third.id])
}

@MainActor
@Test
func undoRestoresRemovedActionsInOneStep() {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let third = MacroAction.wait(milliseconds: 300)
    let fixture = EditingFixture(actions: [first, second, third])

    fixture.controller.removeActions(ids: [first.id, third.id])
    #expect(fixture.controller.document.actions.map(\.id) == [second.id])

    fixture.undoManager.undo()
    #expect(fixture.controller.document.actions.map(\.id) == [first.id, second.id, third.id])
}

@MainActor
@Test
func undoRemovesRecordedActionsAddedByRecording() {
    let existing = MacroAction.wait(milliseconds: 100)
    let fixture = EditingFixture(actions: [existing])
    let recorded = [
        MacroAction.wait(milliseconds: 200),
        MacroAction.wait(milliseconds: 300),
    ]

    fixture.controller.appendRecordedActions(recorded)
    #expect(fixture.controller.document.actions.count == 3)

    fixture.undoManager.undo()
    #expect(fixture.controller.document.actions.map(\.id) == [existing.id])
}

@MainActor
@Test
func undoKeepsCurrentMacroNameWhenRestoringActions() {
    let fixture = EditingFixture()
    fixture.controller.document.name = "처음 이름"
    fixture.controller.addAction(.wait(milliseconds: 100))
    fixture.controller.document.name = "나중 이름"

    fixture.undoManager.undo()

    #expect(fixture.controller.document.actions.isEmpty)
    #expect(fixture.controller.document.name == "나중 이름")
}

@MainActor
@Test
func skipsUndoRegistrationWhileRecording() {
    let fixture = EditingFixture()
    fixture.controller.isRecordingInProgress = true

    fixture.controller.addWaitAction(milliseconds: 100)

    #expect(fixture.controller.document.actions.count == 1)
    #expect(fixture.undoManager.canUndo == false)
}

@MainActor
@Test
func pastesCopiedActionsAfterSelectionWithNewIdentifiers() throws {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let third = MacroAction.wait(milliseconds: 300)
    let fixture = EditingFixture(actions: [first, second, third])

    fixture.controller.copyActions(ids: [first.id])
    #expect(fixture.controller.canPasteActions)

    let pastedIDs = fixture.controller.pasteActions(after: [second.id])

    let pastedID = try #require(pastedIDs.first)
    #expect(pastedIDs.count == 1)
    #expect(pastedID != first.id)
    #expect(
        fixture.controller.document.actions.map(\.id) == [first.id, second.id, pastedID, third.id]
    )
    #expect(fixture.controller.document.actions[2].wait?.milliseconds == 100)
}

@MainActor
@Test
func pastesCopiedActionsAtEndWithoutSelection() {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let fixture = EditingFixture(actions: [first, second])

    fixture.controller.copyActions(ids: [first.id, second.id])
    let pastedIDs = fixture.controller.pasteActions(after: [])

    #expect(pastedIDs.count == 2)
    #expect(
        fixture.controller.document.actions.map(\.id)
            == [first.id, second.id, pastedIDs[0], pastedIDs[1]]
    )
}

@MainActor
@Test
func copiesSelectedActionsInDocumentOrder() {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let third = MacroAction.wait(milliseconds: 300)
    let fixture = EditingFixture(actions: [first, second, third])

    fixture.controller.copyActions(ids: [third.id, first.id])
    fixture.controller.pasteActions(after: [third.id])

    let pastedDurations = fixture.controller.document.actions
        .suffix(2)
        .compactMap { $0.wait?.milliseconds }
    #expect(pastedDurations == [100, 300])
}

@MainActor
@Test
func undoRemovesPastedActions() {
    let first = MacroAction.wait(milliseconds: 100)
    let fixture = EditingFixture(actions: [first])

    fixture.controller.copyActions(ids: [first.id])
    fixture.controller.pasteActions(after: [first.id])
    #expect(fixture.controller.document.actions.count == 2)

    fixture.undoManager.undo()
    #expect(fixture.controller.document.actions.map(\.id) == [first.id])
}

@MainActor
@Test
func ignoresPasteWhenPasteboardHasNoActions() {
    let fixture = EditingFixture(actions: [.wait(milliseconds: 100)])

    let pastedIDs = fixture.controller.pasteActions(after: [])

    #expect(pastedIDs.isEmpty)
    #expect(fixture.controller.document.actions.count == 1)
    #expect(fixture.controller.canPasteActions == false)
}

@MainActor
@Test
func duplicatesSelectedActionsRightAfterTheirOriginals() {
    let first = MacroAction.wait(milliseconds: 100)
    let second = MacroAction.wait(milliseconds: 200)
    let third = MacroAction.wait(milliseconds: 300)
    let fixture = EditingFixture(actions: [first, second, third])

    let duplicatedIDs = fixture.controller.duplicateActions(ids: [first.id, second.id])

    #expect(duplicatedIDs.count == 2)
    #expect(Set(duplicatedIDs).isDisjoint(with: [first.id, second.id, third.id]))
    #expect(
        fixture.controller.document.actions.map(\.id)
            == [first.id, second.id, duplicatedIDs[0], duplicatedIDs[1], third.id]
    )
    #expect(
        fixture.controller.document.actions.compactMap { $0.wait?.milliseconds }
            == [100, 200, 100, 200, 300]
    )
}

@MainActor
@Test
func duplicatesRepeatBlockWithNewNestedIdentifiers() throws {
    let nested = MacroAction.wait(milliseconds: 500)
    let block = MacroAction.repeatBlock(count: 2, actions: [nested])
    let fixture = EditingFixture(actions: [block])

    let duplicatedIDs = fixture.controller.duplicateActions(ids: [block.id])

    #expect(duplicatedIDs.count == 1)
    let duplicated = try #require(fixture.controller.document.actions.last)
    #expect(duplicated.id != block.id)
    #expect(duplicated.repeatBlock?.count == 2)
    #expect(duplicated.repeatBlock?.actions.first?.id != nested.id)
    #expect(duplicated.repeatBlock?.actions.first?.wait?.milliseconds == 500)
}

@MainActor
@Test
func undoRemovesDuplicatedActions() {
    let first = MacroAction.wait(milliseconds: 100)
    let fixture = EditingFixture(actions: [first])

    fixture.controller.duplicateActions(ids: [first.id])
    #expect(fixture.controller.document.actions.count == 2)

    fixture.undoManager.undo()
    #expect(fixture.controller.document.actions.map(\.id) == [first.id])
}

@MainActor
@Test
func ignoresDuplicateWithoutSelection() {
    let fixture = EditingFixture(actions: [.wait(milliseconds: 100)])

    let duplicatedIDs = fixture.controller.duplicateActions(ids: [])

    #expect(duplicatedIDs.isEmpty)
    #expect(fixture.controller.document.actions.count == 1)
}
