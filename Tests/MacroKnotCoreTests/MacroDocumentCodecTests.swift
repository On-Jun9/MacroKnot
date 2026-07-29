import Foundation
import Testing
@testable import MacroKnotCore

@Test
func roundTripsInitialActionKinds() throws {
    let point = ScreenPoint(x: 120, y: 240)
    let actions: [MacroAction] = [
        .click(point: point, strategy: .accessibilityElementThenCoordinate),
        .keyboard(keyCode: 0, characters: "a", modifierFlags: 0),
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
        controlScope: .applications([
            ApplicationTarget(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit"),
        ]),
        actions: actions
    )

    let data = try MacroDocumentCodec.encode(document)
    let decoded = try MacroDocumentCodec.decode(data)

    #expect(decoded == document)
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
