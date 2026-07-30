import Foundation

public enum CaptureFileNaming {
    public static func nextAvailableURL(
        in directory: URL,
        date: Date = Date(),
        fileExists: (String) -> Bool
    ) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = "MacroKnot-\(formatter.string(from: date))"

        var suffix = 0
        while true {
            let suffixText = suffix == 0 ? "" : "-\(suffix)"
            let name = "\(base)\(suffixText).png"
            if !fileExists(name) {
                return directory.appendingPathComponent(name, isDirectory: false)
            }
            suffix += 1
        }
    }
}
