import CoreGraphics
import Testing
@testable import MacroKnotApp

@Test
func matchesOnlyTheExactConfiguredShortcut() {
    let shortcut = RecordingShortcutChoice.controlOptionR.definition

    #expect(shortcut?.matches(
        keyCode: 15,
        flags: [.maskControl, .maskAlternate]
    ) == true)
    #expect(shortcut?.matches(
        keyCode: 15,
        flags: [.maskControl]
    ) == false)
    #expect(shortcut?.matches(
        keyCode: 15,
        flags: [.maskControl, .maskAlternate, .maskShift]
    ) == false)
    #expect(shortcut?.matches(
        keyCode: 35,
        flags: [.maskControl, .maskAlternate]
    ) == false)
}

@Test
func supportsDisablingGlobalCommandShortcuts() {
    #expect(RecordingShortcutChoice.disabled.definition == nil)
    #expect(PlaybackShortcutChoice.disabled.definition == nil)
}
