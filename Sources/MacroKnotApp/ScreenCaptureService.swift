import Combine
import CoreGraphics
import Foundation
import ImageIO
import MacroKnotCore
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenCaptureService {
    static func capture(_ payload: CapturePayload) async throws -> URL {
        let directory = URL(
            fileURLWithPath: payload.destinationDirectory,
            isDirectory: true
        )
        try validateDirectory(directory)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenCaptureServiceError.shareableContentUnavailable(error.localizedDescription)
        }
        try Task.checkCancellation()

        let image: CGImage
        if payload.target.kind == .application {
            image = try await captureApplication(
                payload.target,
                content: content,
                includesCursor: payload.includesCursor
            )
        } else {
            let filter = try contentFilter(for: payload.target, content: content)
            image = try await captureImage(
                filter: filter,
                includesCursor: payload.includesCursor
            )
        }
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let destination = CaptureFileNaming.nextAvailableURL(in: directory) { name in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
        do {
            try writePNG(image, to: destination)
        } catch {
            throw ScreenCaptureServiceError.writeFailed(error.localizedDescription)
        }
        return destination
    }

    private static func contentFilter(
        for target: CaptureTarget,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        switch target.kind {
        case .display:
            guard let displayID = target.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw ScreenCaptureServiceError.targetUnavailable("선택한 디스플레이")
            }
            return SCContentFilter(display: display, excludingWindows: [])
        case .window:
            guard let windowID = target.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenCaptureServiceError.targetUnavailable("선택한 창")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        case .application:
            throw ScreenCaptureServiceError.invalidApplicationCapturePath
        }
    }

    private static func captureApplication(
        _ target: CaptureTarget,
        content: SCShareableContent,
        includesCursor: Bool
    ) async throws -> CGImage {
        guard let bundleIdentifier = target.bundleIdentifier,
              let application = content.applications.first(where: {
                  $0.bundleIdentifier == bundleIdentifier
              }) else {
            throw ScreenCaptureServiceError.targetUnavailable("선택한 앱")
        }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == application.processID && $0.isOnScreen
                && $0.frame.width > 0 && $0.frame.height > 0
        }
        guard !windows.isEmpty else {
            throw ScreenCaptureServiceError.targetUnavailable("선택한 앱의 보이는 창")
        }

        var captures: [(frame: CGRect, image: CGImage, scale: CGFloat)] = []
        for window in windows {
            try Task.checkCancellation()
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await captureImage(filter: filter, includesCursor: includesCursor)
            captures.append((window.frame, image, CGFloat(filter.pointPixelScale)))
        }
        if captures.count == 1, let image = captures.first?.image {
            return image
        }
        return try composite(captures)
    }

    private static func captureImage(
        filter: SCContentFilter,
        includesCursor: Bool
    ) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = max(
            1,
            Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        )
        configuration.height = max(
            1,
            Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        )
        configuration.showsCursor = includesCursor
        configuration.capturesAudio = false
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ScreenCaptureServiceError.captureFailed(error.localizedDescription)
        }
    }

    private static func composite(
        _ captures: [(frame: CGRect, image: CGImage, scale: CGFloat)]
    ) throws -> CGImage {
        let union = captures.dropFirst().reduce(captures[0].frame) {
            $0.union($1.frame)
        }
        let scale = captures.map(\.scale).max() ?? 1
        let width = max(1, Int(ceil(union.width * scale)))
        let height = max(1, Int(ceil(union.height * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScreenCaptureServiceError.imageDestinationCreationFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for capture in captures {
            let rect = compositeRect(for: capture.frame, within: union, scale: scale)
            context.draw(capture.image, in: rect)
        }
        guard let image = context.makeImage() else {
            throw ScreenCaptureServiceError.imageEncodingFailed
        }
        return image
    }

    static func compositeRect(
        for frame: CGRect,
        within union: CGRect,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: (frame.minX - union.minX) * scale,
            y: (union.maxY - frame.maxY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private static func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScreenCaptureServiceError.destinationUnavailable
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw ScreenCaptureServiceError.destinationNotWritable
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard let destination = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenCaptureServiceError.imageDestinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ScreenCaptureServiceError.imageEncodingFailed
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

enum ScreenCaptureServiceError: LocalizedError {
    case destinationUnavailable
    case destinationNotWritable
    case shareableContentUnavailable(String)
    case targetUnavailable(String)
    case captureFailed(String)
    case imageDestinationCreationFailed
    case imageEncodingFailed
    case writeFailed(String)
    case invalidApplicationCapturePath

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            return "캡처 저장 폴더를 사용할 수 없습니다."
        case .destinationNotWritable:
            return "캡처 저장 폴더에 쓸 수 없습니다."
        case let .shareableContentUnavailable(message):
            return "캡처 대상 목록을 가져오지 못했습니다: \(message)"
        case let .targetUnavailable(target):
            return "\(target)을 사용할 수 없습니다."
        case let .captureFailed(message):
            return "화면 캡처에 실패했습니다: \(message)"
        case .imageDestinationCreationFailed, .imageEncodingFailed:
            return "PNG 이미지를 만들지 못했습니다."
        case let .writeFailed(message):
            return "PNG 저장에 실패했습니다: \(message)"
        case .invalidApplicationCapturePath:
            return "앱 캡처 경로가 올바르지 않습니다."
        }
    }
}

enum CaptureFolderHistory {
    private static let key = "lastCaptureDestinationDirectory"

    static var lastDirectoryURL: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: key)
        }
    }
}

struct CaptureSourceOption: Identifiable, Equatable {
    var id: String { value }
    let value: String
    let label: String
}

@MainActor
final class CaptureSourceCatalog: ObservableObject {
    @Published private(set) var displays: [CaptureSourceOption] = []
    @Published private(set) var applications: [CaptureSourceOption] = []
    @Published private(set) var windows: [CaptureSourceOption] = []
    @Published private(set) var errorMessage: String?
    private var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            displays = content.displays.map {
                CaptureSourceOption(
                    value: String($0.displayID),
                    label: "디스플레이 \($0.displayID) (\($0.width)×\($0.height))"
                )
            }
            applications = Dictionary(
                grouping: content.applications,
                by: \.bundleIdentifier
            )
            .compactMap { bundleIdentifier, applications in
                guard let application = applications.first else { return nil }
                return CaptureSourceOption(
                    value: bundleIdentifier,
                    label: application.applicationName
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            windows = content.windows.compactMap { window in
                guard let application = window.owningApplication else { return nil }
                let title = window.title?.isEmpty == false ? window.title! : "제목 없는 창"
                return CaptureSourceOption(
                    value: String(window.windowID),
                    label: "\(application.applicationName) — \(title)"
                )
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            loaded = true
            errorMessage = nil
        } catch {
            errorMessage = "캡처 대상 목록을 가져오지 못했습니다: \(error.localizedDescription)"
        }
    }

    func options(for kind: CaptureTarget.Kind) -> [CaptureSourceOption] {
        switch kind {
        case .display: return displays
        case .application: return applications
        case .window: return windows
        }
    }
}
