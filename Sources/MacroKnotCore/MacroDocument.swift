import Foundation

public struct MacroDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var controlScope: MacroControlScope
    public var actions: [MacroAction]
    public var displayConfiguration: DisplayConfiguration?

    public init(
        id: UUID = UUID(),
        name: String,
        controlScope: MacroControlScope = .entireScreen,
        actions: [MacroAction] = [],
        displayConfiguration: DisplayConfiguration? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.controlScope = controlScope
        self.actions = actions
        self.displayConfiguration = displayConfiguration
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw MacroDocumentError.unsupportedFormatVersion(formatVersion)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacroDocumentError.emptyName
        }
        try controlScope.validate()
        guard controlScope.kind == .entireScreen else {
            throw MacroDocumentError.unsupportedControlScope
        }
        try actions.forEach { try $0.validate() }
        try displayConfiguration?.validate()
    }

    public func validateForPlayback(
        currentDisplayConfiguration: DisplayConfiguration
    ) throws {
        try validate()
        guard containsCoordinateActions else { return }
        guard let displayConfiguration else {
            throw MacroDocumentError.missingDisplayConfiguration
        }
        guard displayConfiguration.isCompatible(with: currentDisplayConfiguration) else {
            throw MacroDocumentError.displayConfigurationChanged
        }
        for action in actions {
            try action.validateCoordinates(in: currentDisplayConfiguration)
        }
    }

    public var containsCoordinateActions: Bool {
        actions.contains(where: \.containsCoordinateActions)
    }
}

public struct DisplayConfiguration: Codable, Equatable, Sendable {
    public var displays: [DisplayGeometry]

    public init(displays: [DisplayGeometry]) {
        self.displays = displays.sorted { $0.id < $1.id }
    }

    public func validate() throws {
        guard !displays.isEmpty,
              Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy(\.isValid) else {
            throw MacroDocumentError.invalidDisplayConfiguration
        }
    }

    public func isCompatible(with other: DisplayConfiguration) -> Bool {
        displays == other.displays
    }

    public func contains(_ point: ScreenPoint) -> Bool {
        displays.contains { $0.contains(point) }
    }
}

public struct DisplayGeometry: Codable, Equatable, Sendable {
    public var id: UInt32
    public var origin: ScreenPoint
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(
        id: UInt32,
        origin: ScreenPoint,
        width: Double,
        height: Double,
        scale: Double
    ) {
        self.id = id
        self.origin = origin
        self.width = width
        self.height = height
        self.scale = scale
    }

    fileprivate var isValid: Bool {
        origin.isFinite && width.isFinite && height.isFinite && scale.isFinite
            && width > 0 && height > 0 && scale > 0
    }

    fileprivate func contains(_ point: ScreenPoint) -> Bool {
        point.x >= origin.x && point.y >= origin.y
            && point.x < origin.x + width && point.y < origin.y + height
    }
}

public struct MacroControlScope: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case entireScreen
        case applications
    }

    public var kind: Kind
    public var applications: [ApplicationTarget]

    public static let entireScreen = MacroControlScope(
        kind: .entireScreen,
        applications: []
    )

    public static func applications(_ applications: [ApplicationTarget]) -> Self {
        MacroControlScope(kind: .applications, applications: applications)
    }

    public func validate() throws {
        switch kind {
        case .entireScreen:
            guard applications.isEmpty else {
                throw MacroDocumentError.invalidControlScope
            }
        case .applications:
            guard !applications.isEmpty else {
                throw MacroDocumentError.invalidControlScope
            }
            guard applications.allSatisfy({ !$0.bundleIdentifier.isEmpty }) else {
                throw MacroDocumentError.invalidControlScope
            }
        }
    }

}

public struct ApplicationTarget: Codable, Equatable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

public enum ActionTargetStrategy: String, Codable, Equatable, Sendable {
    case accessibilityElement
    case screenCoordinate
    case accessibilityElementThenCoordinate
}

public struct ScreenPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

public struct TimedScreenPoint: Codable, Equatable, Sendable {
    public var point: ScreenPoint
    public var offsetMilliseconds: UInt64

    public init(point: ScreenPoint, offsetMilliseconds: UInt64) {
        self.point = point
        self.offsetMilliseconds = offsetMilliseconds
    }
}

public struct MacroAction: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case click
        case doubleClick
        case rightClick
        case mouseMove
        case drag
        case scroll
        case keyboard
        case wait
        case capture
        case repeatBlock
    }

    public var id: UUID
    public var kind: Kind
    public var delayBeforeMilliseconds: UInt64?
    public var targetStrategy: ActionTargetStrategy?
    public var mouse: MousePayload?
    public var keyboard: KeyboardPayload?
    public var wait: WaitPayload?
    public var capture: CapturePayload?
    public var repeatBlock: RepeatPayload?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        delayBeforeMilliseconds: UInt64? = nil,
        targetStrategy: ActionTargetStrategy? = nil,
        mouse: MousePayload? = nil,
        keyboard: KeyboardPayload? = nil,
        wait: WaitPayload? = nil,
        capture: CapturePayload? = nil,
        repeatBlock: RepeatPayload? = nil
    ) {
        self.id = id
        self.kind = kind
        self.delayBeforeMilliseconds = delayBeforeMilliseconds
        self.targetStrategy = targetStrategy
        self.mouse = mouse
        self.keyboard = keyboard
        self.wait = wait
        self.capture = capture
        self.repeatBlock = repeatBlock
    }

    public static func click(
        kind: Kind = .click,
        point: ScreenPoint,
        strategy: ActionTargetStrategy
    ) -> Self {
        Self(
            kind: kind,
            targetStrategy: strategy,
            mouse: MousePayload(start: point)
        )
    }

    public static func keyboard(
        keyCode: UInt16,
        characters: String?,
        modifierFlags: UInt64,
        eventKind: KeyboardPayload.EventKind = .press,
        isRepeat: Bool = false
    ) -> Self {
        Self(
            kind: .keyboard,
            keyboard: KeyboardPayload(
                keyCode: keyCode,
                characters: characters,
                modifierFlags: modifierFlags,
                eventKind: eventKind,
                isRepeat: isRepeat
            )
        )
    }

    public static func wait(milliseconds: UInt64) -> Self {
        Self(kind: .wait, wait: WaitPayload(milliseconds: milliseconds))
    }

    public static func capture(_ payload: CapturePayload) -> Self {
        Self(kind: .capture, capture: payload)
    }

    public static func repeatBlock(count: Int, actions: [MacroAction]) -> Self {
        Self(
            kind: .repeatBlock,
            repeatBlock: RepeatPayload(count: count, actions: actions)
        )
    }

    public func validate() throws {
        let payloadCount = [
            mouse != nil,
            keyboard != nil,
            wait != nil,
            capture != nil,
            repeatBlock != nil,
        ].filter { $0 }.count
        guard payloadCount == 1 else {
            throw MacroDocumentError.invalidAction(id)
        }

        switch kind {
        case .click, .doubleClick, .rightClick, .mouseMove:
            guard let mouse,
                  mouse.start.isFinite,
                  mouse.end == nil,
                  mouse.path == nil,
                  mouse.durationMilliseconds == nil,
                  mouse.buttonNumber == nil,
                  mouse.scrollDeltaX == nil,
                  mouse.scrollDeltaY == nil,
                  targetStrategy == .screenCoordinate else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .drag:
            guard let mouse,
                  mouse.start.isFinite,
                  mouse.end?.isFinite == true,
                  targetStrategy == .screenCoordinate else {
                throw MacroDocumentError.invalidAction(id)
            }
            try mouse.validateDrag(actionID: id)
        case .scroll:
            guard let mouse,
                  mouse.start.isFinite,
                  mouse.end == nil,
                  mouse.path == nil,
                  mouse.durationMilliseconds == nil,
                  mouse.buttonNumber == nil,
                  mouse.scrollDeltaX?.isFinite != false,
                  mouse.scrollDeltaY?.isFinite != false,
                  mouse.scrollDeltaX.map(Self.isValidScrollDelta) != false,
                  mouse.scrollDeltaY.map(Self.isValidScrollDelta) != false,
                  mouse.scrollDeltaX != nil || mouse.scrollDeltaY != nil,
                  targetStrategy == .screenCoordinate else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .keyboard:
            guard let keyboard,
                  keyboard.isRepeat != true || keyboard.resolvedEventKind == .keyDown,
                  targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .wait:
            guard let wait, wait.milliseconds > 0, targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .capture:
            guard let capture,
                  !capture.destinationDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !capture.includesCursor,
                  targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
            try capture.target.validate()
        case .repeatBlock:
            guard let repeatBlock,
                  repeatBlock.count > 0,
                  !repeatBlock.actions.isEmpty,
                  targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
            try repeatBlock.actions.forEach { try $0.validate() }
        }
    }

    public var containsCoordinateActions: Bool {
        if targetStrategy == .screenCoordinate || targetStrategy == .accessibilityElementThenCoordinate {
            return true
        }
        return repeatBlock?.actions.contains(where: \.containsCoordinateActions) == true
    }

    fileprivate func validateCoordinates(in configuration: DisplayConfiguration) throws {
        if targetStrategy == .screenCoordinate || targetStrategy == .accessibilityElementThenCoordinate {
            guard let mouse,
                  configuration.contains(mouse.start),
                  mouse.end.map(configuration.contains) != false,
                  mouse.path?.allSatisfy({ configuration.contains($0.point) }) != false else {
                throw MacroDocumentError.coordinateOutsideDisplays(id)
            }
        }
        try repeatBlock?.actions.forEach { try $0.validateCoordinates(in: configuration) }
    }

    private static func isValidScrollDelta(_ value: Double) -> Bool {
        value >= Double(Int32.min) && value <= Double(Int32.max)
    }
}

public struct MousePayload: Codable, Equatable, Sendable {
    public var start: ScreenPoint
    public var end: ScreenPoint?
    public var path: [TimedScreenPoint]?
    public var durationMilliseconds: UInt64?
    public var buttonNumber: Int64?
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?

    public init(
        start: ScreenPoint,
        end: ScreenPoint? = nil,
        path: [TimedScreenPoint]? = nil,
        durationMilliseconds: UInt64? = nil,
        buttonNumber: Int64? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil
    ) {
        self.start = start
        self.end = end
        self.path = path
        self.durationMilliseconds = durationMilliseconds
        self.buttonNumber = buttonNumber
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }

    fileprivate func validateDrag(actionID: UUID) throws {
        guard scrollDeltaX == nil,
              scrollDeltaY == nil,
              buttonNumber == nil || buttonNumber == 0 || buttonNumber == 1 else {
            throw MacroDocumentError.invalidAction(actionID)
        }
        guard let path else { return }
        guard path.count >= 2,
              path.first?.point == start,
              path.last?.point == end,
              path.allSatisfy({ $0.point.isFinite }),
              zip(path, path.dropFirst()).allSatisfy({ $0.offsetMilliseconds <= $1.offsetMilliseconds }),
              path.first?.offsetMilliseconds == 0,
              path.last?.offsetMilliseconds == durationMilliseconds else {
            throw MacroDocumentError.invalidAction(actionID)
        }
    }
}

public struct KeyboardPayload: Codable, Equatable, Sendable {
    public enum EventKind: String, Codable, Equatable, Sendable {
        case press
        case keyDown
        case keyUp
    }

    public var keyCode: UInt16
    public var characters: String?
    public var modifierFlags: UInt64
    public var eventKind: EventKind?
    public var isRepeat: Bool?

    public init(
        keyCode: UInt16,
        characters: String?,
        modifierFlags: UInt64,
        eventKind: EventKind = .press,
        isRepeat: Bool = false
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifierFlags = modifierFlags
        self.eventKind = eventKind
        self.isRepeat = isRepeat
    }

    public var resolvedEventKind: EventKind {
        eventKind ?? .press
    }
}

public struct WaitPayload: Codable, Equatable, Sendable {
    public var milliseconds: UInt64

    public init(milliseconds: UInt64) {
        self.milliseconds = milliseconds
    }
}

public struct CapturePayload: Codable, Equatable, Sendable {
    public var target: CaptureTarget
    public var destinationDirectory: String
    public var includesCursor: Bool

    public init(
        target: CaptureTarget,
        destinationDirectory: String,
        includesCursor: Bool = false
    ) {
        self.target = target
        self.destinationDirectory = destinationDirectory
        self.includesCursor = includesCursor
    }
}

public struct CaptureTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case display
        case application
        case window
    }

    public var kind: Kind
    public var displayID: UInt32?
    public var bundleIdentifier: String?
    public var windowID: UInt32?

    public static func display(_ id: UInt32) -> Self {
        Self(kind: .display, displayID: id)
    }

    public static func application(_ bundleIdentifier: String) -> Self {
        Self(kind: .application, bundleIdentifier: bundleIdentifier)
    }

    public static func window(_ id: UInt32) -> Self {
        Self(kind: .window, windowID: id)
    }

    public func validate() throws {
        switch kind {
        case .display:
            guard displayID != nil, bundleIdentifier == nil, windowID == nil else {
                throw MacroDocumentError.invalidCaptureTarget
            }
        case .application:
            guard let bundleIdentifier, !bundleIdentifier.isEmpty,
                  displayID == nil, windowID == nil else {
                throw MacroDocumentError.invalidCaptureTarget
            }
        case .window:
            guard windowID != nil, displayID == nil, bundleIdentifier == nil else {
                throw MacroDocumentError.invalidCaptureTarget
            }
        }
    }
}

public struct RepeatPayload: Codable, Equatable, Sendable {
    public var count: Int
    public var actions: [MacroAction]

    public init(count: Int, actions: [MacroAction]) {
        self.count = count
        self.actions = actions
    }
}

public enum MacroDocumentError: Error, Equatable, LocalizedError {
    case unsupportedFormatVersion(Int)
    case emptyName
    case invalidControlScope
    case invalidAction(UUID)
    case invalidCaptureTarget
    case invalidDisplayConfiguration
    case missingDisplayConfiguration
    case displayConfigurationChanged
    case coordinateOutsideDisplays(UUID)
    case unsupportedControlScope

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(version):
            return "지원하지 않는 매크로 형식 버전입니다: \(version)"
        case .emptyName:
            return "매크로 이름이 비어 있습니다."
        case .invalidControlScope:
            return "매크로 제어 범위가 올바르지 않습니다."
        case let .invalidAction(id):
            return "매크로 액션 구성이 올바르지 않습니다: \(id)"
        case .invalidCaptureTarget:
            return "캡처 대상 구성이 올바르지 않습니다."
        case .invalidDisplayConfiguration:
            return "디스플레이 구성 정보가 올바르지 않습니다."
        case .missingDisplayConfiguration:
            return "좌표 재생에 필요한 디스플레이 기준 정보가 없습니다."
        case .displayConfigurationChanged:
            return "디스플레이 해상도·배율·배치가 매크로 작성 당시와 달라 재생할 수 없습니다."
        case let .coordinateOutsideDisplays(id):
            return "화면 밖 좌표가 포함된 액션은 재생할 수 없습니다: \(id)"
        case .unsupportedControlScope:
            return "현재 버전에서는 전체 화면 제어 매크로만 사용할 수 있습니다."
        }
    }
}
