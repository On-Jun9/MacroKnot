import AppKit
import MacroKnotCore
import SwiftUI

#if DEBUG
struct UISnapshotCaptureView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = UISnapshotAnchorView()
        view.outputURL = Self.outputURL
        view.requestedContentSize = Self.requestedContentSize
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static var outputURL: URL? {
        let prefix = "--ui-snapshot-output="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let path = String(argument.dropFirst(prefix.count))
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static var requestedContentSize: CGSize? {
        requestedContentSize(in: ProcessInfo.processInfo.arguments)
    }

    static func requestedContentSize(in arguments: [String]) -> CGSize? {
        let prefix = "--ui-snapshot-window-size="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let components = argument.dropFirst(prefix.count).split(separator: "x", omittingEmptySubsequences: false)
        guard components.count == 2,
            let width = Double(components[0]),
            let height = Double(components[1]),
            width.isFinite,
            height.isFinite,
            width >= 320,
            height >= 240
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

private final class UISnapshotAnchorView: NSView {
    var outputURL: URL?
    var requestedContentSize: CGSize?
    private var isCaptureScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, outputURL != nil, !isCaptureScheduled else { return }
        if let requestedContentSize {
            window.setContentSize(requestedContentSize)
            window.center()
        }
        isCaptureScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.captureWindowWithScreenCaptureKit()
        }
    }

    private func captureWindowWithScreenCaptureKit() {
        guard let outputURL, let window else { return }
        let windowID = CGWindowID(window.windowNumber)

        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let capturedURL = try await ScreenCaptureService.capture(
                    CapturePayload(
                        target: .window(windowID),
                        destinationDirectory: outputURL.deletingLastPathComponent().path
                    )
                )
                try FileManager.default.moveItem(at: capturedURL, to: outputURL)
            } catch {
                let errorURL = outputURL.appendingPathExtension("error.txt")
                try? error.localizedDescription.write(
                    to: errorURL,
                    atomically: true,
                    encoding: .utf8
                )
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif
