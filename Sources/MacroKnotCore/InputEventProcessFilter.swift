public enum InputEventProcessFilter {
    public static func shouldRecord(
        sourceProcessID: Int64,
        destinationProcessID: Int64?,
        recorderProcessID: Int64,
        excludesEventsTargetingRecorder: Bool
    ) -> Bool {
        guard sourceProcessID != recorderProcessID else { return false }
        return !excludesEventsTargetingRecorder || destinationProcessID != recorderProcessID
    }
}
