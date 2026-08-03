#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import MacroKnotCore
import SwiftUI

struct DebugUISnapshotRoot: View {
    @ObservedObject var permissions: PermissionState
    @StateObject private var libraryStore: MacroLibraryStore
    private let configuration: UISnapshotConfiguration

    init(permissions: PermissionState) {
        self.permissions = permissions
        let configuration = UISnapshotConfiguration.current
        self.configuration = configuration
        let records: [MacroLibraryRecord]
        switch configuration.fixture {
        case .empty:
            records = []
        case .mouseHeavy:
            records = Self.mouseHeavyRecords
        default:
            records = Self.previewRecords
        }
        _libraryStore = StateObject(
            wrappedValue: MacroLibraryStore(
                previewRecords: records,
                recoverableDraft: configuration.fixture == .draftRecovery
                    ? Self.previewDraft
                    : nil,
                errorMessage: configuration.fixture == .error
                    ? "보관함 파일 일부를 읽지 못했습니다. 파일 형식을 확인해 주세요."
                    : nil
            )
        )
    }

    var body: some View {
        if configuration.isCaptureRequested {
            fixtureView
                .preferredColorScheme(configuration.colorScheme)
                .background {
                    UISnapshotCaptureView()
                }
        } else if configuration.fixture == .macroEditorCancelFlow {
            MacroEditorCancelFlowFixture(scenario: .cancelWithChanges)
        } else if configuration.fixture == .macroEditorCancelDirectFlow {
            MacroEditorCancelFlowFixture(scenario: .cancelWithoutChanges)
        } else if configuration.fixture == .macroEditorCancelRecoveredFlow {
            MacroEditorCancelFlowFixture(scenario: .cancelRecoveredDraft)
        } else if configuration.fixture == .coordinatePickerSheetFlow {
            CoordinatePickerSheetFlowFixture()
        } else {
            LibraryView(permissions: permissions)
        }
    }

    @ViewBuilder
    private var fixtureView: some View {
        switch configuration.fixture {
        case .empty:
            LibraryView(permissions: permissions)
                .environmentObject(libraryStore)
        case .populated:
            LibraryView(permissions: permissions)
                .environmentObject(libraryStore)
        case .mouseHeavy:
            LibraryView(permissions: permissions)
                .environmentObject(libraryStore)
        case .playing:
            LibraryView(
                permissions: permissions,
                previewState: .playing(
                    iteration: 2,
                    repeatCount: 3,
                    actionIndex: 6,
                    actionCount: 14
                )
            )
            .environmentObject(libraryStore)
        case .playbackOptions:
            LibraryView(
                permissions: permissions,
                previewState: .configured(rate: 1.5, repeatCount: 3)
            )
            .environmentObject(libraryStore)
        case .error:
            LibraryView(
                permissions: permissions,
                previewState: .failed(
                    "디스플레이 해상도·배율·배치가 매크로 작성 당시와 달라 재생할 수 없습니다."
                )
            )
            .environmentObject(libraryStore)
        case .draftRecovery:
            LibraryView(permissions: permissions)
                .environmentObject(libraryStore)
        case .recording:
            ContentView(
                permissions: permissions,
                initialDocument: Self.recordingDocument,
                previewState: .recording(
                    actions: Array(Self.sampleActions.prefix(12)),
                    lastEvent: "마우스 이동 → 포인터 경로"
                )
            )
        case .macroEditor:
            let document = Self.populatedDocument
            macroEditorFixture(
                document: document,
                selectedActionIDs: Set(document.actions[1...3].map(\.id))
            )
        case .macroEditorEmpty:
            macroEditorFixture(
                document: MacroDocument(
                    name: "새 매크로",
                    displayConfiguration: DisplayConfigurationProvider.current()
                )
            )
        case .macroEditorRecording:
            macroEditorFixture(
                document: Self.recordingDocument,
                previewState: .recording(
                    actions: Array(Self.sampleActions.prefix(12)),
                    lastEvent: "마우스 이동 → 포인터 경로"
                )
            )
        case .editor:
            ActionEditorSheet(draft: Self.editorDraft) { _ in }
        case .coordinatePicker:
            ScreenCoordinatePickerOverlay(onSelect: {}, onCancel: {})
        case .coordinatePickerFlow:
            CoordinatePickerFlowFixture(automatedAction: .select)
        case .coordinatePickerCancelFlow:
            CoordinatePickerFlowFixture(automatedAction: .cancel)
        case .coordinatePickerSheetFlow:
            CoordinatePickerSheetFlowFixture()
        case .macroEditorCancelFlow:
            MacroEditorCancelFlowFixture(scenario: .cancelWithChanges)
        case .macroEditorCancelDirectFlow:
            MacroEditorCancelFlowFixture(scenario: .cancelWithoutChanges)
        case .macroEditorCancelRecoveredFlow:
            MacroEditorCancelFlowFixture(scenario: .cancelRecoveredDraft)
        case .settings:
            SettingsView(permissions: permissions)
        case .settingsRecording:
            SettingsView(permissions: permissions, initialTab: .recording)
        case .settingsShortcuts:
            SettingsView(permissions: permissions, initialTab: .shortcuts)
        }
    }

    private func macroEditorFixture(
        document: MacroDocument,
        selectedActionIDs: Set<UUID> = [],
        previewState: WorkspacePreviewState = .live
    ) -> some View {
        ContentView(
            permissions: permissions,
            initialDocument: document,
            initialSelectedActionIDs: selectedActionIDs,
            previewState: previewState,
            editorConfiguration: MacroEditorConfiguration(
                startRecording: false,
                isPlaybackRunning: { false },
                onRecordingRequestHandled: {},
                onRecordingStateChanged: { _ in },
                onDraftChanged: { _ in },
                shouldConfirmCancel: { _ in false },
                onSave: { _ in },
                onCancel: {}
            )
        )
    }

    private static var populatedDocument: MacroDocument {
        MacroDocument(
            name: "월간 보고서 자료 정리 및 캡처 자동화",
            actions: sampleActions,
            displayConfiguration: DisplayConfigurationProvider.current()
        )
    }

    private static var recordingDocument: MacroDocument {
        MacroDocument(
            name: "새 업무 흐름 녹화",
            actions: Array(sampleActions.prefix(3)),
            displayConfiguration: DisplayConfigurationProvider.current()
        )
    }

    private static var previewRecords: [MacroLibraryRecord] {
        let documents = [
            populatedDocument,
            MacroDocument(
                name: "주간 정산 자료 내려받기",
                actions: Array(sampleActions.prefix(6)),
                displayConfiguration: DisplayConfigurationProvider.current()
            ),
            MacroDocument(
                name: "고객 문의 화면 캡처",
                actions: Array(sampleActions.suffix(5)),
                displayConfiguration: DisplayConfigurationProvider.current()
            ),
        ]
        return documents.enumerated().map { index, document in
            let date = Date(timeIntervalSince1970: 1_785_346_800 - Double(index * 86_400))
            return MacroLibraryRecord(document: document, createdAt: date, modifiedAt: date)
        }
    }

    private static var previewDraft: MacroDraftRecord {
        MacroDraftRecord(
            mode: .edit,
            document: populatedDocument,
            originalCreatedAt: Date(timeIntervalSince1970: 1_785_260_400),
            updatedAt: Date(timeIntervalSince1970: 1_785_346_800)
        )
    }

    private static var mouseHeavyRecords: [MacroLibraryRecord] {
        var actions: [MacroAction] = []
        for index in 0..<120 {
            let point = ScreenPoint(
                x: Double(120 + index * 4),
                y: Double(240 + index)
            )
            actions.append(MacroAction(
                kind: .mouseMove,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(start: point)
            ))
        }
        actions.append(MacroAction.click(
            point: ScreenPoint(x: 600, y: 360),
            strategy: .screenCoordinate
        ))
        for index in 0..<10 {
            let point = ScreenPoint(
                x: Double(600 + index * 8),
                y: Double(360 + index * 3)
            )
            actions.append(MacroAction(
                kind: .mouseMove,
                targetStrategy: .screenCoordinate,
                mouse: MousePayload(start: point)
            ))
        }
        actions.append(MacroAction.keyboard(keyCode: 36, characters: nil, modifierFlags: 0))
        actions.append(MacroAction.wait(milliseconds: 500))
        let document = MacroDocument(
            name: "스크롤 자료 정리",
            actions: actions,
            displayConfiguration: DisplayConfigurationProvider.current()
        )
        let date = Date(timeIntervalSince1970: 1_785_346_800)
        return [MacroLibraryRecord(document: document, createdAt: date, modifiedAt: date)]
    }

    private static var editorDraft: ActionEditorDraft {
        var draft = ActionEditorDraft(kind: .drag)
        draft.startX = "128"
        draft.startY = "242"
        draft.endX = "864"
        draft.endY = "612"
        draft.duration = "850"
        draft.delay = "250"
        return draft
    }

    // Build a fresh set for each fixture state. The recording fixture displays
    // saved and in-progress actions together, so reusing UUIDs would make
    // SwiftUI's list identity collapse otherwise distinct rows.
    private static var sampleActions: [MacroAction] {
        [
        MacroAction(
            kind: .click,
            delayBeforeMilliseconds: 350,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: ScreenPoint(x: 180, y: 220))
        ),
        .keyboard(keyCode: 3, characters: "f", modifierFlags: 1_048_576),
        .wait(milliseconds: 800),
        MacroAction(
            kind: .doubleClick,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: ScreenPoint(x: 520, y: 410))
        ),
        MacroAction(
            kind: .scroll,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(
                start: ScreenPoint(x: 760, y: 510),
                scrollDeltaX: 0,
                scrollDeltaY: -420
            )
        ),
        MacroAction(
            kind: .drag,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(
                start: ScreenPoint(x: 240, y: 320),
                end: ScreenPoint(x: 680, y: 320),
                durationMilliseconds: 650,
                buttonNumber: 0
            )
        ),
        .keyboard(keyCode: 36, characters: nil, modifierFlags: 0),
        .capture(
            CapturePayload(
                target: .display(1),
                destinationDirectory: "/Users/example/Pictures/MacroKnot/월간 보고서 캡처"
            )
        ),
        .repeatBlock(
            count: 3,
            actions: [
                .wait(milliseconds: 500),
                .keyboard(keyCode: 48, characters: nil, modifierFlags: 0),
            ]
        ),
        MacroAction(
            kind: .rightClick,
            delayBeforeMilliseconds: 200,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: ScreenPoint(x: 940, y: 560))
        ),
        MacroAction(
            kind: .mouseMove,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: ScreenPoint(x: 1_020, y: 680))
        ),
        .wait(milliseconds: 1_500),
        .keyboard(keyCode: 1, characters: "s", modifierFlags: 1_048_576),
        MacroAction(
            kind: .click,
            delayBeforeMilliseconds: 1_200,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: ScreenPoint(x: 1_120, y: 740))
        ),
        ]
    }
}

private struct UISnapshotConfiguration {
    enum Fixture: String {
        case empty
        case populated
        case recording
        case playing
        case playbackOptions = "playback-options"
        case mouseHeavy = "mouse-heavy"
        case error
        case editor
        case macroEditor = "macro-editor"
        case macroEditorEmpty = "macro-editor-empty"
        case macroEditorRecording = "macro-editor-recording"
        case macroEditorCancelFlow = "macro-editor-cancel-flow"
        case macroEditorCancelDirectFlow = "macro-editor-cancel-direct-flow"
        case macroEditorCancelRecoveredFlow = "macro-editor-cancel-recovered-flow"
        case draftRecovery = "draft-recovery"
        case coordinatePicker = "coordinate-picker"
        case coordinatePickerFlow = "coordinate-picker-flow"
        case coordinatePickerCancelFlow = "coordinate-picker-cancel-flow"
        case coordinatePickerSheetFlow = "coordinate-picker-sheet-flow"
        case settings
        case settingsRecording = "settings-recording"
        case settingsShortcuts = "settings-shortcuts"
    }

    let fixture: Fixture
    let colorScheme: ColorScheme?
    let isCaptureRequested: Bool

    static var current: Self {
        Self(
            fixture: value(for: "--ui-snapshot-fixture=")
                .flatMap(Fixture.init(rawValue:)) ?? .empty,
            colorScheme: colorScheme(from: value(for: "--ui-snapshot-appearance=")),
            isCaptureRequested: ProcessInfo.processInfo.arguments.contains {
                $0.hasPrefix("--ui-snapshot-output=")
            }
        )
    }

    private static func value(for prefix: String) -> String? {
        guard
            let argument = ProcessInfo.processInfo.arguments.first(where: {
                $0.hasPrefix(prefix)
            })
        else {
            return nil
        }
        return String(argument.dropFirst(prefix.count))
    }

    private static func colorScheme(from value: String?) -> ColorScheme? {
        switch value {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

private struct CoordinatePickerFlowFixture: View {
    enum AutomatedAction {
        case select
        case cancel
    }

    let automatedAction: AutomatedAction
    @StateObject private var coordinatePicker = ScreenCoordinatePicker()
    @State private var didStart = false
    @State private var resultTitle = "화면 선택 준비 중"
    @State private var resultDetail = "전체 화면 선택 레이어를 여는 중입니다."
    @State private var resultImage = "scope"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: resultImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(resultImage == "checkmark.circle.fill" ? Color.green : Color.accentColor)
            Text(resultTitle)
                .font(.title2.weight(.semibold))
            Text(resultDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: startOnce)
    }

    private func startOnce() {
        guard !didStart else { return }
        didStart = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            coordinatePicker.begin { outcome in
                switch outcome {
                case .selected(let point):
                    resultImage = "checkmark.circle.fill"
                    resultTitle = "화면 좌표 선택 완료"
                    resultDetail = "X \(ScreenCoordinateTextFormatter.pickedString(point.x)) · Y \(ScreenCoordinateTextFormatter.pickedString(point.y))"
                case .cancelled:
                    resultImage = "xmark.circle.fill"
                    resultTitle = "화면 좌표 선택 취소"
                    resultDetail = "선택 전 값이 그대로 유지됩니다."
                case .failed(let message):
                    resultImage = "exclamationmark.triangle.fill"
                    resultTitle = "화면 좌표 선택 실패"
                    resultDetail = message
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                switch automatedAction {
                case .select:
                    Self.postTestClickAtCurrentPointer()
                case .cancel:
                    Self.postTestEscape()
                }
            }
        }
    }

    private static func postTestClickAtCurrentPointer() {
        guard let source = CGEventSource(stateID: .hidSystemState),
            let location = CGEvent(source: nil)?.location
        else { return }
        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private static func postTestEscape() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}

/// 시트가 열린 창에서 좌표 선택을 실행했다 취소한 뒤, 창이 다시 보이고
/// 시트가 부모 창에 부착된 채 복원되는지를 runtime.jsonl에 PASS/FAIL로 남기는 자동 시험.
/// 선택 동안에도 창이 윈도우 목록에 남아 있어야(AltTab에서 사라지지 않아야) 한다.
private struct CoordinatePickerSheetFlowFixture: View {
    @StateObject private var coordinatePicker = ScreenCoordinatePicker()
    @State private var didStart = false
    @State private var isSheetPresented = false
    @State private var statusText = "좌표 선택 시트 복원 시험 준비"
    @State private var hostWindow: NSWindow?
    @State private var hostConcealedDuringPick = false
    @State private var hostListedDuringPick = false
    @State private var sheetAttachedDuringPick = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(statusText)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $isSheetPresented) {
            VStack(spacing: 10) {
                Text("시트 복원 확인용")
                    .font(.headline)
                Text("좌표 선택 동안 이 시트가 부착 상태를 유지해야 합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 360)
        }
        .onAppear(perform: startOnce)
    }

    private func startOnce() {
        guard !didStart else { return }
        didStart = true
        RuntimeEventLogger.record("coordinate_picker_sheet_flow_started", fields: [:])

        after(0.3) {
            statusText = "시트 표시"
            hostWindow = NSApplication.shared.windows.first { window in
                window.isVisible && window.level == .normal
            }
            isSheetPresented = true
        }
        after(1.3) {
            guard let hostWindow, hostWindow.attachedSheet != nil else {
                finish(result: "FAIL", fields: ["stage": "sheet_not_presented"])
                return
            }
            statusText = "좌표 선택 시작"
            coordinatePicker.begin { _ in }
        }
        after(2.1) {
            hostConcealedDuringPick = hostWindow?.alphaValue == 0
            hostListedDuringPick = hostWindow?.isVisible == true
            sheetAttachedDuringPick = hostWindow?.attachedSheet != nil
            statusText = "좌표 선택 취소로 복원"
            coordinatePicker.cancel()
        }
        after(2.9) {
            let hostRestored = hostWindow?.isVisible == true
                && hostWindow?.alphaValue == 1
            let attachedSheet = hostWindow?.attachedSheet
            let sheetRestored = attachedSheet != nil
                && attachedSheet?.isVisible == true
                && attachedSheet?.alphaValue == 1
                && attachedSheet?.sheetParent === hostWindow
            let passed = hostConcealedDuringPick && hostListedDuringPick
                && sheetAttachedDuringPick && hostRestored && sheetRestored
            finish(
                result: passed ? "PASS" : "FAIL",
                fields: [
                    "host_concealed_during_pick": String(hostConcealedDuringPick),
                    "host_listed_during_pick": String(hostListedDuringPick),
                    "sheet_attached_during_pick": String(sheetAttachedDuringPick),
                    "host_restored_after": String(hostRestored),
                    "sheet_restored_attached": String(sheetRestored),
                ]
            )
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            work()
        }
    }

    private func finish(result: String, fields: [String: String]) {
        RuntimeEventLogger.record(
            "coordinate_picker_sheet_flow_result",
            result: result,
            fields: fields
        )
        // 시트 모달 세션이 남아 있으면 terminate가 진행되지 않고
        // 앱이 시트와 함께 화면에 남으므로 시트를 닫은 뒤 종료한다.
        isSheetPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}

extension Notification.Name {
    static let debugMacroEditorAppendWaitAction = Notification.Name(
        "dev.macroknot.debug.editor-append-wait-action"
    )
    static let debugMacroEditorRequestCancel = Notification.Name(
        "dev.macroknot.debug.editor-request-cancel"
    )
}

/// 편집 창의 `취소 → 초안 삭제` 흐름을 실제 알림창 버튼 클릭까지 재현하고
/// 창이 닫혔는지를 runtime.jsonl에 PASS/FAIL로 남기는 자동 시험.
private struct MacroEditorCancelFlowFixture: View {
    enum Scenario {
        /// 변경 후 취소: 확인창을 거쳐 초안을 삭제하고 창이 닫혀야 한다.
        case cancelWithChanges
        /// 빈 초안 취소: 확인창 없이 즉시 창이 닫혀야 한다.
        case cancelWithoutChanges
        /// 내용 있는 초안을 닫았다 다시 연 뒤 취소: 세션 내 변경이 없어도
        /// 확인창이 반드시 떠야 한다.
        case cancelRecoveredDraft
    }

    let scenario: Scenario
    @EnvironmentObject private var store: MacroLibraryStore
    @Environment(\.openWindow) private var openWindow
    @State private var didStart = false
    @State private var alertClicked = false
    @State private var statusText = "편집 창 취소 흐름 시험 준비"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(statusText)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: startOnce)
    }

    private var scenarioName: String {
        switch scenario {
        case .cancelWithChanges: return "cancel_with_changes"
        case .cancelWithoutChanges: return "cancel_without_changes"
        case .cancelRecoveredDraft: return "cancel_recovered_draft"
        }
    }

    private var expectsAlert: Bool {
        scenario != .cancelWithoutChanges
    }

    private func startOnce() {
        guard !didStart else { return }
        didStart = true
        RuntimeEventLogger.record(
            "editor_cancel_flow_started",
            fields: ["scenario": scenarioName]
        )

        guard let draft = store.beginNewDraft() else {
            finish(result: "FAIL", fields: ["stage": "begin_new_draft"])
            return
        }
        statusText = "편집 창 여는 중"
        openWindow(id: "macro-editor", value: draft.document.id)

        after(1.2) {
            logWindows(stage: "after_open")
            if scenario != .cancelWithoutChanges {
                statusText = "변경사항 생성"
                NotificationCenter.default.post(
                    name: .debugMacroEditorAppendWaitAction,
                    object: nil
                )
            }
        }

        var cancelDelay = 1.6
        if scenario == .cancelRecoveredDraft {
            after(2.0) {
                statusText = "초안 유지한 채 편집 창 닫기"
                editorWindows().first?.close()
            }
            after(2.8) {
                statusText = "초안 복구로 편집 창 다시 열기"
                guard let recovered = store.beginNewDraft() else {
                    finish(result: "FAIL", fields: ["stage": "reopen_recovered_draft"])
                    return
                }
                openWindow(id: "macro-editor", value: recovered.document.id)
            }
            cancelDelay = 4.0
        }

        after(cancelDelay) {
            statusText = "취소 요청"
            NotificationCenter.default.post(name: .debugMacroEditorRequestCancel, object: nil)
        }
        after(cancelDelay + 1.0) {
            guard expectsAlert else { return }
            logWindows(stage: "alert_presented")
            alertClicked = clickButton(titled: "초안 삭제")
            statusText = alertClicked ? "초안 삭제 클릭됨" : "초안 삭제 버튼 못 찾음"
            RuntimeEventLogger.record(
                "editor_cancel_flow_alert_click",
                result: alertClicked ? "PASS" : "FAIL",
                fields: ["scenario": scenarioName]
            )
        }
        after(cancelDelay + 2.4) {
            logWindows(stage: "final")
            let editorCount = editorWindows().count
            let draftCleared = store.recoverableDraft == nil
            let alertSatisfied = expectsAlert ? alertClicked : true
            finish(
                result: editorCount == 0 && draftCleared && alertSatisfied ? "PASS" : "FAIL",
                fields: [
                    "editor_window_count": String(editorCount),
                    "draft_cleared": String(draftCleared),
                    "alert_clicked": String(alertClicked),
                ]
            )
        }
    }

    private func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            work()
        }
    }

    private func finish(result: String, fields: [String: String]) {
        RuntimeEventLogger.record("editor_cancel_flow_result", result: result, fields: fields)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func editorWindows() -> [NSWindow] {
        NSApplication.shared.windows.filter { window in
            window.isVisible
                && (window.identifier?.rawValue.contains("macro-editor") == true
                    || window.title == "매크로 편집"
                    || window.title == "새 매크로")
        }
    }

    private func logWindows(stage: String) {
        let summary = NSApplication.shared.windows
            .map { window in
                [
                    String(describing: type(of: window)),
                    "id=\(window.identifier?.rawValue ?? "-")",
                    "title=\(window.title)",
                    "visible=\(window.isVisible)",
                    "sheet=\(window.attachedSheet != nil)",
                ].joined(separator: ",")
            }
            .joined(separator: " | ")
        RuntimeEventLogger.record(
            "editor_cancel_flow_windows",
            fields: ["stage": stage, "windows": summary]
        )
    }

    private func clickButton(titled title: String) -> Bool {
        var candidates = NSApplication.shared.windows
        candidates.append(contentsOf: candidates.compactMap(\.attachedSheet))
        for window in candidates {
            if let button = findButton(titled: title, in: window.contentView) {
                button.performClick(nil)
                return true
            }
        }
        return false
    }

    private func findButton(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(titled: title, in: subview) {
                return found
            }
        }
        return nil
    }
}
#endif
