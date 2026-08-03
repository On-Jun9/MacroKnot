import AppKit
import Combine
import CoreGraphics
import Foundation
import MacroKnotCore
import SwiftUI

enum ScreenCoordinatePickerOutcome {
    case selected(ScreenPoint)
    case cancelled
    case failed(String)
}

enum ScreenCoordinateTextFormatter {
    static func string(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        if abs(value) < 1_000_000_000_000_000, value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    static func pickedString(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        let rounded = (value * 100).rounded() / 100
        return string(rounded == 0 ? 0 : rounded)
    }
}

@MainActor
final class ScreenCoordinatePicker: ObservableObject {
    @Published private(set) var isSelecting = false

    private weak var previousKeyWindow: NSWindow?
    private var concealedWindows: [(window: NSWindow, alphaValue: CGFloat)] = []
    private var selectionPanels: [NSPanel] = []
    private var completion: ((ScreenCoordinatePickerOutcome) -> Void)?

    func begin(completion: @escaping (ScreenCoordinatePickerOutcome) -> Void) {
        guard !isSelecting else { return }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            completion(.failed("사용할 수 있는 디스플레이를 찾지 못했습니다."))
            return
        }

        isSelecting = true
        self.completion = completion
        previousKeyWindow = NSApplication.shared.keyWindow
        // orderOut은 창을 윈도우 목록에서 제거해 시트 부착이 끊기고
        // AltTab류 유틸에 창이 사라졌다 생기는 것으로 보인다.
        // 창 목록·순서·부착을 유지하도록 투명도만 낮춰 화면에서 감춘다.
        concealedWindows = NSApplication.shared.windows
            .filter { $0.isVisible && $0.level == .normal }
            .map { ($0, $0.alphaValue) }
        concealedWindows.forEach { $0.window.alphaValue = 0 }

        selectionPanels = screens.map(makeSelectionPanel(for:))
        selectionPanels.forEach { $0.orderFrontRegardless() }
        NSApplication.shared.activate(ignoringOtherApps: true)

        let mouseLocation = NSEvent.mouseLocation
        let keyPanel = selectionPanels.first { $0.frame.contains(mouseLocation) }
            ?? selectionPanels.first
        keyPanel?.makeKey()
    }

    func cancel() {
        guard isSelecting else { return }
        finish(with: .cancelled)
    }

    private func makeSelectionPanel(for screen: NSScreen) -> NSPanel {
        let panel = CoordinatePickerPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(screen.frame, display: false)
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.onCancel = { [weak self] in self?.cancel() }
        panel.contentView = CrosshairHostingView(
            rootView: ScreenCoordinatePickerOverlay(
                onSelect: { [weak self] in self?.selectCurrentPointerLocation() },
                onCancel: { [weak self] in self?.cancel() }
            )
        )
        return panel
    }

    private func selectCurrentPointerLocation() {
        guard let location = CGEvent(source: nil)?.location else {
            finish(with: .failed("현재 포인터의 화면 좌표를 읽지 못했습니다."))
            return
        }
        finish(with: .selected(Self.screenPoint(from: location)))
    }

    private func finish(with outcome: ScreenCoordinatePickerOutcome) {
        let completion = completion
        self.completion = nil

        selectionPanels.forEach {
            $0.orderOut(nil)
            $0.contentView = nil
        }
        selectionPanels.removeAll()
        NSCursor.arrow.set()

        concealedWindows.forEach { $0.window.alphaValue = $0.alphaValue }
        concealedWindows.removeAll()
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        NSApplication.shared.activate(ignoringOtherApps: true)
        isSelecting = false

        completion?(outcome)
    }

    nonisolated static func screenPoint(from location: CGPoint) -> ScreenPoint {
        ScreenPoint(x: location.x, y: location.y)
    }
}

/// 일회성 `NSCursor.set()`은 AppKit의 cursor rect 갱신에 덮여 유지되지 않고,
/// cursor rect는 key 창에서만 동작해 다중 디스플레이 패널에 쓸 수 없다.
/// key 여부와 무관하게 동작하는 tracking area로 십자선 커서를 유지한다.
private final class CrosshairHostingView<Content: View>: NSHostingView<Content> {
    private var crosshairTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let crosshairTrackingArea {
            removeTrackingArea(crosshairTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        crosshairTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }
}

private final class CoordinatePickerPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {
            onCancel?()
            return
        }
        super.sendEvent(event)
    }
}

struct ScreenCoordinatePickerOverlay: View {
    let onSelect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

            VStack(spacing: 7) {
                Label("위치를 클릭하세요", systemImage: "scope")
                    .font(.headline)
                Text("원하는 지점을 한 번 클릭하면 화면 좌표가 자동 입력됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "cursorarrow.click")
                    Text("클릭은 아래 앱에 전달되지 않습니다")
                    Text("·")
                        .accessibilityHidden(true)
                    Text("Esc")
                        .font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    Text("취소")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .padding(.top, 36)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onCancel)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("화면 위치 선택. 원하는 위치를 클릭하거나 Escape 키로 취소합니다.")
    }
}
