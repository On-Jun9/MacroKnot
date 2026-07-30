import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class PermissionState: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenCaptureGranted = false

    init() {
        refresh()
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false,
        ] as CFDictionary)
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        RuntimeEventLogger.record(
            "permission_state",
            result: accessibilityGranted ? "PASS" : "FAIL",
            fields: [
                "accessibility": String(accessibilityGranted),
                "screen_capture": String(screenCaptureGranted),
            ]
        )
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
