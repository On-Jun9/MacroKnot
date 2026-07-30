import Foundation
import Testing
@testable import MacroKnotCore

@Test
func roundTripsInitialActionKinds() throws {
    let point = ScreenPoint(x: 120, y: 240)
    let actions: [MacroAction] = [
        .click(point: point, strategy: .screenCoordinate),
        .click(kind: .doubleClick, point: point, strategy: .screenCoordinate),
        .click(kind: .rightClick, point: point, strategy: .screenCoordinate),
        MacroAction(
            kind: .mouseMove,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: point)
        ),
        MacroAction(
            kind: .drag,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(
                start: point,
                end: ScreenPoint(x: 300, y: 400),
                path: [
                    TimedScreenPoint(point: point, offsetMilliseconds: 0),
                    TimedScreenPoint(
                        point: ScreenPoint(x: 300, y: 400),
                        offsetMilliseconds: 250
                    ),
                ],
                durationMilliseconds: 250,
                buttonNumber: 0
            )
        ),
        MacroAction(
            kind: .scroll,
            targetStrategy: .screenCoordinate,
            mouse: MousePayload(start: point, scrollDeltaX: 2.5, scrollDeltaY: -10)
        ),
        .keyboard(
            keyCode: 0,
            characters: "a",
            modifierFlags: 0,
            eventKind: .keyDown
        ),
        .keyboard(
            keyCode: 0,
            characters: "a",
            modifierFlags: 0,
            eventKind: .keyUp
        ),
        .wait(milliseconds: 500),
        .capture(CapturePayload(
            target: .display(1),
            destinationDirectory: "/tmp"
        )),
        .repeatBlock(count: 2, actions: [
            .wait(milliseconds: 100),
        ]),
    ]
    let document = MacroDocument(
        name: "왕복 시험",
        actions: actions,
        displayConfiguration: DisplayConfiguration(displays: [
            DisplayGeometry(
                id: 1,
                origin: ScreenPoint(x: 0, y: 0),
                width: 1920,
                height: 1080,
                scale: 2
            ),
        ])
    )

    let data = try MacroDocumentCodec.encode(document)
    let decoded = try MacroDocumentCodec.decode(data)

    #expect(decoded == document)
}

@Test
func rejectsUnimplementedControlScopeAndTargetStrategy() {
    let applicationDocument = MacroDocument(
        name: "지정 앱",
        controlScope: .applications([
            ApplicationTarget(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit"),
        ])
    )
    #expect(throws: MacroDocumentError.unsupportedControlScope) {
        try applicationDocument.validate()
    }

    let action = MacroAction.click(
        point: ScreenPoint(x: 10, y: 20),
        strategy: .accessibilityElement
    )
    #expect(throws: MacroDocumentError.invalidAction(action.id)) {
        try action.validate()
    }
}

@Test
func rejectsUnsupportedFormatVersion() throws {
    var document = MacroDocument(name: "버전 시험")
    document.formatVersion = 99

    #expect(throws: MacroDocumentError.unsupportedFormatVersion(99)) {
        try MacroDocumentCodec.encode(document)
    }
}

@Test
func rejectsInvalidRepeatCount() throws {
    let action = MacroAction.repeatBlock(
        count: 0,
        actions: [.wait(milliseconds: 100)]
    )
    let document = MacroDocument(name: "반복 시험", actions: [action])

    #expect(throws: MacroDocumentError.invalidAction(action.id)) {
        try MacroDocumentCodec.encode(document)
    }
}

@Test
func savesAtomicallyAndLoads() throws {
    let document = MacroDocument(
        name: "파일 시험",
        actions: [.wait(milliseconds: 250)]
    )
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("macro.json")

    try MacroDocumentCodec.save(document, to: url)

    #expect(try MacroDocumentCodec.load(from: url) == document)
}

@Test
func createsNonconflictingCaptureFileNames() {
    let directory = URL(fileURLWithPath: "/tmp/captures", isDirectory: true)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var existing: Set<String> = []

    let first = CaptureFileNaming.nextAvailableURL(in: directory, date: date) {
        existing.contains($0)
    }
    existing.insert(first.lastPathComponent)
    let second = CaptureFileNaming.nextAvailableURL(in: directory, date: date) {
        existing.contains($0)
    }

    #expect(first.pathExtension == "png")
    #expect(second.deletingPathExtension().lastPathComponent.hasSuffix("-1"))
    #expect(first != second)
}

@Test
func validatesCoordinatesAgainstRecordedDisplayConfiguration() throws {
    let configuration = DisplayConfiguration(displays: [
        DisplayGeometry(
            id: 1,
            origin: ScreenPoint(x: 0, y: 0),
            width: 1920,
            height: 1080,
            scale: 2
        ),
    ])
    let document = MacroDocument(
        name: "좌표 검증",
        actions: [
            .click(
                point: ScreenPoint(x: 100, y: 200),
                strategy: .screenCoordinate
            ),
        ],
        displayConfiguration: configuration
    )

    try document.validateForPlayback(currentDisplayConfiguration: configuration)

    let changedScale = DisplayConfiguration(displays: [
        DisplayGeometry(
            id: 1,
            origin: ScreenPoint(x: 0, y: 0),
            width: 1920,
            height: 1080,
            scale: 1
        ),
    ])
    #expect(throws: MacroDocumentError.displayConfigurationChanged) {
        try document.validateForPlayback(currentDisplayConfiguration: changedScale)
    }
}

@Test
func rejectsCoordinatesOutsideAllDisplays() {
    let configuration = DisplayConfiguration(displays: [
        DisplayGeometry(
            id: 1,
            origin: ScreenPoint(x: 0, y: 0),
            width: 100,
            height: 100,
            scale: 1
        ),
    ])
    let action = MacroAction.click(
        point: ScreenPoint(x: 100, y: 50),
        strategy: .screenCoordinate
    )
    let document = MacroDocument(
        name: "화면 밖 좌표",
        actions: [action],
        displayConfiguration: configuration
    )

    #expect(throws: MacroDocumentError.coordinateOutsideDisplays(action.id)) {
        try document.validateForPlayback(currentDisplayConfiguration: configuration)
    }
}

@Test
func rejectsCoordinatePlaybackWithoutRecordedDisplayConfiguration() {
    let document = MacroDocument(
        name: "기준 없는 좌표",
        actions: [
            .click(point: ScreenPoint(x: 10, y: 20), strategy: .screenCoordinate),
        ]
    )
    let current = DisplayConfiguration(displays: [
        DisplayGeometry(
            id: 1,
            origin: ScreenPoint(x: 0, y: 0),
            width: 100,
            height: 100,
            scale: 1
        ),
    ])

    #expect(throws: MacroDocumentError.missingDisplayConfiguration) {
        try document.validateForPlayback(currentDisplayConfiguration: current)
    }
}

@Test
func rejectsScrollDeltaOutsideCoreGraphicsRange() {
    let action = MacroAction(
        kind: .scroll,
        targetStrategy: .screenCoordinate,
        mouse: MousePayload(
            start: ScreenPoint(x: 0, y: 0),
            scrollDeltaY: Double(Int32.max) + 1
        )
    )

    #expect(throws: MacroDocumentError.invalidAction(action.id)) {
        try action.validate()
    }
}

@Test
func decodesInvalidActionForEditingButRejectsValidatedDecode() throws {
    let action = MacroAction.wait(milliseconds: 0)
    let document = MacroDocument(name: "수정할 문서", actions: [action])
    let data = try JSONEncoder().encode(document)

    let editable = try MacroDocumentCodec.decodeForEditing(data)

    #expect(editable.actions.first?.id == action.id)
    #expect(throws: MacroDocumentError.invalidAction(action.id)) {
        try MacroDocumentCodec.decode(data)
    }
}

@Test
func roundTripsRecordedTimingIncludingFirstActionDelay() throws {
    var reducer = InputActionReducer(
        mode: .meaningfulActionsOnly,
        recordingStartTimestampNanoseconds: 1_000_000_000
    )
    var actions: [MacroAction] = []
    reducer.consume(RawInputEvent(
        kind: .keyDown,
        timestampNanoseconds: 2_250_000_000,
        keyCode: 0,
        characters: "a"
    ), appendingTo: &actions)
    reducer.consume(RawInputEvent(
        kind: .keyUp,
        timestampNanoseconds: 2_750_000_000,
        keyCode: 0,
        characters: "a"
    ), appendingTo: &actions)
    let document = MacroDocument(name: "녹화 시간", actions: actions)

    let decoded = try MacroDocumentCodec.decode(MacroDocumentCodec.encode(document))

    #expect(decoded.actions.map(\.delayBeforeMilliseconds) == [1_250, 500])
}
