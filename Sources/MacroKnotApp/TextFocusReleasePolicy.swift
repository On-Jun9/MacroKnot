import AppKit

/// 텍스트 편집 중 창의 다른 곳을 클릭했을 때 편집 포커스를 놓아줄지 판단한다.
/// SwiftUI 텍스트 필드는 바깥을 클릭해도 포커스가 풀리지 않아 `Cmd+Z`, `Cmd+Delete` 같은
/// 단축키가 편집 창이 아니라 텍스트 필드로 들어가므로 이 판정이 필요하다.
/// 창과 이벤트 없이 시험할 수 있도록 판정만 떼어 두었다.
enum TextFocusReleasePolicy {
    /// 창 좌표의 클릭 지점이 닿은 뷰를 찾는다.
    /// `hitTest`는 상위 뷰 좌표계의 점을 받고, 콘텐츠 뷰의 상위는 창 프레임이므로 창 좌표를
    /// 그대로 넘긴다. 콘텐츠 뷰 좌표로 변환해 넘기면 `NSHostingView`처럼 뒤집힌 뷰에서
    /// 판정 지점이 세로로 뒤집힌다.
    static func hitView(in window: NSWindow, at pointInWindow: NSPoint) -> NSView? {
        guard let contentView = window.contentView else { return nil }
        return contentView.hitTest(pointInWindow)
    }

    /// 클릭이 닿은 뷰부터 위로 올라가며 텍스트 입력 컨트롤인지 확인한다.
    /// SwiftUI 텍스트 필드는 클릭이 내부 자식 뷰에 닿으므로 상위 계층까지 살펴야 한다.
    static func isTextInput(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSTextField || candidate is NSTextView {
                return true
            }
            current = candidate.superview
        }
        return false
    }

    /// 텍스트 편집 중이고 클릭 지점이 텍스트 입력이 아닐 때만 포커스를 놓는다.
    /// 편집 중이 아니면 뷰 계층을 뒤지지 않도록 클릭 지점은 클로저로 받는다.
    /// 타이틀바처럼 콘텐츠 밖을 클릭하면 클릭 지점이 없으므로 포커스를 놓는다.
    static func shouldRelease(
        isEditingText: Bool,
        hitView: () -> NSView?
    ) -> Bool {
        guard isEditingText else { return false }
        guard let view = hitView() else { return true }
        return !isTextInput(view)
    }
}
