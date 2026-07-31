import Foundation

public struct PlaybackOptions: Equatable, Sendable {
    public enum Repetition: Equatable, Sendable {
        case finite(Int)
        case infinite
    }

    public static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    public static let `default` = PlaybackOptions(rate: 1, repetition: .finite(1))

    public var rate: Double
    public var repetition: Repetition

    public init(rate: Double, repetition: Repetition) {
        self.rate = rate
        self.repetition = repetition
    }

    public func validate() throws {
        guard Self.supportedRates.contains(rate) else {
            throw PlaybackOptionsError.unsupportedRate
        }
        if case .finite(let count) = repetition, !(1...9_999).contains(count) {
            throw PlaybackOptionsError.invalidRepeatCount
        }
    }
}

public enum PlaybackOptionsError: Error, Equatable, LocalizedError {
    case unsupportedRate
    case invalidRepeatCount

    public var errorDescription: String? {
        switch self {
        case .unsupportedRate:
            return "지원하지 않는 재생 속도입니다."
        case .invalidRepeatCount:
            return "반복 횟수는 1회 이상 9,999회 이하여야 합니다."
        }
    }
}

public extension MacroAction {
    func scalingTiming(for rate: Double) throws -> MacroAction {
        try PlaybackOptions(rate: rate, repetition: .finite(1)).validate()
        var result = self
        result.delayBeforeMilliseconds = delayBeforeMilliseconds.map {
            Self.scaledMilliseconds($0, rate: rate, minimum: 0)
        }

        if var wait = result.wait {
            wait.milliseconds = Self.scaledMilliseconds(wait.milliseconds, rate: rate, minimum: 1)
            result.wait = wait
        }

        if var mouse = result.mouse {
            mouse.durationMilliseconds = mouse.durationMilliseconds.map {
                Self.scaledMilliseconds($0, rate: rate, minimum: 1)
            }
            mouse.path = mouse.path?.map { sample in
                TimedScreenPoint(
                    point: sample.point,
                    offsetMilliseconds: Self.scaledMilliseconds(
                        sample.offsetMilliseconds,
                        rate: rate,
                        minimum: sample.offsetMilliseconds == 0 ? 0 : 1
                    )
                )
            }
            result.mouse = mouse
        }

        if var repeatBlock = result.repeatBlock {
            repeatBlock.actions = try repeatBlock.actions.map { try $0.scalingTiming(for: rate) }
            result.repeatBlock = repeatBlock
        }
        return result
    }

    private static func scaledMilliseconds(
        _ milliseconds: UInt64,
        rate: Double,
        minimum: UInt64
    ) -> UInt64 {
        let scaled = (Double(milliseconds) / rate).rounded()
        guard scaled < Double(UInt64.max) else { return .max }
        return max(minimum, UInt64(scaled))
    }
}
