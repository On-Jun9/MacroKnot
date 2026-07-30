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
    private var windowsToRestore: [NSWindow] = []
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
        windowsToRestore = NSApplication.shared.windows.filter { window in
            window.isVisible && window.level == .normal
        }
        windowsToRestore.forEach { $0.orderOut(nil) }

        selectionPanels = screens.map(makeSelectionPanel(for:))
        selectionPanels.forEach { $0.orderFrontRegardless() }
        NSApplication.shared.activate(ignoringOtherApps: true)

        let mouseLocation = NSEvent.mouseLocation
        let keyPanel = selectionPanels.first { $0.frame.contains(mouseLocation) }
            ?? selectionPanels.first
        keyPanel?.makeKey()
        NSCursor.crosshair.set()
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
        panel.contentView = NSHostingView(
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

        windowsToRestore.reversed().forEach { $0.orderFront(nil) }
        windowsToRestore.removeAll()
        previousKeyWindow?.makeKeyAndOrderFront(nil)
        previousKeyWindow = nil
        NSApplication.shared.activate(ignoringOtherApps: true)
        isSelecting = false

        completion?(outcome)
    }

    nonisolated static func screenPoint(from location: CGPoint) -> ScreenPoint {
        ScreenPoint(x: location.x, y: location.y)
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
                .onHover { hovering in
                    if hovering {
                        NSCursor.crosshair.set()
                    }
                }

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
