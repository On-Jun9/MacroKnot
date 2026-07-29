public enum EmergencyStopShortcut {
    public static let keyCode: UInt16 = 53

    public static func matches(
        keyCode: UInt16,
        controlPressed: Bool,
        optionPressed: Bool,
        commandPressed: Bool,
        shiftPressed: Bool
    ) -> Bool {
        keyCode == Self.keyCode
            && controlPressed
            && !optionPressed
            && !commandPressed
            && !shiftPressed
    }
}
