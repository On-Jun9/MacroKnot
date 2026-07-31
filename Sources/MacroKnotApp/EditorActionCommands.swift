import AppKit
import SwiftUI

/// 표준 편집 메뉴의 복사·붙여넣기를 편집 창의 액션 명령으로 처리하는 응답자.
/// 창 뒤쪽 응답자 사슬에 끼우므로 텍스트 필드(필드 편집기)가 먼저 응답하고,
/// 매크로 이름을 입력하는 동안에는 시스템 기본 복사·붙여넣기가 그대로 유지된다.
final class EditorActionCommandResponder: NSResponder, NSMenuItemValidation {
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onCancel: (() -> Void)?
    /// pasteboard는 다른 앱이 언제든 교체할 수 있으므로 메뉴 검증 시점에 실시간으로 판정한다.
    var canPaste: (() -> Bool)?

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    @objc func paste(_ sender: Any?) {
        onPaste?()
    }

    // 포커스를 가진 뷰가 없으면 `.onExitCommand`가 Esc를 받지 못하므로
    // 응답자 사슬 끝에서 받아 같은 취소 경로로 연결한다.
    // 포커스 없는 창의 Esc는 `cancelOperation:`이 아니라 `cancel:` 액션으로 사슬에 전달된다.
    override func cancelOperation(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            nextResponder?.cancelOperation(sender)
        }
    }

    @objc func cancel(_ sender: Any?) {
        if let onCancel {
            onCancel()
        } else {
            nextResponder?.doCommand(by: #selector(cancel(_:)))
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return onCopy != nil
        case #selector(paste(_:)):
            return onPaste != nil && canPaste?() != false
        default:
            return true
        }
    }
}

/// 편집 창이 살아 있는 동안에만 위 응답자를 창의 응답자 사슬에 넣고 빼는 부착점.
struct EditorActionCommands: NSViewRepresentable {
    /// 복사·붙여넣기를 지금 할 수 없으면 nil을 전달해 메뉴 항목을 비활성으로 만든다.
    let onCopy: (() -> Void)?
    let onPaste: (() -> Void)?
    let canPaste: (() -> Bool)?
    let onCancel: (() -> Void)?

    final class Coordinator {
        let responder = EditorActionCommandResponder()
        weak var window: NSWindow?

        func install(on window: NSWindow) {
            guard window.nextResponder !== responder else { return }
            self.window = window
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
        }

        func uninstall() {
            guard let window, window.nextResponder === responder else { return }
            window.nextResponder = responder.nextResponder
            self.window = nil
        }
    }

    final class AttachmentView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = AttachmentView()
        apply(to: context.coordinator)
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            if let window {
                coordinator?.install(on: window)
            } else {
                coordinator?.uninstall()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    private func apply(to coordinator: Coordinator) {
        coordinator.responder.onCopy = onCopy
        coordinator.responder.onPaste = onPaste
        coordinator.responder.canPaste = canPaste
        coordinator.responder.onCancel = onCancel
    }
}
