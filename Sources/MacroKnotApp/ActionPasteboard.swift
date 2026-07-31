import AppKit
import Foundation
import MacroKnotCore

/// 편집 창의 액션 복사·붙여넣기 전용 pasteboard 형식.
/// 앱 안에서만 주고받으므로 문자열 같은 공개 타입은 함께 기록하지 않는다.
enum ActionPasteboard {
    static let actionsType = NSPasteboard.PasteboardType("dev.macroknot.actions")

    @discardableResult
    static func write(_ actions: [MacroAction], to pasteboard: NSPasteboard) -> Bool {
        guard !actions.isEmpty,
              let data = try? JSONEncoder().encode(actions) else { return false }
        pasteboard.clearContents()
        return pasteboard.setData(data, forType: actionsType)
    }

    static func read(from pasteboard: NSPasteboard) -> [MacroAction] {
        guard let data = pasteboard.data(forType: actionsType),
              let actions = try? JSONDecoder().decode([MacroAction].self, from: data) else {
            return []
        }
        return actions
    }

    static func containsActions(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.data(forType: actionsType) != nil
    }
}
