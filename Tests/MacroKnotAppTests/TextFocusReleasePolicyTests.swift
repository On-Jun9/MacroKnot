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
