import Foundation

public enum MacroDocumentCodec {
    public static func encode(_ document: MacroDocument) throws -> Data {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> MacroDocument {
        let document = try JSONDecoder().decode(MacroDocument.self, from: data)
        try document.validate()
        return document
    }

    public static func save(_ document: MacroDocument, to url: URL) throws {
        let data = try encode(document)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> MacroDocument {
        try decode(Data(contentsOf: url))
    }
}
