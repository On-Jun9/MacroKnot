import SwiftUI

@main
struct MacroKnotApp: App {
    @StateObject private var permissions = PermissionState()
    @StateObject private var libraryStore = MacroKnotApp.makeLibraryStore()

    private static func makeLibraryStore() -> MacroLibraryStore {
#if DEBUG
        // 자동 UI 흐름 시험이 사용자 실제 보관함·초안을 건드리지 않도록 격리한다.
        if let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--debug-store-root=")
        }) {
            let path = String(argument.dropFirst("--debug-store-root=".count))
            return MacroLibraryStore(
                storage: MacroLibraryStorage(
                    rootURL: URL(filePath: path, directoryHint: .isDirectory)
                )
            )
        }
#endif
        return MacroLibraryStore()
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG
            DebugUISnapshotRoot(permissions: permissions)
                .environmentObject(libraryStore)
#else
            LibraryView(permissions: permissions)
                .environmentObject(libraryStore)
#endif
        }
        .defaultSize(width: 1_100, height: 720)

        WindowGroup("매크로 편집", id: "macro-editor", for: UUID.self) { $draftID in
            if let draftID {
                MacroEditorWindowView(permissions: permissions, draftID: draftID)
                    .environmentObject(libraryStore)
            }
        }
        .defaultSize(width: 1_100, height: 720)
        Settings {
            SettingsView(permissions: permissions)
        }
        .commands {
            DocumentMenuCommands()
        }
    }
}

struct MacroCommands {
    let newMacro: (() -> Void)?
    let importMacro: (() -> Void)?
    let saveMacro: (() -> Void)?
    let exportMacro: (() -> Void)?
    let closeWindow: (() -> Void)?
}

private struct MacroCommandsKey: FocusedValueKey {
    typealias Value = MacroCommands
}

extension FocusedValues {
    var macroCommands: MacroCommands? {
        get { self[MacroCommandsKey.self] }
        set { self[MacroCommandsKey.self] = newValue }
    }
}

private struct DocumentMenuCommands: Commands {
    @FocusedValue(\.macroCommands) private var macroCommands

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 매크로") {
                macroCommands?.newMacro?()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(macroCommands?.newMacro == nil)

            Button("가져오기…") {
                macroCommands?.importMacro?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(macroCommands?.importMacro == nil)

            Divider()

            Button("창 닫기") {
                macroCommands?.closeWindow?()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(macroCommands?.closeWindow == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("보관함에 저장") {
                macroCommands?.saveMacro?()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(macroCommands?.saveMacro == nil)

            Button("내보내기…") {
                macroCommands?.exportMacro?()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(macroCommands?.exportMacro == nil)
        }
    }
}
