import AppKit
import MacroKnotCore
import SwiftUI

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

enum SettingsTab: Hashable {
    case permissions
    case recording
    case shortcuts
}

struct SettingsView: View {
    @ObservedObject var permissions: PermissionState
    @State private var selectedTab: SettingsTab
    @AppStorage(AppPreferenceKeys.excludesEventsTargetingMacroKnot)
    private var excludesEventsTargetingMacroKnot = true
    @AppStorage(AppPreferenceKeys.recordingMode)
    private var recordingModeRawValue = AppPreferenceDefaults.recordingMode.rawValue
    @AppStorage(AppPreferenceKeys.recordingShortcut)
    private var recordingShortcutRawValue = AppPreferenceDefaults.recordingShortcut.rawValue
    @AppStorage(AppPreferenceKeys.playbackShortcut)
    private var playbackShortcutRawValue = AppPreferenceDefaults.playbackShortcut.rawValue

    init(permissions: PermissionState, initialTab: SettingsTab = .permissions) {
        self.permissions = permissions
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            permissionsPane
                .tag(SettingsTab.permissions)
                .tabItem {
                    Label("권한", systemImage: "checkmark.shield")
                }

            recordingPane
                .tag(SettingsTab.recording)
                .tabItem {
                    Label("녹화", systemImage: "record.circle")
                }

            shortcutsPane
                .tag(SettingsTab.shortcuts)
                .tabItem {
                    Label("단축키", systemImage: "keyboard")
                }
        }
        .padding(20)
        .frame(width: 620, height: 440)
        .onAppear(perform: permissions.refresh)
    }

    private var permissionsPane: some View {
        SettingsPane(
            title: "시스템 권한",
            description: "MacroKnot은 입력을 기록·재생하고 캡처 액션을 실행할 때만 해당 권한을 사용합니다."
        ) {
            SettingsCard {
                PermissionSettingsRow(
                    title: "손쉬운 사용",
                    description: "키보드와 포인터 입력을 녹화하고 재생합니다.",
                    granted: permissions.accessibilityGranted,
                    action: permissions.openAccessibilitySettings
                )
                Divider()
                PermissionSettingsRow(
                    title: "화면 및 시스템 오디오 녹음",
                    description: "디스플레이·앱·창 캡처 액션을 저장합니다.",
                    granted: permissions.screenCaptureGranted,
                    action: permissions.openScreenCaptureSettings
                )
            }

            HStack {
                Text("시스템 설정에서 권한을 바꾼 뒤 상태를 새로고침해 주세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("상태 새로고침", systemImage: "arrow.clockwise", action: permissions.refresh)
            }
        }
    }

    private var recordingPane: some View {
        SettingsPane(
            title: "입력 녹화",
            description: "자주 사용하는 녹화 방식을 기본값으로 정합니다. 시작 전에는 메인 화면에서 다시 바꿀 수 있습니다."
        ) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("기본 마우스 녹화")
                        .font(.headline)
                    Picker("기본 마우스 녹화", selection: recordingModeBinding) {
                        Text("주요 동작만 기록")
                            .tag(InputRecordingMode.meaningfulActionsOnly)
                        Text("모든 마우스 움직임 기록")
                            .tag(InputRecordingMode.allMouseMovement)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(recordingModeDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "MacroKnot 창을 대상으로 한 입력 제외",
                        isOn: $excludesEventsTargetingMacroKnot
                    )
                    Text("켜면 MacroKnot에서 액션을 편집하거나 녹화를 중지한 조작이 매크로에 섞이지 않습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Label("변경 사항은 다음 녹화를 시작할 때 적용됩니다.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsPane: some View {
        SettingsPane(
            title: "전역 단축키",
            description: "MacroKnot이 다른 앱 뒤에 있어도 녹화와 재생을 빠르게 제어합니다."
        ) {
            SettingsCard {
                ShortcutSettingsRow(title: "녹화 시작·중지") {
                    Picker("녹화 시작·중지", selection: $recordingShortcutRawValue) {
                        ForEach(RecordingShortcutChoice.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Divider()

                ShortcutSettingsRow(title: "재생") {
                    Picker("재생", selection: $playbackShortcutRawValue) {
                        ForEach(PlaybackShortcutChoice.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.red.opacity(0.10))
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.red)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("긴급 중지")
                        .fontWeight(.semibold)
                    Text("재생 중에는 어느 앱에서든 Control + Escape로 즉시 멈출 수 있습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⌃ Esc")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
            }
            .padding(13)
            .background(.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
        }
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

    private var recordingModeDescription: String {
        switch InputRecordingMode(rawValue: recordingModeRawValue)
            ?? AppPreferenceDefaults.recordingMode
        {
        case .meaningfulActionsOnly:
            return "클릭·스크롤·드래그는 기록하고, 단순한 포인터 이동은 제외해 액션 목록을 간결하게 유지합니다."
        case .allMouseMovement:
            return "포인터의 전체 이동 경로를 기록합니다. 액션 수가 빠르게 늘어날 수 있습니다."
        }
    }
}

private struct SettingsPane<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: String
    let description: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "허용됨" : "설정 필요")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((granted ? Color.green : Color.orange).opacity(0.10), in: Capsule())
            Button("시스템 설정", action: action)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ShortcutSettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
            Spacer()
            control
        }
    }
}
