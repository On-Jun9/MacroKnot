import AppKit
import MacroKnotCore
import Testing

@testable import MacroKnotApp

@Test
func presentsEveryEditableActionWithAUniqueNameAndIcon() {
    let kinds = MacroAction.Kind.allEditorCases

    #expect(kinds.count == 10)
    #expect(Set(kinds.map(\.displayName)).count == kinds.count)
    #expect(kinds.allSatisfy { !$0.displayName.isEmpty })
    #expect(kinds.allSatisfy { !$0.systemImage.isEmpty })
    #expect(kinds.allSatisfy { !$0.editorDescription.isEmpty })
}

@MainActor
@Test
func usesAvailableSystemSymbolsForPrimaryInterfaceActions() {
    let symbols = Set(MacroAction.Kind.allEditorCases.map(\.systemImage)).union([
        "arrow.clockwise",
        "camera.fill",
        "checkmark.circle.fill",
        "checkmark.shield",
        "chevron.down",
        "chevron.up",
        "cursorarrow.click",
        "doc.text",
        "ellipsis.circle",
        "exclamationmark.circle.fill",
        "exclamationmark.triangle.fill",
        "folder",
        "gearshape",
        "hand.raised.fill",
        "info.circle",
        "keyboard",
        "list.bullet.rectangle",
        "play.circle.fill",
        "play.fill",
        "plus",
        "record.circle",
        "record.circle.fill",
        "repeat",
        "sidebar.leading",
        "slider.horizontal.3",
        "scope",
        "stop.circle.fill",
        "stop.fill",
        "trash",
        "trash.slash",
        "xmark.octagon.fill",
    ])
    let unavailable = symbols.filter {
        NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil
    }

    #expect(unavailable.isEmpty)
}

#if DEBUG
    @Test
    func parsesUISnapshotWindowSizeSafely() {
        #expect(
            UISnapshotCaptureView.requestedContentSize(in: [
                "MacroKnot",
                "--ui-snapshot-window-size=900x620",
            ]) == CGSize(width: 900, height: 620)
        )
        #expect(
            UISnapshotCaptureView.requestedContentSize(in: [
                "--ui-snapshot-window-size=too-small"
            ]) == nil
        )
        #expect(
            UISnapshotCaptureView.requestedContentSize(in: [
                "--ui-snapshot-window-size=200x100"
            ]) == nil
        )
    }
#endif

@Test
func formatsActionSummariesForFastScanning() {
    let click = MacroAction(
        kind: .click,
        delayBeforeMilliseconds: 250,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(start: ScreenPoint(x: 10, y: 20))
    )
    let drag = MacroAction(
        kind: .drag,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(
            start: ScreenPoint(x: 10, y: 20),
            end: ScreenPoint(x: 90, y: 120),
            durationMilliseconds: 1_500,
            buttonNumber: 0
        )
    )
    let keyboard = MacroAction.keyboard(
        keyCode: 0,
        characters: "a",
        modifierFlags: 1,
        eventKind: .press
    )
    let capture = MacroAction.capture(
        CapturePayload(
            target: .window(42),
            destinationDirectory: "/tmp/MacroKnot 결과"
        ))
    let repeated = MacroAction.repeatBlock(
        count: 3,
        actions: [
            .wait(milliseconds: 100),
            keyboard,
        ])

    #expect(click.summary == "시작 전 250ms · 화면 좌표 (10, 20)")
    #expect(drag.summary == "(10, 20) → (90, 120) · 1.5초")
    #expect(keyboard.summary == "“a” · 보조 키 포함 · 누르고 떼기")
    #expect(capture.summary == "창 → MacroKnot 결과")
    #expect(repeated.summary == "2개 액션을 3회 반복")

    let returnKey = MacroAction.keyboard(
        keyCode: 36,
        characters: "\r",
        modifierFlags: 0
    )
    #expect(returnKey.summary == "Return · 누르고 떼기")
}

@Test
func calculatesNestedDurationAndSaturatesOverflow() {
    let actions: [MacroAction] = [
        .wait(milliseconds: 1_000),
        .repeatBlock(count: 3, actions: [.wait(milliseconds: 500)]),
    ]
    let overflowing: [MacroAction] = [
        .wait(milliseconds: .max),
        .wait(milliseconds: 1),
    ]

    #expect(actions.estimatedDurationMilliseconds == 2_500)
    #expect(overflowing.estimatedDurationMilliseconds == UInt64.max)
}

@Test
func formatsFiniteAndInfinitePlaybackProgress() {
    #expect(
        PlaybackProgressPresentation.statusText(
            iteration: 2,
            repetition: .finite(3),
            actionIndex: 6,
            actionCount: 14
        ) == "반복 2/3 · 액션 6/14"
    )
    #expect(
        PlaybackProgressPresentation.statusText(
            iteration: 7,
            repetition: .infinite
        ) == "반복 7 · 무한 반복"
    )
}

@Test
func presentsDraftNameAndLastUpdatedTimeForRecovery() {
    let updatedAt = Date(timeIntervalSince1970: 1_785_346_800)
    let draft = MacroDraftRecord(
        mode: .edit,
        document: MacroDocument(name: "월간 보고서 자동화"),
        originalCreatedAt: nil,
        updatedAt: updatedAt
    )

    var formattedDate: Date?
    let message = DraftRecoveryPresentation.message(for: draft) { date in
        formattedDate = date
        return "2026년 7월 30일 오전 2:40"
    }
    #expect(formattedDate == updatedAt)
    #expect(message == "월간 보고서 자동화 · 마지막 수정: 2026년 7월 30일 오전 2:40")

    var unnamedDraft = draft
    unnamedDraft.document.name = "  \n"
    let unnamedMessage = DraftRecoveryPresentation.message(for: unnamedDraft) { _ in
        "2026년 7월 30일 오전 2:40"
    }
    #expect(unnamedMessage == "이름 없는 매크로 · 마지막 수정: 2026년 7월 30일 오전 2:40")
}

@Test
func detectsCaptureActionsInsideRepeatBlocks() {
    let withoutCapture: [MacroAction] = [
        .wait(milliseconds: 100),
        .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
    ]
    let nestedCapture: [MacroAction] = [
        .repeatBlock(
            count: 2,
            actions: [
                .capture(
                    CapturePayload(
                        target: .display(1),
                        destinationDirectory: "/tmp"
                    ))
            ])
    ]

    #expect(!withoutCapture.containsCaptureAction)
    #expect(nestedCapture.containsCaptureAction)
}

@Test
func groupsConsecutiveMouseMovesForLibraryPreview() {
    let actions = [
        MacroAction(kind: .mouseMove, mouse: MousePayload(start: ScreenPoint(x: 10, y: 20))),
        MacroAction(kind: .mouseMove, mouse: MousePayload(start: ScreenPoint(x: 20, y: 30))),
        MacroAction(kind: .mouseMove, mouse: MousePayload(start: ScreenPoint(x: 30, y: 40))),
        MacroAction.click(
            point: ScreenPoint(x: 30, y: 40),
            strategy: .screenCoordinate
        ),
        MacroAction(kind: .mouseMove, mouse: MousePayload(start: ScreenPoint(x: 50, y: 60))),
        MacroAction(kind: .mouseMove, mouse: MousePayload(start: ScreenPoint(x: 60, y: 70))),
    ]

    let preview = MacroActionPreviewItem.grouped(actions)

    #expect(preview.count == 3)
    #expect(preview[0].sourceLabel == "1–3")
    #expect(preview[0].contains(actionNumber: 2))
    #expect(!preview[0].contains(actionNumber: 4))
    #expect(preview[0].title == "마우스 이동 ×3")
    #expect(preview[0].summary == "(10, 20) → (30, 40) · 연속 이동 경로")
    #expect(preview[1].kind == .click)
    #expect(preview[1].contains(actionNumber: 4))
    #expect(preview[2].sourceLabel == "5–6")
}

@Test
func formatsDurationsWithoutUnnecessaryPrecision() {
    #expect(MacroDurationFormatter.concise(milliseconds: 0) == "0ms")
    #expect(MacroDurationFormatter.concise(milliseconds: 999) == "999ms")
    #expect(MacroDurationFormatter.concise(milliseconds: 1_000) == "1초")
    #expect(MacroDurationFormatter.concise(milliseconds: 1_250) == "1.2초")
}

@Test
func distinguishesNewAndExistingActionDrafts() {
    let newDraft = ActionEditorDraft(kind: .wait)
    let existingDraft = ActionEditorDraft(action: .wait(milliseconds: 500))

    #expect(!newDraft.isEditing)
    #expect(existingDraft.isEditing)
}
