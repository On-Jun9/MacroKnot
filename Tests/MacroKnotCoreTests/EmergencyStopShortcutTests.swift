import Testing
@testable import MacroKnotCore

@Test
func matchesOnlyControlEscape() {
    #expect(EmergencyStopShortcut.matches(
        keyCode: 53,
        controlPressed: true,
        optionPressed: false,
        commandPressed: false,
        shiftPressed: false
    ))
    #expect(!EmergencyStopShortcut.matches(
        keyCode: 53,
        controlPressed: false,
        optionPressed: false,
        commandPressed: false,
        shiftPressed: false
    ))
    #expect(!EmergencyStopShortcut.matches(
        keyCode: 53,
        controlPressed: true,
        optionPressed: true,
        commandPressed: false,
        shiftPressed: false
    ))
    #expect(!EmergencyStopShortcut.matches(
        keyCode: 0,
        controlPressed: true,
        optionPressed: false,
        commandPressed: false,
        shiftPressed: false
    ))
}
