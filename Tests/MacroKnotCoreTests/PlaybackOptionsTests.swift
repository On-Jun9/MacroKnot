import Foundation
import Testing
@testable import MacroKnotCore

@Test
func scalesTopLevelAndNestedActionTiming() throws {
    let drag = MacroAction(
        kind: .drag,
        delayBeforeMilliseconds: 200,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(
            start: ScreenPoint(x: 0, y: 0),
            end: ScreenPoint(x: 10, y: 10),
            path: [
                TimedScreenPoint(point: ScreenPoint(x: 0, y: 0), offsetMilliseconds: 0),
                TimedScreenPoint(point: ScreenPoint(x: 10, y: 10), offsetMilliseconds: 400),
            ],
            durationMilliseconds: 400,
            buttonNumber: 0
        )
    )
    let repeatAction = MacroAction.repeatBlock(
        count: 2,
        actions: [.wait(milliseconds: 1_000), drag]
    )

    let scaled = try repeatAction.scalingTiming(for: 2)

    #expect(scaled.repeatBlock?.actions[0].wait?.milliseconds == 500)
    #expect(scaled.repeatBlock?.actions[1].delayBeforeMilliseconds == 100)
    #expect(scaled.repeatBlock?.actions[1].mouse?.durationMilliseconds == 200)
    #expect(scaled.repeatBlock?.actions[1].mouse?.path?.last?.offsetMilliseconds == 200)
    try scaled.validate()
}

@Test
func slowsTimingAndRejectsUnsupportedOptions() throws {
    let action = MacroAction.wait(milliseconds: 100)
    #expect(try action.scalingTiming(for: 0.5).wait?.milliseconds == 200)

    #expect(throws: PlaybackOptionsError.unsupportedRate) {
        try action.scalingTiming(for: 3)
    }
    #expect(throws: PlaybackOptionsError.invalidRepeatCount) {
        try PlaybackOptions(rate: 1, repetition: .finite(0)).validate()
    }
}
