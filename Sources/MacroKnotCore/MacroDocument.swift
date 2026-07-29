import Foundation

public struct MacroDocument: Codable, Equatable, Identifiable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var controlScope: MacroControlScope
    public var actions: [MacroAction]

    public init(
        id: UUID = UUID(),
        name: String,
        controlScope: MacroControlScope = .entireScreen,
        actions: [MacroAction] = []
    ) {
        formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.controlScope = controlScope
        self.actions = actions
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw MacroDocumentError.unsupportedFormatVersion(formatVersion)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacroDocumentError.emptyName
        }
        try controlScope.validate()
        try actions.forEach { try $0.validate() }
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
        modifierFlags: UInt64
    ) -> Self {
        Self(
            kind: .keyboard,
            keyboard: KeyboardPayload(
                keyCode: keyCode,
                characters: characters,
                modifierFlags: modifierFlags
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
            guard mouse?.end == nil, targetStrategy != nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .drag:
            guard mouse?.end != nil, targetStrategy != nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .scroll:
            guard let mouse, mouse.scrollDeltaX != nil || mouse.scrollDeltaY != nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .keyboard:
            guard keyboard != nil, targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .wait:
            guard let wait, wait.milliseconds > 0, targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
        case .capture:
            guard let capture, !capture.destinationDirectory.isEmpty, targetStrategy == nil else {
                throw MacroDocumentError.invalidAction(id)
            }
            try capture.target.validate()
        case .repeatBlock:
            guard let repeatBlock, repeatBlock.count > 0, !repeatBlock.actions.isEmpty else {
                throw MacroDocumentError.invalidAction(id)
            }
            try repeatBlock.actions.forEach { try $0.validate() }
        }
    }
}

public struct MousePayload: Codable, Equatable, Sendable {
    public var start: ScreenPoint
    public var end: ScreenPoint?
    public var scrollDeltaX: Double?
    public var scrollDeltaY: Double?

    public init(
        start: ScreenPoint,
        end: ScreenPoint? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil
    ) {
        self.start = start
        self.end = end
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }
}

public struct KeyboardPayload: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var characters: String?
    public var modifierFlags: UInt64

    public init(keyCode: UInt16, characters: String?, modifierFlags: UInt64) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifierFlags = modifierFlags
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
        }
    }
}
