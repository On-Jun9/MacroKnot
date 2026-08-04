import AppKit
import Testing

@testable import MacroKnotApp

@MainActor
@Test
func keepsTextFocusWhileNotEditingText() {
    var didLookUpHitView = false

    let shouldRelease = TextFocusReleasePolicy.shouldRelease(isEditingText: false) {
        didLookUpHitView = true
        return NSButton()
    }

    #expect(!shouldRelease)
    // 편집 중이 아니면 뷰 계층을 뒤지지 않는다.
    #expect(!didLookUpHitView)
}

@MainActor
@Test
func keepsTextFocusWhenClickLandsInAnotherTextField() {
    let textField = NSTextField()

    #expect(TextFocusReleasePolicy.isTextInput(textField))
    #expect(TextFocusReleasePolicy.shouldRelease(isEditingText: true) { textField } == false)
}

@MainActor
@Test
func keepsTextFocusWhenClickLandsInsideNestedTextFieldSubview() {
    // SwiftUI 텍스트 필드는 클릭이 내부 자식 뷰에 닿으므로 상위 계층을 따라 올라가야 한다.
    let textField = NSTextField()
    let innerView = NSView()
    textField.addSubview(innerView)

    #expect(TextFocusReleasePolicy.isTextInput(innerView))
    #expect(TextFocusReleasePolicy.shouldRelease(isEditingText: true) { innerView } == false)
}

@MainActor
@Test
func releasesTextFocusWhenClickLandsOnNonTextControl() {
    let container = NSView()
    let button = NSButton()
    container.addSubview(button)

    #expect(!TextFocusReleasePolicy.isTextInput(button))
    #expect(TextFocusReleasePolicy.shouldRelease(isEditingText: true) { button })
}

@MainActor
@Test
func releasesTextFocusWhenClickLandsOutsideContentView() {
    // 타이틀바처럼 콘텐츠 밖을 클릭하면 클릭 지점이 없다.
    #expect(TextFocusReleasePolicy.shouldRelease(isEditingText: true) { nil })
}

/// SwiftUI 창의 콘텐츠 뷰(`NSHostingView`)와 같이 뒤집힌 좌표계를 쓰는 컨테이너.
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
@Test
func findsClickedViewByWindowCoordinatesInFlippedContentView() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let content = FlippedContainerView()
    // 뒤집힌 좌표계이므로 y가 작을수록 화면 위쪽이다.
    content.addSubview(NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 40)))
    content.addSubview(NSView(frame: NSRect(x: 0, y: 160, width: 200, height: 40)))
    window.contentView = content

    // 창 좌표는 좌하단 기준이므로 y=190이 화면 위쪽의 텍스트 입력칸이다.
    // 콘텐츠 뷰 좌표로 변환해 판정하면 위아래가 뒤집혀 반대로 결론이 난다.
    let topHit = TextFocusReleasePolicy.hitView(in: window, at: NSPoint(x: 100, y: 190))
    let bottomHit = TextFocusReleasePolicy.hitView(in: window, at: NSPoint(x: 100, y: 10))

    #expect(topHit.map(TextFocusReleasePolicy.isTextInput) == true)
    #expect(bottomHit.map(TextFocusReleasePolicy.isTextInput) == false)
    #expect(TextFocusReleasePolicy.shouldRelease(isEditingText: true) { topHit } == false)
    #expect(TextFocusReleasePolicy.shouldRelease(isEditingText: true) { bottomHit })
}
