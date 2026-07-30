import SwiftUI
import MacroKnotCore

enum AppPreferenceKeys {
    static let excludesEventsTargetingMacroKnot = "recording.excludesEventsTargetingMacroKnot"
    static let recordingMode = "recording.defaultMode"
    static let recordingShortcut = "shortcuts.toggleRecording"
    static let playbackShortcut = "shortcuts.playback"
}

enum AppPreferenceDefaults {
    static let recordingMode = InputRecordingMode.meaningfulActionsOnly
    static let recordingShortcut = RecordingShortcutChoice.controlOptionR
    static let playbackShortcut = PlaybackShortcutChoice.controlOptionP
}

struct SettingsView: View {
    @ObservedObject var permissions: PermissionState
    @AppStorage(AppPreferenceKeys.excludesEventsTargetingMacroKnot)
    private var excludesEventsTargetingMacroKnot = true
    @AppStorage(AppPreferenceKeys.recordingMode)
    private var recordingModeRawValue = AppPreferenceDefaults.recordingMode.rawValue
    @AppStorage(AppPreferenceKeys.recordingShortcut)
    private var recordingShortcutRawValue = AppPreferenceDefaults.recordingShortcut.rawValue
    @AppStorage(AppPreferenceKeys.playbackShortcut)
    private var playbackShortcutRawValue = AppPreferenceDefaults.playbackShortcut.rawValue

    var body: some View {
        Form {
            Section("권한") {
                permissionRow(
                    "손쉬운 사용",
                    granted: permissions.accessibilityGranted,
                    action: permissions.openAccessibilitySettings
                )
                permissionRow(
                    "화면 캡처",
                    granted: permissions.screenCaptureGranted,
                    action: permissions.openScreenCaptureSettings
                )
                Button("권한 상태 새로고침", action: permissions.refresh)
            }

            Section("입력 녹화") {
                Picker("기본 마우스 녹화", selection: recordingModeBinding) {
                    Text("클릭·스크롤·드래그만")
                        .tag(InputRecordingMode.meaningfulActionsOnly)
                    Text("모든 마우스 이동")
                        .tag(InputRecordingMode.allMouseMovement)
                }
                Toggle(
                    "MacroKnot 창 위 입력 제외",
                    isOn: $excludesEventsTargetingMacroKnot
                )
                Text("켜면 MacroKnot 창을 대상으로 한 마우스와 키 입력을 액션에 넣지 않습니다. 변경 사항은 다음 녹화부터 적용됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("전역 단축키") {
                Picker("녹화 시작·중지", selection: $recordingShortcutRawValue) {
                    ForEach(RecordingShortcutChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                Picker("재생", selection: $playbackShortcutRawValue) {
                    ForEach(PlaybackShortcutChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                LabeledContent("재생 강제 중지", value: "Control + Escape")
                Text("전역 단축키는 MacroKnot이 뒤에 있어도 동작합니다. 녹화 단축키는 시작과 중지를 전환합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 500)
    }

    private var recordingModeBinding: Binding<InputRecordingMode> {
        Binding(
            get: {
                InputRecordingMode(rawValue: recordingModeRawValue)
                    ?? AppPreferenceDefaults.recordingMode
            },
            set: { recordingModeRawValue = $0.rawValue }
        )
    }

    private func permissionRow(
        _ title: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            Text(granted ? "허용됨" : "설정 필요")
                .foregroundStyle(.secondary)
            Button("설정 열기", action: action)
                .disabled(granted)
        }
    }
}
