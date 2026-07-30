#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import MacroKnotCore
import SwiftUI

struct DebugUISnapshotRoot: View {
    @ObservedObject var permissions: PermissionState
    private let configuration = UISnapshotConfiguration.current

    var body: some View {
        fixtureView
            .preferredColorScheme(configuration.colorScheme)
            .background {
                UISnapshotCaptureView()
            }
    }

    @ViewBuilder
    private var fixtureView: some View {
        switch configuration.fixture {
        case .empty:
            ContentView(permissions: permissions)
        case .populated:
            ContentView(
                permissions: permissions,
                initialDocument: Self.populatedDocument
            )
        case .recording:
            ContentView(
                permissions: permissions,
                initialDocument: Self.recordingDocument,
                previewState: .recording(
                    actions: Array(Self.sampleActions.prefix(12)),
                    lastEvent: "마우스 이동 → 포인터 경로"
                )
            )
        case .playing:
            ContentView(
                permissions: permissions,
                initialDocument: Self.populatedDocument,
                previewState: .playing
            )
        case .error:
            ContentView(
                permissions: permissions,
                initialDocument: Self.populatedDocument,
                previewState: .failed(
                    "디스플레이 해상도·배율·배치가 매크로 작성 당시와 달라 재생할 수 없습니다."
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
        case .settings:
            SettingsView(permissions: permissions)
        case .settingsRecording:
            SettingsView(permissions: permissions, initialTab: .recording)
        case .settingsShortcuts:
            SettingsView(permissions: permissions, initialTab: .shortcuts)
        }
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
        case error
        case editor
        case coordinatePicker = "coordinate-picker"
        case coordinatePickerFlow = "coordinate-picker-flow"
        case coordinatePickerCancelFlow = "coordinate-picker-cancel-flow"
        case settings
        case settingsRecording = "settings-recording"
        case settingsShortcuts = "settings-shortcuts"
    }

    let fixture: Fixture
    let colorScheme: ColorScheme?

    static var current: Self {
        Self(
            fixture: value(for: "--ui-snapshot-fixture=")
                .flatMap(Fixture.init(rawValue:)) ?? .empty,
            colorScheme: colorScheme(from: value(for: "--ui-snapshot-appearance="))
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
#endif
